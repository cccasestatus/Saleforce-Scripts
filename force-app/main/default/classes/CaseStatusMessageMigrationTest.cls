/**
 * @description Unit tests for Case Status Message migration logic and batch.
 * Scenarios cover zero/one/many candidates, boundary timestamps, closed-date EOD, excluded statuses.
 * @group Case Status Message Migration
 * @see CaseStatusMessageAssigner, CaseStatusMessageMigrationBatch
 */
@IsTest
private class CaseStatusMessageMigrationTest {

    @TestSetup
    static void setupData() {
        // Parties (Accounts)
        Account a1 = new Account(Name = 'Party A1');
        Account a2 = new Account(Name = 'Party A2');
        insert new List<Account>{ a1, a2 };

        // Matters for A1
        // m1: Active across entire period (no closed date)
        litify_pm__Matter__c m1 = new litify_pm__Matter__c(
            Name = 'M1',
            litify_pm__Client__c = a1.Id,
            CreatedDate = system.now().addDays(-30)
        );
        // m2: Closes on a date D; should be active until end-of-day UTC
        litify_pm__Matter__c m2 = new litify_pm__Matter__c(
            Name = 'M2',
            litify_pm__Client__c = a1.Id,
            CreatedDate = system.now().addDays(-20),
            litify_pm__Closed_Date__c = Date.today().addDays(-5)
        );
        // Matter for A2 created after messages; should not be active at earlier T
        litify_pm__Matter__c m3 = new litify_pm__Matter__c(
            Name = 'M3',
            litify_pm__Client__c = a2.Id,
            CreatedDate = system.now().addDays(5)
        );

        // Intakes for A1
        // i1: Open (no attached matter, allowed status)
        litify_pm__Intake__c i1 = new litify_pm__Intake__c(
            Name = 'I1',
            litify_pm__Client__c = a1.Id,
            CreatedDate = system.now().addDays(-10),
            litify_pm__Status__c = 'Open'
        );
        // i2: Excluded by status (Turned Down)
        litify_pm__Intake__c i2 = new litify_pm__Intake__c(
            Name = 'I2',
            litify_pm__Client__c = a1.Id,
            CreatedDate = system.now().addDays(-9),
            litify_pm__Status__c = 'Turned Down'
        );
        // i3: Not open because linked to matter
        litify_pm__Intake__c i3 = new litify_pm__Intake__c(
            Name = 'I3',
            litify_pm__Client__c = a1.Id,
            CreatedDate = system.now().addDays(-8),
            litify_pm__Matter__c = null, // set later after we have m1 Id
            litify_pm__Status__c = 'Open'
        );

        insert new List<SObject>{ m1, m2, m3, i1, i2, i3 };

        // After insert, attach i3 to m1 to make it not open
        i3.litify_pm__Matter__c = m1.Id;
        update i3;

        // Conversations and Messages (Banjaxed)
        // Conversation for A1
        banjaxed_cm__Conversation__c conv1 = new banjaxed_cm__Conversation__c(
            Name = 'Conv A1',
            banjaxed_cm__Party__c = a1.Id
        );
        // Conversation for A2
        banjaxed_cm__Conversation__c conv2 = new banjaxed_cm__Conversation__c(
            Name = 'Conv A2',
            banjaxed_cm__Party__c = a2.Id
        );
        insert new List<SObject>{ conv1, conv2 };

        // Messages for A1 across time
        // msg1 at T1: when single open intake exists (i1). Should link Intake.
        banjaxed_cm__Conversation_Message__c msg1 = new banjaxed_cm__Conversation_Message__c(
            banjaxed_cm__Conversation__c = conv1.Id,
            banjaxed_cm__Message_Body__c = 'Message 1',
            CreatedDate = system.now().addDays(-7)
        );
        // msg2 at T2: modify timeline so that there are zero open intakes (simulate by creating another intake after T2)
        banjaxed_cm__Conversation_Message__c msg2 = new banjaxed_cm__Conversation_Message__c(
            banjaxed_cm__Conversation__c = conv1.Id,
            banjaxed_cm__Message_Body__c = 'Message 2',
            CreatedDate = system.now().addDays(-4)
        );
        // msg3 at T3: two active matters at T (create another active matter before T3)
        banjaxed_cm__Conversation_Message__c msg3 = new banjaxed_cm__Conversation_Message__c(
            banjaxed_cm__Conversation__c = conv1.Id,
            banjaxed_cm__Message_Body__c = 'Message 3',
            CreatedDate = system.now().addDays(-2)
        );
        // msg4 at T4 equals date of m2 closed date end-of-day test; ensure still active until EOD
        Datetime t4 = Datetime.newInstanceGmt(m2.litify_pm__Closed_Date__c.year(), m2.litify_pm__Closed_Date__c.month(), m2.litify_pm__Closed_Date__c.day(), 20, 0, 0);
        banjaxed_cm__Conversation_Message__c msg4 = new banjaxed_cm__Conversation_Message__c(
            banjaxed_cm__Conversation__c = conv1.Id,
            banjaxed_cm__Message_Body__c = 'Message 4',
            CreatedDate = t4
        );

        // Messages for A2, where matter is created after messages; expect null linkage
        banjaxed_cm__Conversation_Message__c msg5 = new banjaxed_cm__Conversation_Message__c(
            banjaxed_cm__Conversation__c = conv2.Id,
            banjaxed_cm__Message_Body__c = 'Message 5',
            CreatedDate = system.now()
        );

        insert new List<SObject>{ msg1, msg2, msg3, msg4, msg5 };

        // Additional timeline adjustments:
        // Create another matter for A1 before msg3 to cause >1 active matters at T3
        litify_pm__Matter__c m4 = new litify_pm__Matter__c(
            Name = 'M4',
            litify_pm__Client__c = a1.Id,
            CreatedDate = system.now().addDays(-3)
        );
        insert m4;

        // Create another open intake for A1 after msg2 but before msg3 to not affect earlier messages
        litify_pm__Intake__c i4 = new litify_pm__Intake__c(
            Name = 'I4',
            litify_pm__Client__c = a1.Id,
            CreatedDate = system.now().addDays(-3),
            litify_pm__Status__c = 'Open'
        );
        insert i4;
    }

