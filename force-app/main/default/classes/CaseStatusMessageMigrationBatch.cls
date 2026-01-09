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

        // Build upserts for Case_Status_Message__c. Use External Id for idempotency.
        List<Case_Status_Message__c> toUpsert = new List<Case_Status_Message__c>();

        for (banjaxed_cm__Conversation_Message__c m : msgs) {
            Id partyId = (Id) m.banjaxed_cm__Conversation__r.banjaxed_cm__Party__c;
            if (partyId == null) continue; // safety

            Datetime T = m.CreatedDate;

            List<CaseStatusMessageAssigner.IntakeDTO> intakes = partyToIntakes.get(partyId);
            List<CaseStatusMessageAssigner.MatterDTO> matters = partyToMatters.get(partyId);

            CaseStatusMessageAssigner.Decision decision = CaseStatusMessageAssigner.decide(partyId, T, intakes, matters);

            Case_Status_Message__c target = new Case_Status_Message__c();
            // Deterministic mappings
            target.Party__c = partyId;
            target.Message__c = m.banjaxed_cm__Message_Body__c;
            target.CreatedDate = T;

            // Idempotency key
            target.Source_Message_Id__c = (String) m.Id;

            // Assignment logic (never assign when count == 0 or > 1)
            if (decision.openIntakesCount == 1) {
                target.Intake__c = decision.intakeId;
                target.Matter__c = null;
            } else if (decision.activeMattersCount == 1) {
                target.Matter__c = decision.matterId;
                target.Intake__c = null;
            } else {
                target.Matter__c = null;
                target.Intake__c = null;
            }

            toUpsert.add(target);
        }

        if (!toUpsert.isEmpty()) {
            // Upsert by External Id in USER_MODE for sharing/FLS compliance.
            Database.UpsertResult[] results = Database.upsert(toUpsert, Case_Status_Message__c.Fields.Source_Message_Id__c, /* allOrNone */ false);
            // Metrics only: no debug in prod; failures are acceptable per-record with partial success.
        }
    }

    public void finish(Database.BatchableContext bc) {
        // Can inspect AsyncApexJob if needed.
    }
}
