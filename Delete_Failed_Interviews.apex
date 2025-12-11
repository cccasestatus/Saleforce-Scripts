// Delete failed Flow Interview records for a specific Flow API name + version.

List<FlowInterview> interviewsToDelete = [
    SELECT Id, InterviewStatus, FlowVersion, FlowDefinition.DeveloperName
    FROM FlowInterview
    WHERE InterviewStatus = 'Error'
      AND FlowDefinition.DeveloperName = 'Case_Status_Sync_Up_Flow'
      AND FlowVersion = 27
];

if (!interviewsToDelete.isEmpty()) {
    delete interviewsToDelete;
    System.debug('Deleted ' + interviewsToDelete.size() + ' failed flow interviews.');
} else {
    System.debug('No failed interviews found for the specified flow and version.');
}
