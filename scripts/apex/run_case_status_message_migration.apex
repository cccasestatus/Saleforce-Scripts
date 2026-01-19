// Launch full-historical Case Status Message migration via Batch
// Uses Database.executeBatch(new CaseStatusMessageMigrationBatch(), 200);

// Run in Anonymous Apex or via Flow using CaseStatusMessageInvocable if preferred.
Id jobId = Database.executeBatch(new CaseStatusMessageMigrationBatch(), 200);
System.debug('Launched CaseStatusMessageMigrationBatch. AsyncApexJob Id: ' + jobId);

// Optional: Query job after enqueuing (commented to avoid unnecessary queries in prod)
AsyncApexJob job = [SELECT Id, Status, JobItemsProcessed, TotalJobItems, NumberOfErrors
                  FROM AsyncApexJob WHERE Id = :jobId];
System.debug('Job Status: ' + job.Status + ', Items: ' + job.JobItemsProcessed + '/' + job.TotalJobItems + ', Errors: ' + job.NumberOfErrors);
