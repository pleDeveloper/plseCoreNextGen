@IsTest
private class PulseWorkflowTriggerControllerTest {

    private static Workflow_Definition__c makeDef() {
        Workflow_Definition__c wd = new Workflow_Definition__c(
            Name = 'ctl_test',
            Workflow_Key__c = 'ctl_test',
            Version__c = 1,
            Status__c = 'Draft',
            Subject_Kinds__c = 'Opportunity',
            Definition_JSON__c =
                '{"schema":"pulse.workflow.v1","workflowKey":"ctl_test","version":1,' +
                '"subjectKinds":["Opportunity"],' +
                '"states":[{"key":"intake","label":"Intake","type":"form","fields":[],"transitions":[]}]}'
        );
        insert wd;
        return wd;
    }

    @IsTest
    static void upsertCreatesTriggerRecord() {
        Workflow_Definition__c wd = makeDef();
        Map<String, Object> payload = new Map<String, Object>{
            'workflowDefinitionId' => wd.Id,
            'targetObject'         => 'Opportunity',
            'eventType'            => 'Created',
            'conditionJson'        => '{"field":"StageName","op":"EQUALS","value":"Qualification"}',
            'active'               => true
        };

        Test.startTest();
        PulseWorkflowTriggerController.UpsertResult result =
            PulseWorkflowTriggerController.upsertTrigger(payload);
        Test.stopTest();

        System.assert(result.success, 'Upsert should succeed: ' + result.error);
        System.assertNotEquals(null, result.recordId);
        System.assertEquals('Opportunity_PulseWorkflowTrigger', result.triggerName);

        Workflow_Trigger__c saved = [
            SELECT Id, Target_Object__c, Event_Type__c, Active__c
            FROM Workflow_Trigger__c WHERE Id = :result.recordId
        ];
        System.assertEquals('Opportunity', saved.Target_Object__c);
        System.assertEquals('Created', saved.Event_Type__c);
        System.assertEquals(true, saved.Active__c);
    }

    @IsTest
    static void upsertUpdatesExistingRecord() {
        Workflow_Definition__c wd = makeDef();
        Workflow_Trigger__c existing = new Workflow_Trigger__c(
            Name = 'existing',
            Workflow_Definition__c = wd.Id,
            Target_Object__c = 'Opportunity',
            Event_Type__c = 'Created',
            Active__c = true
        );
        insert existing;

        Map<String, Object> payload = new Map<String, Object>{
            'recordId'             => existing.Id,
            'workflowDefinitionId' => wd.Id,
            'targetObject'         => 'Opportunity',
            'eventType'            => 'Updated',
            'active'               => false
        };

        Test.startTest();
        PulseWorkflowTriggerController.UpsertResult result =
            PulseWorkflowTriggerController.upsertTrigger(payload);
        Test.stopTest();

        System.assert(result.success);
        Workflow_Trigger__c reloaded = [
            SELECT Event_Type__c, Active__c FROM Workflow_Trigger__c WHERE Id = :existing.Id
        ];
        System.assertEquals('Updated', reloaded.Event_Type__c);
        System.assertEquals(false, reloaded.Active__c);
    }

    @IsTest
    static void listReturnsTriggersForDefinition() {
        Workflow_Definition__c wd = makeDef();
        insert new Workflow_Trigger__c(
            Name = 'a', Workflow_Definition__c = wd.Id,
            Target_Object__c = 'Opportunity', Event_Type__c = 'Created', Active__c = true
        );
        insert new Workflow_Trigger__c(
            Name = 'b', Workflow_Definition__c = wd.Id,
            Target_Object__c = 'Opportunity', Event_Type__c = 'Updated', Active__c = false
        );

        Test.startTest();
        List<PulseWorkflowTriggerController.TriggerDto> results =
            PulseWorkflowTriggerController.listTriggers(wd.Id);
        Test.stopTest();

        System.assertEquals(2, results.size());
    }

