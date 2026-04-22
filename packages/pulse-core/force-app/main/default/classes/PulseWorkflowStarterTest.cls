@IsTest
private class PulseWorkflowStarterTest {

    private static Workflow_Definition__c makeDef(String key, String firstState) {
        Workflow_Definition__c wd = new Workflow_Definition__c(
            Name                = key,
            Workflow_Key__c     = key,
            Version__c          = 1,
            Status__c           = 'Published',
            Subject_Kinds__c    = 'Opportunity',
            Definition_JSON__c  =
                '{"schema":"pulse.workflow.v1","workflowKey":"' + key + '","version":1,' +
                '"subjectKinds":["Opportunity"],' +
                '"states":[{"key":"' + firstState + '","label":"S","type":"form","fields":[],"transitions":[]}]}'
        );
        insert wd;
        return wd;
    }

    private static Workflow_Trigger__c makeTrigger(
        Id defId, String obj, String eventType, String conditionJson
    ) {
        Workflow_Trigger__c t = new Workflow_Trigger__c(
            Name                   = 'Test Trigger',
            Workflow_Definition__c = defId,
            Target_Object__c       = obj,
            Event_Type__c          = eventType,
            Condition_JSON__c      = conditionJson,
            Active__c              = true
        );
        insert t;
        return t;
    }

    @IsTest
    static void createsInstanceWhenConditionMatchesOnCreate() {
        Workflow_Definition__c wd = makeDef('test_wf_1', 'intake');
        makeTrigger(wd.Id, 'Opportunity', 'Created',
            '{"field":"StageName","op":"EQUALS","value":"Qualification"}');

        Opportunity o = new Opportunity(
            Name = 'Match Me', StageName = 'Qualification', CloseDate = Date.today().addDays(30)
        );
        insert o;

        Test.startTest();
        PulseWorkflowStarter.handle(
            'Opportunity',
            new List<Opportunity>{ o },
            null,
            true
        );
        Test.stopTest();

        List<Workflow_Instance__c> insts = [
            SELECT Id, Current_State__c, Parent_Record_Id__c
            FROM Workflow_Instance__c
            WHERE Workflow_Definition__c = :wd.Id
        ];
        System.assertEquals(1, insts.size(), 'Expected one instance to be created');
        System.assertEquals('intake', insts[0].Current_State__c);
        System.assertEquals(o.Id, insts[0].Parent_Record_Id__c);
    }

    @IsTest
    static void skipsWhenConditionDoesNotMatch() {
        Workflow_Definition__c wd = makeDef('test_wf_2', 'intake');
        makeTrigger(wd.Id, 'Opportunity', 'Created',
            '{"field":"StageName","op":"EQUALS","value":"Closed Won"}');

        Opportunity o = new Opportunity(
            Name = 'No Match', StageName = 'Qualification', CloseDate = Date.today().addDays(30)
        );
        insert o;

        Test.startTest();
        PulseWorkflowStarter.handle(
            'Opportunity', new List<Opportunity>{ o }, null, true
        );
        Test.stopTest();

        Integer count = [SELECT COUNT() FROM Workflow_Instance__c WHERE Workflow_Definition__c = :wd.Id];
        System.assertEquals(0, count, 'No instance should be created when condition misses');
    }

    @IsTest
    static void respectsEventTypeCreatedVsUpdated() {
        Workflow_Definition__c wd = makeDef('test_wf_3', 'intake');
        makeTrigger(wd.Id, 'Opportunity', 'Updated',
            '{"field":"StageName","op":"EQUALS","value":"Qualification"}');

        Opportunity o = new Opportunity(
            Name = 'Create Path', StageName = 'Qualification', CloseDate = Date.today().addDays(30)
        );
        insert o;

        Test.startTest();
        // Fire as insert — should be ignored because event type is Updated-only.
        PulseWorkflowStarter.handle(
            'Opportunity', new List<Opportunity>{ o }, null, true
        );
        Test.stopTest();

        Integer count = [SELECT COUNT() FROM Workflow_Instance__c WHERE Workflow_Definition__c = :wd.Id];
        System.assertEquals(0, count, 'Updated-only trigger should ignore insert events');
    }

