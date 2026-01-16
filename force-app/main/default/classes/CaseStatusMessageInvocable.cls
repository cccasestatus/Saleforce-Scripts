/**
 * @description Invocable entry to launch full-historical Case Status Message migration via Batch
 * @group Case Status Message Migration
 * @author Agentforce
 */
public with sharing class CaseStatusMessageInvocable {
    /**
     * Optional inputs for future extensibility (e.g., date windows); empty for full historical per spec.
     */
    public class Request {
        // Placeholder for future filters (e.g., start/end). Full historical when omitted.
    }

    public class Response {
        @InvocableVariable
        public Id jobId;
    }

    /**
     * Launches the batch end-to-end over full historical dataset.
     */
    @InvocableMethod(label='Run Case Status Message Migration' description='Creates/updates Case_Status_Message__c from Banjaxed Conversation Messages.')
    public static List<Response> run(List<String> requests) {
        // Full historical, no filters
        Id jobId = Database.executeBatch(new CaseStatusMessageMigrationBatch(), 200);
        Response r = new Response();
        r.jobId = jobId;
        return new List<Response>{ r };
    }
}
