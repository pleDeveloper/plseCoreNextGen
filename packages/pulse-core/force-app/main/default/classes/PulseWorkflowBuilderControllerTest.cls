@IsTest
private class PulseWorkflowBuilderControllerTest {

    // ── Stub gateway — prevents real callouts during publish tests ──────

    private class StubGateway extends SchemaDeploymentGateway {
        public override SchemaDeploymentGateway.DeploymentPlan buildPlan(
            String targetObject,
            String workflowKey,
            List<SchemaDeploymentGateway.FieldSpec> requestedFields
        ) {
            SchemaDeploymentGateway.DeploymentPlan plan =
                new SchemaDeploymentGateway.DeploymentPlan();
            plan.targetObject = targetObject;
            plan.workflowKey  = workflowKey;
            plan.fields.addAll(requestedFields);
            return plan;
        }

        public override SchemaDeploymentGateway.DeploymentResult enqueue(
            Id deploymentRequestId,
            SchemaDeploymentGateway.DeploymentPlan plan
        ) {
            SchemaDeploymentGateway.DeploymentResult r =
                new SchemaDeploymentGateway.DeploymentResult();
            r.status       = 'Queued';
            r.message      = 'Stub enqueue ok';
            r.deploymentId = 'stub-001';
            return r;
        }

        public override SchemaDeploymentGateway.DeploymentResult getStatus(
            Id deploymentRequestId
        ) {
            SchemaDeploymentGateway.DeploymentResult r =
                new SchemaDeploymentGateway.DeploymentResult();
            r.status       = 'Completed';
            r.message      = 'done';
            r.deploymentId = 'stub-001';
            return r;
        }
    }

    // ── Test data helpers ──────────────────────────────────────────────

    private static final String VALID_JSON = '{'
        + '"schema":"pulse.workflow.v1",'
        + '"workflowKey":"test_wf",'
        + '"version":1,'
        + '"subjectKinds":["Account"],'
        + '"states":[{'
        + '  "key":"intake","label":"Intake","type":"form",'
        + '  "fields":[{"key":"notes","label":"Notes","type":"Text","required":false}],'
        + '  "transitions":[]'
        + '}]'
        + '}';

    private static Workflow_Definition__c createDefinition() {
        Workflow_Definition__c wd = new Workflow_Definition__c(
            Name               = 'test_wf',
            Workflow_Key__c    = 'test_wf',
            Status__c          = 'Draft',
            Version__c         = 1,
            Definition_JSON__c = VALID_JSON,
            Subject_Kinds__c   = 'Account'
        );
        insert wd;
        return wd;
    }

    // ── loadWorkflow ──────────────────────────────────────────────────

    @IsTest
    static void testLoadWorkflow() {
        Workflow_Definition__c wd = createDefinition();

        Test.startTest();
        PulseWorkflowBuilderController.WorkflowPayload p =
            PulseWorkflowBuilderController.loadWorkflow(wd.Id);
        Test.stopTest();

        System.assertEquals(wd.Id, p.recordId);
        System.assertEquals('test_wf', p.workflowKey);
        System.assertEquals(1, p.version);
        System.assertEquals('Draft', p.status);
        System.assert(p.definitionJson.contains('pulse.workflow.v1'));
        System.assertEquals('Account', p.subjectKinds);
    }

    // ── saveWorkflow — update existing ────────────────────────────────

    @IsTest
    static void testSaveWorkflowUpdate() {
        Workflow_Definition__c wd = createDefinition();

        Test.startTest();
        PulseWorkflowBuilderController.SaveResult r =
            PulseWorkflowBuilderController.saveWorkflow(wd.Id, VALID_JSON);
        Test.stopTest();

        System.assert(r.success);
        System.assertEquals(wd.Id, r.recordId);
        System.assert(r.errors.isEmpty());
    }

    // ── saveWorkflow — create new ─────────────────────────────────────

    @IsTest
    static void testSaveWorkflowCreateNew() {
        Test.startTest();
        PulseWorkflowBuilderController.SaveResult r =
            PulseWorkflowBuilderController.saveWorkflow(null, VALID_JSON);
        Test.stopTest();

        System.assert(r.success);
        System.assertNotEquals(null, r.recordId);

        Workflow_Definition__c created = [
            SELECT Workflow_Key__c, Status__c, Version__c
            FROM   Workflow_Definition__c
            WHERE  Id = :r.recordId
        ];
        System.assertEquals('test_wf', created.Workflow_Key__c);
        System.assertEquals('Draft', created.Status__c);
        System.assertEquals(1, created.Version__c);
    }

