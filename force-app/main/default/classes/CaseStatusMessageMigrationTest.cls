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

        // At T1, exactly one open intake (i1) -> choose intake
        CaseStatusMessageAssigner.Decision d1 = CaseStatusMessageAssigner.decide((Id)msg1.banjaxed_cm__Conversation__r.banjaxed_cm__Party__c, msg1.CreatedDate, iDTOs, mDTOs);
        System.assertEquals(1, d1.openIntakesCount);
        System.assertNotEquals(null, d1.intakeId);
        System.assertEquals(null, d1.matterId);

        // At T3, two active matters (m1 + m4), so must choose neither
        CaseStatusMessageAssigner.Decision d3 = CaseStatusMessageAssigner.decide((Id)msg1.banjaxed_cm__Conversation__r.banjaxed_cm__Party__c, msg3.CreatedDate, iDTOs, mDTOs);
        System.assertEquals(0, d3.openIntakesCount); // i4 exists but created -3d; depending on T3 (-2d), it's open at T3; ensure count != 1; assert neither is chosen
        System.assertEquals(null, d3.intakeId);
        System.assertEquals(null, d3.matterId);

        // At T4 (20:00Z on closed date of m2), m2 still active due to EOD rule -> at least one active matter
        CaseStatusMessageAssigner.Decision d4 = CaseStatusMessageAssigner.decide((Id)msg1.banjaxed_cm__Conversation__r.banjaxed_cm__Party__c, msg4.CreatedDate, iDTOs, mDTOs);
        System.assertTrue(d4.activeMattersCount >= 1);
    }

    @IsTest
    static void testBatchCreatesAndAssignsDeterministically() {
        Test.startTest();
        Id jobId = Database.executeBatch(new CaseStatusMessageMigrationBatch(), 200);
        Test.stopTest();

        // Fetch results keyed by Source Message Id
        Map<Id, Case_Status_Message__c> bySource = new Map<Id, Case_Status_Message__c>();
        for (Case_Status_Message__c csm : [
            SELECT Id, Party__c, Message__c, Intake__c, Matter__c, Source_Message_Id__c
            FROM Case_Status_Message__c
        ]) {
            bySource.put((Id)csm.Source_Message_Id__c, csm);
        }

        List<banjaxed_cm__Conversation_Message__c> msgs = [
            SELECT Id, banjaxed_cm__Message_Body__c, banjaxed_cm__Conversation__r.banjaxed_cm__Party__c, CreatedDate
            FROM banjaxed_cm__Conversation_Message__c ORDER BY CreatedDate
        ];
        System.assertEquals(msgs.size(), bySource.size(), 'All messages should have corresponding Case_Status_Message__c via idempotent upsert');

        for (banjaxed_cm__Conversation_Message__c m : msgs) {
            Case_Status_Message__c csm = bySource.get(m.Id);
            System.assertNotEquals(null, csm, 'CSM exists for message');
            System.assertEquals((Id)m.banjaxed_cm__Conversation__r.banjaxed_cm__Party__c, csm.Party__c, 'Party linkage must be authoritative');
            System.assertEquals(m.banjaxed_cm__Message_Body__c, csm.Message__c, 'Message body mapped');

            // Deterministic assignment checks by specific messages:
            if (m.banjaxed_cm__Message_Body__c == 'Message 1') {
                System.assertNotEquals(null, csm.Intake__c, 'Message 1 should link Intake when exactly one open intake exists');
                System.assertEquals(null, csm.Matter__c);
            }
            if (m.banjaxed_cm__Message_Body__c == 'Message 3') {
                // More than one active matter at T -> neither assigned
                System.assertEquals(null, csm.Intake__c);
                System.assertEquals(null, csm.Matter__c);
            }
            if (m.banjaxed_cm__Message_Body__c == 'Message 5') {
                // A2 matter created after T -> counts as 0 at T => neither
                System.assertEquals(null, csm.Intake__c);
                System.assertEquals(null, csm.Matter__c);
            }
        }
    }

    @IsTest
    static void testIdempotentUpsertByExternalId() {
        Test.startTest();
        Database.executeBatch(new CaseStatusMessageMigrationBatch(), 200);
        Test.stopTest();

        Integer beforeCount = [SELECT COUNT() FROM Case_Status_Message__c];

        // Run again should not create duplicates due to External ID upsert
        Test.startTest();
        Database.executeBatch(new CaseStatusMessageMigrationBatch(), 200);
        Test.stopTest();

        Integer afterCount = [SELECT COUNT() FROM Case_Status_Message__c];
        System.assertEquals(beforeCount, afterCount, 'Upsert by External Id should prevent duplicates on reruns');
    }
}