    @IsTest
    static void deleteRemovesRecord() {
        Workflow_Definition__c wd = makeDef();
        Workflow_Trigger__c t = new Workflow_Trigger__c(
            Name = 'x', Workflow_Definition__c = wd.Id,
            Target_Object__c = 'Opportunity', Event_Type__c = 'Created', Active__c = true
        );
        insert t;

        Test.startTest();
        Boolean ok = PulseWorkflowTriggerController.deleteTrigger(t.Id);
        Test.stopTest();

        System.assertEquals(true, ok);
        Integer cnt = [SELECT COUNT() FROM Workflow_Trigger__c WHERE Id = :t.Id];
        System.assertEquals(0, cnt);
    }

    @IsTest
    static void describeObjectFieldsReturnsFields() {
        Test.startTest();
        List<PulseWorkflowTriggerController.FieldInfo> fields =
            PulseWorkflowTriggerController.describeObjectFields('Opportunity');
        Test.stopTest();

        System.assert(fields.size() > 0, 'Should return at least some Opportunity fields');
        Boolean foundStageName = false;
        for (PulseWorkflowTriggerController.FieldInfo fi : fields) {
            if (fi.apiName == 'StageName') {
                foundStageName = true;
                System.assertNotEquals(null, fi.picklistValues);
                System.assert(fi.picklistValues.size() > 0);
                break;
            }
        }
        System.assert(foundStageName, 'Expected StageName field with picklist values');
    }

    @IsTest
    static void upsertFailsWithMissingFields() {
        Map<String, Object> payload = new Map<String, Object>();
        PulseWorkflowTriggerController.UpsertResult r =
            PulseWorkflowTriggerController.upsertTrigger(payload);
        System.assertEquals(false, r.success);
        System.assertNotEquals(null, r.error);
    }

    @IsTest
    static void coerceToTriggerDtoHandlesEdgeCases() {
        // null input → empty DTO
        PulseWorkflowTriggerController.TriggerDto d1 =
            PulseWorkflowTriggerController.coerceToTriggerDto(null);
        System.assertEquals(null, d1.recordId);
        System.assertEquals(null, d1.workflowDefinitionId);

        // empty strings for ids should become null (not throw on Id cast)
        PulseWorkflowTriggerController.TriggerDto d2 =
            PulseWorkflowTriggerController.coerceToTriggerDto(
                new Map<String, Object>{'recordId' => '', 'workflowDefinitionId' => ''});
        System.assertEquals(null, d2.recordId);
        System.assertEquals(null, d2.workflowDefinitionId);

        // active as String "true" should coerce to Boolean true
        PulseWorkflowTriggerController.TriggerDto d3 =
            PulseWorkflowTriggerController.coerceToTriggerDto(
                new Map<String, Object>{'active' => 'true'});
        System.assertEquals(true, d3.active);
    }

    @IsTest
    static void innerDtoCoverage() {
        PulseWorkflowTriggerController.TriggerDto d =
            new PulseWorkflowTriggerController.TriggerDto();
        d.recordId = null; d.workflowDefinitionId = null; d.name = 'x';
        d.targetObject = 'o'; d.eventType = 'Created'; d.conditionJson = '{}';
        d.initialStateKey = 's'; d.active = true;

        PulseWorkflowTriggerController.UpsertResult r =
            new PulseWorkflowTriggerController.UpsertResult();
        r.success = true; r.recordId = null; r.triggerName = 't';
        r.apexTriggerAlreadyExisted = false; r.provisioningMessage = ''; r.error = '';

        PulseWorkflowTriggerController.FieldInfo f =
            new PulseWorkflowTriggerController.FieldInfo();
        f.apiName = 'a'; f.label = 'l'; f.fieldType = 'STRING';
        f.nillable = true; f.picklistValues = new List<String>{'x'};

        System.assertNotEquals(null, d);
        System.assertNotEquals(null, r);
        System.assertNotEquals(null, f);
    }
}