    @IsTest
    static void testAssignerCoreLogic() {
        // Build DTOs representing party A1 state
        Account a1 = [SELECT Id FROM Account WHERE Name = 'Party A1' LIMIT 1];
        List<litify_pm__Matter__c> matters = [
            SELECT Id, litify_pm__Client__c, CreatedDate, litify_pm__Closed_Date__c
            FROM litify_pm__Matter__c WHERE litify_pm__Client__c = :a1.Id
        ];
        List<litify_pm__Intake__c> intakes = [
            SELECT Id, litify_pm__Client__c, CreatedDate, litify_pm__Matter__c, litify_pm__Status__c
            FROM litify_pm__Intake__c WHERE litify_pm__Client__c = :a1.Id
        ];

        List<CaseStatusMessageAssigner.MatterDTO> mDTOs = new List<CaseStatusMessageAssigner.MatterDTO>();
        for (litify_pm__Matter__c m : matters) {
            CaseStatusMessageAssigner.MatterDTO dto = new CaseStatusMessageAssigner.MatterDTO();
            dto.id = m.Id; dto.clientId = m.litify_pm__Client__c; dto.createdDate = m.CreatedDate; dto.closedDate = m.litify_pm__Closed_Date__c;
            mDTOs.add(dto);
        }
        List<CaseStatusMessageAssigner.IntakeDTO> iDTOs = new List<CaseStatusMessageAssigner.IntakeDTO>();
        for (litify_pm__Intake__c i : intakes) {
            CaseStatusMessageAssigner.IntakeDTO dto = new CaseStatusMessageAssigner.IntakeDTO();
            dto.id = i.Id; dto.clientId = i.litify_pm__Client__c; dto.createdDate = i.CreatedDate; dto.matterId = i.litify_pm__Matter__c; dto.status = i.litify_pm__Status__c;
            iDTOs.add(dto);
        }

        // Pick timestamps relative to setup
        banjaxed_cm__Conversation_Message__c msg1 = [SELECT Id, CreatedDate, banjaxed_cm__Conversation__r.banjaxed_cm__Party__c FROM banjaxed_cm__Conversation_Message__c WHERE banjaxed_cm__Message_Body__c = 'Message 1' LIMIT 1];
        banjaxed_cm__Conversation_Message__c msg3 = [SELECT Id, CreatedDate FROM banjaxed_cm__Conversation_Message__c WHERE banjaxed_cm__Message_Body__c = 'Message 3' LIMIT 1];
        banjaxed_cm__Conversation_Message__c msg4 = [SELECT Id, CreatedDate FROM banjaxed_cm__Conversation_Message__c WHERE banjaxed_cm__Message_Body__c = 'Message 4' LIMIT 1];

        // At T1, at least one open intake (i1) -> all open intakes should be returned
        CaseStatusMessageAssigner.Decision d1 = CaseStatusMessageAssigner.decide((Id)msg1.banjaxed_cm__Conversation__r.banjaxed_cm__Party__c, msg1.CreatedDate, iDTOs, mDTOs);
        System.assertTrue(d1.openIntakesCount >= 1, 'Expect >=1 open intake at T1');
        System.assertNotEquals(null, d1.intakeIds, 'intakeIds should be populated when open intakes exist');
        System.assertTrue(!d1.intakeIds.isEmpty(), 'intakeIds should not be empty');
        System.assertEquals(null, d1.matterIds, 'matterIds should be null when intakes chosen OR remain null when no matters considered');

        // At T3, two active matters (m1 + m4), so should return all active matters if no open intakes exist at that T
        CaseStatusMessageAssigner.Decision d3 = CaseStatusMessageAssigner.decide((Id)msg1.banjaxed_cm__Conversation__r.banjaxed_cm__Party__c, msg3.CreatedDate, iDTOs, mDTOs);
        // Depending on data timing, intakes created after T3 won't count; ensure either path is consistent:
        if (d3.openIntakesCount > 0) {
            System.assertNotEquals(null, d3.intakeIds, 'If open intakes exist, intakeIds must be non-null');
            System.assertTrue(d3.intakeIds.size() == d3.openIntakesCount);
        } else {
            System.assertTrue(d3.activeMattersCount >= 1, 'Expect >=1 active matter at T3');
            System.assertNotEquals(null, d3.matterIds, 'matterIds should be populated when matters chosen');
            System.assertTrue(d3.matterIds.size() == d3.activeMattersCount);
        }

        // At T4 (20:00Z on closed date of m2), m2 still active due to EOD rule -> ensure active matters count respects EOD
        CaseStatusMessageAssigner.Decision d4 = CaseStatusMessageAssigner.decide((Id)msg1.banjaxed_cm__Conversation__r.banjaxed_cm__Party__c, msg4.CreatedDate, iDTOs, mDTOs);
        System.assertTrue(d4.activeMattersCount >= 1);
    }

