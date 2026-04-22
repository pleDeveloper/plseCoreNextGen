// Smoke-test the workflow auto-start pipeline end-to-end.
// Creates a Workflow_Trigger__c on the Real Estate Leasing workflow that
// fires when a new Opportunity has StageName = 'Qualification', inserts
// a qualifying Opportunity, then verifies a Workflow_Instance__c appeared.
//
// Does NOT test the Tooling API provisioning step (no ApexTrigger is
// provisioned from this script — we call the Starter directly).

plse__Workflow_Definition__c wd = [
    SELECT Id FROM plse__Workflow_Definition__c
    WHERE plse__Workflow_Key__c = 'real_estate_leasing_v1' LIMIT 1
];

// Clean up any previous smoke-test trigger and opp
delete [SELECT Id FROM plse__Workflow_Trigger__c WHERE Name = 'SMOKE Trigger'];

plse__Workflow_Trigger__c t = new plse__Workflow_Trigger__c(
    Name = 'SMOKE Trigger',
    plse__Workflow_Definition__c = wd.Id,
    plse__Target_Object__c = 'Opportunity',
    plse__Event_Type__c = 'Created',
    plse__Condition_JSON__c =
        '{"logic":"AND","rules":[' +
        '{"field":"StageName","op":"EQUALS","value":"Qualification"},' +
        '{"field":"Name","op":"CONTAINS","value":"SMOKE"}' +
        ']}',
    plse__Active__c = true
);
insert t;
System.debug('### Created trigger: ' + t.Id);

// Clean up any prior smoke opp
delete [SELECT Id FROM Opportunity WHERE Name = 'SMOKE TEST Opportunity'];

Opportunity o = new Opportunity(
    Name = 'SMOKE TEST Opportunity',
    StageName = 'Qualification',
    CloseDate = Date.today().addDays(30),
    Amount = 5000
);
insert o;
System.debug('### Inserted Opportunity: ' + o.Id);

// Manually invoke the Starter to simulate what an auto-provisioned
// Apex trigger would do.
plse.PulseWorkflowStarter.handle(
    'Opportunity', new List<Opportunity>{ o }, null, true
);

// Verify a new instance was created
List<plse__Workflow_Instance__c> insts = [
    SELECT Id, plse__Current_State__c, plse__Status__c
    FROM plse__Workflow_Instance__c
    WHERE plse__Parent_Record_Id__c = :o.Id
];
System.debug('### Instance count: ' + insts.size());
for (plse__Workflow_Instance__c inst : insts) {
    System.debug('### Instance ' + inst.Id + ' at state ' + inst.plse__Current_State__c);
}

// Negative test: insert another opp that should NOT match (Name has no SMOKE)
delete [SELECT Id FROM Opportunity WHERE Name = 'No Match Opp'];
Opportunity o2 = new Opportunity(
    Name = 'No Match Opp',
    StageName = 'Qualification',
    CloseDate = Date.today().addDays(30)
);
insert o2;
plse.PulseWorkflowStarter.handle(
    'Opportunity', new List<Opportunity>{ o2 }, null, true
);
List<plse__Workflow_Instance__c> noMatchInsts = [
    SELECT Id FROM plse__Workflow_Instance__c
    WHERE plse__Parent_Record_Id__c = :o2.Id
];
System.debug('### No-match opp instance count (should be 0): ' + noMatchInsts.size());

System.debug('### Smoke test complete.');