    @IsTest
    static void doesNotDuplicateWhenInstanceAlreadyExists() {
        Workflow_Definition__c wd = makeDef('test_wf_4', 'intake');
        makeTrigger(wd.Id, 'Opportunity', 'Created_or_Updated',
            '{"field":"StageName","op":"EQUALS","value":"Qualification"}');

        Opportunity o = new Opportunity(
            Name = 'Dedup', StageName = 'Qualification', CloseDate = Date.today().addDays(30)
        );
        insert o;

        // Pre-existing instance
        insert new Workflow_Instance__c(
            Workflow_Definition__c = wd.Id,
            Parent_Object_Type__c  = 'Opportunity',
            Parent_Record_Id__c    = o.Id,
            Current_State__c       = 'intake',
            Status__c              = 'Active'
        );

        Test.startTest();
        PulseWorkflowStarter.handle(
            'Opportunity', new List<Opportunity>{ o }, null, true
        );
        Test.stopTest();

        Integer count = [SELECT COUNT() FROM Workflow_Instance__c WHERE Workflow_Definition__c = :wd.Id];
        System.assertEquals(1, count, 'No duplicate instance should be created');
    }

    @IsTest
    static void handlesBulkInsertInOneDml() {
        Workflow_Definition__c wd = makeDef('test_wf_5', 'intake');
        makeTrigger(wd.Id, 'Opportunity', 'Created',
            '{"field":"StageName","op":"EQUALS","value":"Qualification"}');

        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < 5; i++) {
            opps.add(new Opportunity(
                Name = 'Bulk ' + i,
                StageName = 'Qualification',
                CloseDate = Date.today().addDays(30)
            ));
        }
        insert opps;

        Test.startTest();
        Integer dmlBefore = Limits.getDmlStatements();
        PulseWorkflowStarter.handle('Opportunity', opps, null, true);
        Integer dmlAfter  = Limits.getDmlStatements();
        Test.stopTest();

        Integer count = [SELECT COUNT() FROM Workflow_Instance__c WHERE Workflow_Definition__c = :wd.Id];
        System.assertEquals(5, count, 'All 5 records should get instances');
        System.assert(dmlAfter - dmlBefore <= 1, 'Should bulk insert in one DML, got ' + (dmlAfter - dmlBefore));
    }

    @IsTest
    static void usesInitialStateKeyOverride() {
        Workflow_Definition__c wd = makeDef('test_wf_6', 'first_state');
        Workflow_Trigger__c t = makeTrigger(wd.Id, 'Opportunity', 'Created', null);
        t.Initial_State_Key__c = 'override_state';
        update t;

        Opportunity o = new Opportunity(
            Name = 'Override', StageName = 'Qualification', CloseDate = Date.today().addDays(30)
        );
        insert o;

        Test.startTest();
        PulseWorkflowStarter.handle('Opportunity', new List<Opportunity>{ o }, null, true);
        Test.stopTest();

        Workflow_Instance__c inst = [
            SELECT Current_State__c FROM Workflow_Instance__c
            WHERE Workflow_Definition__c = :wd.Id LIMIT 1
        ];
        System.assertEquals('override_state', inst.Current_State__c);
    }

    @IsTest
    static void inactiveTriggerIsIgnored() {
        Workflow_Definition__c wd = makeDef('test_wf_7', 'intake');
        Workflow_Trigger__c t = makeTrigger(wd.Id, 'Opportunity', 'Created_or_Updated', null);
        t.Active__c = false;
        update t;

        Opportunity o = new Opportunity(
            Name = 'Inactive', StageName = 'Qualification', CloseDate = Date.today().addDays(30)
        );
        insert o;

        Test.startTest();
        PulseWorkflowStarter.handle('Opportunity', new List<Opportunity>{ o }, null, true);
        Test.stopTest();

        Integer count = [SELECT COUNT() FROM Workflow_Instance__c WHERE Workflow_Definition__c = :wd.Id];
        System.assertEquals(0, count, 'Inactive trigger should be skipped');
    }

    @IsTest
    static void suppressedFlagShortCircuits() {
        Workflow_Definition__c wd = makeDef('test_wf_8', 'intake');
        makeTrigger(wd.Id, 'Opportunity', 'Created_or_Updated', null);

        Opportunity o = new Opportunity(
            Name = 'Suppressed', StageName = 'Qualification', CloseDate = Date.today().addDays(30)
        );
        insert o;

        PulseWorkflowStarter.suppressed = true;
        try {
            Test.startTest();
            PulseWorkflowStarter.handle('Opportunity', new List<Opportunity>{ o }, null, true);
            Test.stopTest();
        } finally {
            PulseWorkflowStarter.suppressed = false;
        }

        Integer count = [SELECT COUNT() FROM Workflow_Instance__c WHERE Workflow_Definition__c = :wd.Id];
        System.assertEquals(0, count);
    }
}