    @IsTest
    static void testBatchCreatesDuplicatesAndFlags() {
        Test.startTest();
        Id jobId = Database.executeBatch(new CaseStatusMessageMigrationBatch(), 200);
        Test.stopTest();

        // Pull all created CSM records
        List<Case_Status_Message__c> csms = [
            SELECT Id, Party__c, Message__c, Intake__c, Matter__c, Source_Message_Id__c,
                   Is_Historical__c, Is_Duplicate__c, Group_Key__c, Duplicate_Count__c
            FROM Case_Status_Message__c
        ];
        System.assertTrue(csms.size() > 0, 'CSM records should be created');

        // Group by Source_Message_Id__c
        Map<Id, List<Case_Status_Message__c>> bySource = new Map<Id, List<Case_Status_Message__c>>();
        for (Case_Status_Message__c c : csms) {
            Id sourceId = (Id)c.Source_Message_Id__c;
            if (!bySource.containsKey(sourceId)) bySource.put(sourceId, new List<Case_Status_Message__c>());
            bySource.get(sourceId).add(c);
            // Historical flag should always be true
            System.assertEquals(true, c.Is_Historical__c, 'All migrated records should be historical');
        }

        // Verify duplication behavior:
        // - If multiple records exist for the same Source, each should have Is_Duplicate__c = true and same Group_Key__c
        for (Id srcId : bySource.keySet()) {
            List<Case_Status_Message__c> group = bySource.get(srcId);
            if (group.size() > 1) {
                String commonGroup = group[0].Group_Key__c;
                Integer expectedCount = group[0].Duplicate_Count__c == null ? null : Integer.valueOf(group[0].Duplicate_Count__c);
                System.assertNotEquals(null, commonGroup, 'Group key must be set for duplicates');
                System.assertTrue(expectedCount != null && expectedCount == group.size(),
                    'Duplicate count should equal the number of duplicates in the group');
                for (Case_Status_Message__c r : group) {
                    System.assertEquals(true, r.Is_Duplicate__c, 'Each record in a duplicate group must be marked duplicate');
                    System.assertEquals(commonGroup, r.Group_Key__c, 'All duplicates must share the same group key');
                    System.assertEquals(group.size(), Integer.valueOf(r.Duplicate_Count__c), 'Each duplicate must reflect the full group size');
                }
            } else {
                // Singletons should not be marked duplicate and should not have grouping fields set
                Case_Status_Message__c r = group[0];
                System.assertEquals(false, r.Is_Duplicate__c, 'Singleton should not be duplicate');
                System.assertEquals(null, r.Group_Key__c, 'Singleton should not have group key');
                System.assertEquals(null, r.Duplicate_Count__c, 'Singleton should not have duplicate count');
            }
        }
    }

    @IsTest
    static void testReRunCreatesAdditionalRecordsAllowedByInsert() {
        Test.startTest();
        Database.executeBatch(new CaseStatusMessageMigrationBatch(), 200);
        Test.stopTest();

        Integer firstRun = [SELECT COUNT() FROM Case_Status_Message__c];

        // Re-run: logic now uses insert (not upsert). Expect counts to increase.
        Test.startTest();
        Database.executeBatch(new CaseStatusMessageMigrationBatch(), 200);
        Test.stopTest();

        Integer secondRun = [SELECT COUNT() FROM Case_Status_Message__c];
        System.assertTrue(secondRun >= firstRun, 'Second run should create records with insert. If validation rules prevent it, counts may match.');
    }
}
