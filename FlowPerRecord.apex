// === Execute Anonymous: invoke Flow for each Matter's Primary Intake, throttled by SOQL limit ===
// Runs the flow Case_Status_Delete_Intake_Callout for each matching Matter,
// passing 'recordId' = litify_pm__Primary_Intake__c.
// Re-run with the printed lastId until done.
//
// Tuning knobs:
Integer pageSize = 8;      // Keep small; increase/decrease based on your Flow's query usage
Integer queryGuard = 90;   // Stop this pass when Apex queries used >= 90

Id lastId = null;          // If resuming, paste last logged Id here
Integer processed = 0;
List<String> failures = new List<String>();

while (true) {
    // Stop early if we're close to the SOQL limit this transaction
    if (Limits.getQueries() >= queryGuard) {
        System.debug('⛔ Query guard reached (' + Limits.getQueries() + '). Stopping this pass. lastId=' + lastId + ', processed=' + processed);
        break;
    }

    // Pull a small page of records
    List<litify_pm__Matter__c> matters = (lastId == null)
        ? [SELECT Id, litify_pm__Primary_Intake__c
           FROM litify_pm__Matter__c
           WHERE litify_pm__Primary_Intake__r.litify_pm__Status__c = 'Converted'
             AND CreatedDate >= 2024-09-05T00:00:00Z
             AND litify_pm__Primary_Intake__c != null
           ORDER BY Id
           LIMIT :pageSize]
        : [SELECT Id, litify_pm__Primary_Intake__c
           FROM litify_pm__Matter__c
           WHERE litify_pm__Primary_Intake__r.litify_pm__Status__c = 'Converted'
             AND CreatedDate >= 2024-09-05T00:00:00Z
             AND litify_pm__Primary_Intake__c != null
             AND Id > :lastId
           ORDER BY Id
           LIMIT :pageSize];

    if (matters.isEmpty()) {
        System.debug('✅ No more records. Finished all passes. Total processed so far: ' + processed);
        break;
    }

    for (litify_pm__Matter__c m : matters) {
        // Extra guard: bail out before invoking the flow if we’re near the query limit
        if (Limits.getQueries() >= queryGuard) {
            System.debug('⛔ Query guard reached mid-page (' + Limits.getQueries() + '). Stopping. lastId=' + lastId + ', processed=' + processed);
            break;
        }
        try {
            Map<String, Object> inputs = new Map<String, Object>{ 'recordId' => (Object)m.litify_pm__Primary_Intake__c };

            // If your flow's API name includes version (e.g., ..._v1), use that exact name here.
            Flow.Interview.Case_Status_Delete_Intake_Callout interview =
                new Flow.Interview.Case_Status_Delete_Intake_Callout(inputs);
            interview.start();

            processed++;
        } catch (Exception e) {
            failures.add('Matter ' + m.Id + ' (Intake ' + m.litify_pm__Primary_Intake__c + '): ' + e.getMessage());
        }
        lastId = m.Id; // advance cursor as we go, so resume picks up correctly
    }

    // If we broke mid-page for guard reasons, stop outer loop too
    if (Limits.getQueries() >= queryGuard) {
        System.debug('⛔ Stopping outer loop due to query guard. lastId=' + lastId + ', processed=' + processed);
        break;
    }
}

System.debug('📊 Pass summary — processed: ' + processed + ', failures: ' + failures.size());
if (!failures.isEmpty()) {
    System.debug('❌ Failures:\n' + String.join(failures, '\n'));
}
System.debug('➡️  To resume next pass, set lastId to: ' + lastId);