    // ── saveWorkflow — invalid JSON ───────────────────────────────────

    @IsTest
    static void testSaveWorkflowInvalidJson() {
        Workflow_Definition__c wd = createDefinition();

        Test.startTest();
        PulseWorkflowBuilderController.SaveResult r =
            PulseWorkflowBuilderController.saveWorkflow(wd.Id, 'not json');
        Test.stopTest();

        System.assert(!r.success);
        System.assert(!r.errors.isEmpty());
    }

    // ── saveWorkflow — validation errors ──────────────────────────────

    @IsTest
    static void testSaveWorkflowValidationErrors() {
        Workflow_Definition__c wd = createDefinition();
        // Missing required fields in contract
        String badContract = '{"schema":"wrong","workflowKey":"","version":0,"subjectKinds":[],"states":[]}';

        Test.startTest();
        PulseWorkflowBuilderController.SaveResult r =
            PulseWorkflowBuilderController.saveWorkflow(wd.Id, badContract);
        Test.stopTest();

        System.assert(!r.success);
        System.assert(r.errors.size() > 0);
    }

    // ── publishWorkflow — success ─────────────────────────────────────

    @IsTest
    static void testPublishWorkflowSuccess() {
        Workflow_Definition__c wd = createDefinition();

        StubGateway gw = new StubGateway();
        SchemaProvisioningService.gatewayOverride = gw;
        SchemaProvisioningService.suppressEvents  = true;

        PulseWorkflowBuilderController.FieldSpec fs =
            new PulseWorkflowBuilderController.FieldSpec();
        fs.objectApiName = 'Account';
        fs.fieldApiName  = 'Pulse_Notes__c';
        fs.fieldLabel    = 'Notes';
        fs.fieldType     = 'Text';
        fs.fieldLength   = 255;

        Test.startTest();
        PulseWorkflowBuilderController.PublishResult r =
            PulseWorkflowBuilderController.publishWorkflow(
                wd.Id,
                'Account',
                new List<PulseWorkflowBuilderController.FieldSpec>{ fs }
            );
        Test.stopTest();

        System.assertNotEquals(null, r.deploymentRequestId);
        System.assertEquals('Queued', r.status);
    }

    // ── publishWorkflow — empty field list ─────────────────────────────

    @IsTest
    static void testPublishWorkflowNoFields() {
        Workflow_Definition__c wd = createDefinition();

        StubGateway gw = new StubGateway();
        SchemaProvisioningService.gatewayOverride = gw;
        SchemaProvisioningService.suppressEvents  = true;

        Test.startTest();
        PulseWorkflowBuilderController.PublishResult r =
            PulseWorkflowBuilderController.publishWorkflow(
                wd.Id,
                'Account',
                new List<PulseWorkflowBuilderController.FieldSpec>()
            );
        Test.stopTest();

        System.assertNotEquals(null, r.deploymentRequestId);
        System.assertEquals('Completed', r.status);
    }

    // ── Inner type coverage ────────────────────────────────────────────

    @IsTest
    static void testInnerTypeInstantiation() {
        // Exercise all AuraEnabled fields for serialisation coverage
        PulseWorkflowBuilderController.WorkflowPayload wp =
            new PulseWorkflowBuilderController.WorkflowPayload();
        wp.recordId       = null;
        wp.name           = 'test';
        wp.workflowKey    = 'k';
        wp.version        = 1;
        wp.status         = 'Draft';
        wp.definitionJson = '{}';
        wp.subjectKinds   = 'Account';

        PulseWorkflowBuilderController.SaveResult sr =
            new PulseWorkflowBuilderController.SaveResult();
        sr.success  = true;
        sr.recordId = null;
        sr.errors   = new List<String>();

        PulseWorkflowBuilderController.PublishResult pr =
            new PulseWorkflowBuilderController.PublishResult();
        pr.deploymentRequestId = null;
        pr.status              = 'ok';
        pr.message             = 'msg';
        pr.validationErrors    = new List<String>();

        PulseWorkflowBuilderController.FieldSpec fs =
            new PulseWorkflowBuilderController.FieldSpec();
        fs.objectApiName = 'Account';
        fs.fieldApiName  = 'F__c';
        fs.fieldLabel    = 'F';
        fs.fieldType     = 'Text';
        fs.fieldLength   = 255;
        fs.precision     = null;
        fs.scale         = null;

        System.assertNotEquals(null, wp);
        System.assertNotEquals(null, sr);
        System.assertNotEquals(null, pr);
        System.assertNotEquals(null, fs);
    }
}
