// Creates Case Status Messages from Litify Notes 
// Ensure query meets your desired criteria 

List<litify_pm__lit_Note__c> noteList = [SELECT Name, litify_pm__lit_Account__c, litify_pm__lit_Intake__c, litify_pm__lit_Note__c, CreatedById, CreatedDate FROM litify_pm__lit_Note__c  WHERE litify_pm__lit_Intake__c != '' AND (Name = 'appointment_confirmation_request' OR Name = 'checklist_item_created' OR Name = 'checklist_item_reminder' OR Name = 'Internal Message' OR Name = 'message' OR Name = 'out_of_office' OR Name = 'reminder_appointment' OR Name = 'status_change' OR Name = 'updated_appointment') AND CreatedDate < 2025-08-28T19:17:09.000+0000 AND CreatedDate < 2025-01-24T23:39:31.000+0000 ORDER BY CreatedDate Desc LIMIT 2000 Offset 2000];
List<Case_Status_Message__c> messList = new List<Case_Status_Message__c>();
for (litify_pm__lit_Note__c n : noteList){
    Case_Status_Message__c c = new Case_Status_Message__c();
    c.CreatedDate = n.CreatedDate;
    c.CreatedById = n.CreatedById;
    c.Name = n.Name;
    c.Message__c = n.litify_pm__lit_Note__c;
    c.Party__c = n.litify_pm__lit_Account__c;
    c.Intake__c = n.litify_pm__lit_Intake__c;
    messList.add(c);
}
insert messList;
