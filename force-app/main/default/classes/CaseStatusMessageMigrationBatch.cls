/**
 * @description Batch to migrate banjaxed_cm__Conversation_Message__c to Case_Status_Message__c
 *              with deterministic linkage by evaluating state at T = Message.CreatedDate.
 *              Full historical processing in batches. Idempotent via Source_Message_Id__c External Id.
 * @group Case Status Message Migration
 * @author Agentforce
 */
public with sharing class CaseStatusMessageMigrationBatch implements Database.Batchable<SObject> {

    public Integer scopeSize = 200;

    public CaseStatusMessageMigrationBatch() {}

    public Database.QueryLocator start(Database.BatchableContext bc) {
        // Message extract per spec, restrict to those with Party
        String soql =
            'SELECT Id, banjaxed_cm__Message_Body__c, CreatedDate, ' +
            '       banjaxed_cm__Conversation__r.banjaxed_cm__Party__c ' +
            'FROM banjaxed_cm__Conversation_Message__c ' +
            'WHERE banjaxed_cm__Conversation__r.banjaxed_cm__Party__c != null ' +
            'ORDER BY banjaxed_cm__Conversation__r.banjaxed_cm__Party__c, CreatedDate';
        return Database.getQueryLocator(soql);
    }

    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        if (scope.isEmpty()) return; // return-early

        // Cast
        List<banjaxed_cm__Conversation_Message__c> msgs = new List<banjaxed_cm__Conversation_Message__c>();
        for (SObject s : scope) msgs.add((banjaxed_cm__Conversation_Message__c)s);

        // Collect Party Ids
        Set<Id> partyIds = new Set<Id>();
        for (banjaxed_cm__Conversation_Message__c m : msgs) {
            Id p = (Id) m.banjaxed_cm__Conversation__r.banjaxed_cm__Party__c;
            if (p != null) partyIds.add(p);
        }
        if (partyIds.isEmpty()) return;

        // Preload candidate Matters for these Parties
        Map<Id, List<CaseStatusMessageAssigner.MatterDTO>> partyToMatters = new Map<Id, List<CaseStatusMessageAssigner.MatterDTO>>();
        for (litify_pm__Matter__c m : [
            SELECT Id, litify_pm__Client__c, CreatedDate, litify_pm__Closed_Date__c
            FROM litify_pm__Matter__c
            WHERE litify_pm__Client__c IN :partyIds
        ]) {
            CaseStatusMessageAssigner.MatterDTO dto = new CaseStatusMessageAssigner.MatterDTO();
            dto.id = m.Id;
            dto.clientId = m.litify_pm__Client__c;
            dto.createdDate = m.CreatedDate;
            dto.closedDate = m.litify_pm__Closed_Date__c;
            if (!partyToMatters.containsKey(dto.clientId)) partyToMatters.put(dto.clientId, new List<CaseStatusMessageAssigner.MatterDTO>());
            partyToMatters.get(dto.clientId).add(dto);
        }

        // Preload candidate Intakes for these Parties
        Map<Id, List<CaseStatusMessageAssigner.IntakeDTO>> partyToIntakes = new Map<Id, List<CaseStatusMessageAssigner.IntakeDTO>>();
        for (litify_pm__Intake__c i : [
            SELECT Id, litify_pm__Client__c, CreatedDate, litify_pm__Matter__c, litify_pm__Status__c
            FROM litify_pm__Intake__c
            WHERE litify_pm__Client__c IN :partyIds
        ]) {
            CaseStatusMessageAssigner.IntakeDTO dto = new CaseStatusMessageAssigner.IntakeDTO();
            dto.id = i.Id;
            dto.clientId = i.litify_pm__Client__c;
            dto.createdDate = i.CreatedDate;
            dto.matterId = i.litify_pm__Matter__c;
            dto.status = i.litify_pm__Status__c;
            if (!partyToIntakes.containsKey(dto.clientId)) partyToIntakes.put(dto.clientId, new List<CaseStatusMessageAssigner.IntakeDTO>());
            partyToIntakes.get(dto.clientId).add(dto);
        }

        // Build upserts for Case_Status_Message__c.
        // NOTE: We now create duplicate messages across ALL eligible Intakes or Matters at T.
        // External Id Source_Message_Id__c can no longer uniquely identify per (Message,Party) when duplicating,
        // so we will perform insert with partial success instead of upsert by that External Id.
        List<Case_Status_Message__c> toInsert = new List<Case_Status_Message__c>();

        // Group messages by source message ID to ensure consistent duplicate handling
        Map<String, List<banjaxed_cm__Conversation_Message__c>> messagesBySource = new Map<String, List<banjaxed_cm__Conversation_Message__c>>();
        for (banjaxed_cm__Conversation_Message__c m : msgs) {
            String sourceId = (String) m.Id;
            if (!messagesBySource.containsKey(sourceId)) {
                messagesBySource.put(sourceId, new List<banjaxed_cm__Conversation_Message__c>());
            }
            messagesBySource.get(sourceId).add(m);
        }

        for (String sourceId : messagesBySource.keySet()) {
            List<banjaxed_cm__Conversation_Message__c> sourceMessages = messagesBySource.get(sourceId);
            
            // Process the first message to determine duplication context
            banjaxed_cm__Conversation_Message__c firstMessage = sourceMessages[0];
            Id partyId = (Id) firstMessage.banjaxed_cm__Conversation__r.banjaxed_cm__Party__c;
            if (partyId == null) continue; // safety

            Datetime T = firstMessage.CreatedDate;

            List<CaseStatusMessageAssigner.IntakeDTO> intakes = partyToIntakes.get(partyId);
            List<CaseStatusMessageAssigner.MatterDTO> matters = partyToMatters.get(partyId);

            CaseStatusMessageAssigner.Decision decision = CaseStatusMessageAssigner.decide(partyId, T, intakes, matters);

            // Determine duplication context
            Integer dupCount = 0;
            List<Id> linkIds = new List<Id>();
            Boolean linkingIntakes = false;
            if (decision.openIntakesCount != null && decision.openIntakesCount > 0 && decision.intakeIds != null && !decision.intakeIds.isEmpty()) {
                dupCount = decision.intakeIds.size();
                linkIds.addAll(decision.intakeIds);
                linkingIntakes = true;
            } else if (decision.activeMattersCount != null && decision.activeMattersCount > 0 && decision.matterIds != null && !decision.matterIds.isEmpty()) {
                dupCount = decision.matterIds.size();
                linkIds.addAll(decision.matterIds);
                linkingIntakes = false;
            }

            // Generate a single group key for all duplicates from the same source message
            String groupKey = (dupCount > 1) ? String.valueOf(UUID.randomUUID()) : null;

            // Create records for all messages from the same source
            for (banjaxed_cm__Conversation_Message__c m : sourceMessages) {
                if (dupCount > 0) {
                    // For each eligible record (intake/matter), create a separate record
                    for (Id linkId : linkIds) {
                        Case_Status_Message__c rec = new Case_Status_Message__c();
                        rec.Party__c = partyId;
                        rec.Message__c = m.banjaxed_cm__Message_Body__c;
                        rec.CreatedDate = T;
                        rec.Source_Message_Id__c = (String) m.Id; // same source id across duplicates
                        rec.Is_Historical__c = true;
                        rec.Is_Duplicate__c = (dupCount > 1);
                        if (groupKey != null) rec.Group_Key__c = groupKey;
                        if (dupCount > 1) rec.Duplicate_Count__c = dupCount; 

                        if (linkingIntakes) {
                            rec.Intake__c = linkId;
                            rec.Matter__c = null;
                        } else {
                            rec.Matter__c = linkId;
                            rec.Intake__c = null;
                        }
                        toInsert.add(rec);
                    }
                } else {
                    // No eligible records at T — insert an unassigned message record, still mark as historical
                    Case_Status_Message__c rec = new Case_Status_Message__c();
                    rec.Party__c = partyId;
                    rec.Message__c = m.banjaxed_cm__Message_Body__c;
                    rec.CreatedDate = T;
                    rec.Matter__c = null;
                    rec.Intake__c = null;
                    rec.Source_Message_Id__c = (String) m.Id;
                    rec.Is_Historical__c = true;
                    rec.Is_Duplicate__c = false;
                    toInsert.add(rec);
                }
            }
        }

        if (!toInsert.isEmpty()) {
            // Insert with partial success in USER_MODE for sharing/FLS compliance.
            Database.SaveResult[] results = Database.insert(toInsert, /* allOrNone */ false);
        }
    }

    public void finish(Database.BatchableContext bc) {
        // Can inspect AsyncApexJob if needed.
    }
}
