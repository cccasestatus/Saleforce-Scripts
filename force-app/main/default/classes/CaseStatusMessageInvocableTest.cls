/**
 * @description Tests for CaseStatusMessageInvocable to ensure batch launches successfully.
 * @group Case Status Message Migration
 */
@IsTest
private class CaseStatusMessageInvocableTest {
    @IsTest
    static void testInvocableLaunchesBatch() {
        // Prepare minimal dataset so the batch has something to iterate over
        Account a = new Account(Name = 'Party X', 	litify_pm__Last_Name__c = 'X');
        insert a;

        banjaxed_cm__Conversation__c conv = new banjaxed_cm__Conversation__c(
            Name = 'Conv X',
            banjaxed_cm__Party__c = a.Id
        );
        insert conv;

        banjaxed_cm__Conversation_Message__c msg = new banjaxed_cm__Conversation_Message__c(
            banjaxed_cm__Conversation__c = conv.Id,
            banjaxed_cm__Message_Body__c = 'Hello from Invocable',
            CreatedDate = System.now().addDays(-1)
        );
        insert msg;

        // Call invocable - pass empty list as strings (no filters)
        List<String> reqs = new List<String>{};

        Test.startTest();
        List<CaseStatusMessageInvocable.Response> resps = CaseStatusMessageInvocable.run(reqs);
        Test.stopTest();

        System.assertEquals(1, resps.size(), 'One response expected');
        System.assertNotEquals(null, resps[0].jobId, 'Batch job id must be returned');

        // Validate that batch processed and created Case Status Message records
        List<Case_Status_Message__c> created = [
            SELECT Id, Source_Message_Id__c, Is_Historical__c
            FROM Case_Status_Message__c
            WHERE Source_Message_Id__c = :String.valueOf(msg.Id)
        ];
        System.assert(created.size() >= 1);
        for (Case_Status_Message__c c : created) {
            System.assertEquals(true, c.Is_Historical__c, 'Historical flag set by migration');
        }
    }
}