// Forces matter sync by querying matters, updating a value, and iterating over the next batch to update. 
// edit query criteria to meet your requirements
// edit field updated to meet requirements of your flow, but ensure data is not significantly changed

Integer pageSize = 100;
Id lastId = null; // set to the last processed Id when you re-run
Integer processed = 0;

while (true) {
    List<litify_pm__Matter__c> matters = (lastId == null)
        ? [SELECT Id, Synced_with_Case_Status__c
           FROM litify_pm__Matter__c
           WHERE litify_pm__Primary_Intake__r.litify_pm__Status__c = 'Converted'
             AND CreatedDate >= 2024-09-05T00:00:00Z
             AND Synced_with_Case_Status__c != null
           ORDER BY Id
           LIMIT :pageSize]
        : [SELECT Id, Synced_with_Case_Status__c
           FROM litify_pm__Matter__c
           WHERE litify_pm__Primary_Intake__r.litify_pm__Status__c = 'Converted'
             AND CreatedDate >= 2024-09-05T00:00:00Z
             AND Synced_with_Case_Status__c != null
             AND Id > :lastId
           ORDER BY Id
           LIMIT :pageSize];

    if (matters.isEmpty()) break;

    for (litify_pm__Matter__c m : matters) {
        m.Synced_with_Case_Status__c = m.Synced_with_Case_Status__c.addSeconds(2);
    }
    Database.update(matters, false);

    processed += matters.size();
    lastId = matters.get(matters.size() - 1).Id;

    // Stop before the 10s CPU wall; re-run with lastId to continue
    if (Limits.getCpuTime() > 8500) {
        System.debug('Stopping early at Id ' + lastId + ' after ' + processed + ' updates.');
        break;
    }
}
System.debug('Done (this pass). LastId=' + lastId + ', processed=' + processed);
