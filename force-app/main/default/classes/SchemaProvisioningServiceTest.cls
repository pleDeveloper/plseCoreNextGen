@IsTest
private class SchemaProvisioningServiceTest {

    // ── Stub gateway ────────────────────────────────────────────────────

    /**
     * Test-only gateway that never touches Metadata API.
     * Configurable to return success, failure, or validation errors.
     */
    private class StubGateway extends SchemaDeploymentGateway {
        Boolean failEnqueue       = false;
        Boolean returnInvalid     = false;
        Boolean skipAllFields     = false;
        String  enqueueStatus     = 'Queued';
        String  statusPollResult  = 'In_Progress';

        public override SchemaDeploymentGateway.DeploymentPlan buildPlan(
            String targetObject,
            String workflowKey,
            List<SchemaDeploymentGateway.FieldSpec> requestedFields
        ) {
            SchemaDeploymentGateway.DeploymentPlan plan =
                new SchemaDeploymentGateway.DeploymentPlan();
            plan.targetObject = targetObject;
            plan.workflowKey  = workflowKey;

            if (returnInvalid) {
                plan.validationErrors.add('Simulated budget exceeded');
                return plan;
            }

            if (!skipAllFields) {
                plan.fields.addAll(requestedFields);
            }
            return plan;
        }

        public override SchemaDeploymentGateway.DeploymentResult enqueue(
            Id deploymentRequestId,
            SchemaDeploymentGateway.DeploymentPlan plan
        ) {
            if (failEnqueue) {
                throw new SchemaProvisioningServiceTest.GatewayException('Simulated enqueue failure');
            }

            SchemaDeploymentGateway.DeploymentResult dr =
                new SchemaDeploymentGateway.DeploymentResult();
            dr.status       = enqueueStatus;
            dr.message      = 'Stub enqueue ok';
            dr.deploymentId = 'stub-async-001';
            return dr;
        }

        public override SchemaDeploymentGateway.DeploymentResult getStatus(
            Id deploymentRequestId
        ) {
            SchemaDeploymentGateway.DeploymentResult dr =
                new SchemaDeploymentGateway.DeploymentResult();
            dr.status       = statusPollResult;
            dr.message      = 'Status polled';
            dr.deploymentId = 'stub-async-001';
            return dr;
        }
    }

    private class GatewayException extends Exception {}

    // ── Helpers ─────────────────────────────────────────────────────────

    private static Workflow_Definition__c createDefinition() {
        Workflow_Definition__c wd = new Workflow_Definition__c(
            Workflow_Key__c    = 'test_workflow',
            Status__c          = 'Draft',
            Version__c         = 1,
            Definition_JSON__c = '{"schema":"pulse.workflow.v1"}'
        );
        insert wd;
        return wd;
    }

    private static List<SchemaDeploymentGateway.FieldSpec> sampleFields() {
        SchemaDeploymentGateway.FieldSpec f1 = new SchemaDeploymentGateway.FieldSpec();
        f1.objectApiName = 'Account';
        f1.fieldApiName  = 'Pulse_Intake_Notes__c';
        f1.fieldLabel    = 'Intake Notes';
        f1.fieldType     = 'Text';
        f1.length        = 255;

        SchemaDeploymentGateway.FieldSpec f2 = new SchemaDeploymentGateway.FieldSpec();
        f2.objectApiName = 'Account';
        f2.fieldApiName  = 'Pulse_Score__c';
        f2.fieldLabel    = 'Score';
        f2.fieldType     = 'Number';
        f2.precision     = 5;
        f2.scale         = 0;

        return new List<SchemaDeploymentGateway.FieldSpec>{ f1, f2 };
    }

    // ── Tests ───────────────────────────────────────────────────────────

    @IsTest
    static void testSuccessfulProvision() {
        Workflow_Definition__c wd = createDefinition();
        StubGateway gw = new StubGateway();
        SchemaProvisioningService.gatewayOverride = gw;
        SchemaProvisioningService.suppressEvents  = true;

        Test.startTest();
        SchemaProvisioningService.ProvisioningResult result =
            SchemaProvisioningService.provision(
                wd.Id, 'Account', 'test_workflow', sampleFields()
            );
        Test.stopTest();

        System.assertNotEquals(null, result.deploymentRequestId);
        System.assertEquals('Queued', result.status);

        Deployment_Request__c req = [
            SELECT Status__c, Plan_JSON__c, Target_Object__c
            FROM   Deployment_Request__c
            WHERE  Id = :result.deploymentRequestId
        ];
        System.assertEquals('Queued', req.Status__c);
        System.assertEquals('Account', req.Target_Object__c);
        System.assert(req.Plan_JSON__c.contains('Pulse_Intake_Notes__c'));
    }

    @IsTest
    static void testValidationFailure() {
        Workflow_Definition__c wd = createDefinition();
        StubGateway gw = new StubGateway();
        gw.returnInvalid = true;
        SchemaProvisioningService.gatewayOverride = gw;
        SchemaProvisioningService.suppressEvents  = true;

        Test.startTest();
        SchemaProvisioningService.ProvisioningResult result =
            SchemaProvisioningService.provision(
                wd.Id, 'Account', 'test_workflow', sampleFields()
            );
        Test.stopTest();

        System.assertEquals('Failed', result.status);
        System.assert(result.validationErrors != null);
        System.assert(!result.validationErrors.isEmpty());

        Deployment_Request__c req = [
            SELECT Status__c, Error_Message__c
            FROM   Deployment_Request__c
            WHERE  Id = :result.deploymentRequestId
        ];
        System.assertEquals('Failed', req.Status__c);
        System.assert(req.Error_Message__c.contains('budget'));
    }

    @IsTest
    static void testNoFieldsNeeded() {
        Workflow_Definition__c wd = createDefinition();
        StubGateway gw = new StubGateway();
        gw.skipAllFields = true;
        SchemaProvisioningService.gatewayOverride = gw;
        SchemaProvisioningService.suppressEvents  = true;

        Test.startTest();
        SchemaProvisioningService.ProvisioningResult result =
            SchemaProvisioningService.provision(
                wd.Id, 'Account', 'test_workflow', sampleFields()
            );
        Test.stopTest();

        System.assertEquals('Completed', result.status);
        System.assertEquals('No new fields required', result.message);

        Deployment_Request__c req = [
            SELECT Status__c, Completed_Date__c
            FROM   Deployment_Request__c
            WHERE  Id = :result.deploymentRequestId
        ];
        System.assertEquals('Completed', req.Status__c);
        System.assertNotEquals(null, req.Completed_Date__c);
    }

    @IsTest
    static void testEnqueueException() {
        Workflow_Definition__c wd = createDefinition();
        StubGateway gw = new StubGateway();
        gw.failEnqueue = true;
        SchemaProvisioningService.gatewayOverride = gw;
        SchemaProvisioningService.suppressEvents  = true;

        Test.startTest();
        SchemaProvisioningService.ProvisioningResult result =
            SchemaProvisioningService.provision(
                wd.Id, 'Account', 'test_workflow', sampleFields()
            );
        Test.stopTest();

        System.assertEquals('Failed', result.status);
        System.assert(result.message.contains('Simulated enqueue failure'));
    }

    @IsTest
    static void testCheckStatusTransition() {
        Workflow_Definition__c wd = createDefinition();

        Deployment_Request__c req = new Deployment_Request__c(
            Status__c             = 'In_Progress',
            Target_Object__c      = 'Account',
            Workflow_Definition__c = wd.Id,
            Plan_JSON__c          = '{}',
            Requested_By__c       = UserInfo.getUserId()
        );
        insert req;

        StubGateway gw = new StubGateway();
        gw.statusPollResult = 'Completed';
        SchemaProvisioningService.gatewayOverride = gw;
        SchemaProvisioningService.suppressEvents  = true;

        Test.startTest();
        SchemaProvisioningService.ProvisioningResult result =
            SchemaProvisioningService.checkStatus(req.Id);
        Test.stopTest();

        System.assertEquals('Completed', result.status);

        Deployment_Request__c updated = [
            SELECT Status__c, Completed_Date__c
            FROM   Deployment_Request__c
            WHERE  Id = :req.Id
        ];
        System.assertEquals('Completed', updated.Status__c);
        System.assertNotEquals(null, updated.Completed_Date__c);
    }

    @IsTest
    static void testCheckStatusAlreadyTerminal() {
        Workflow_Definition__c wd = createDefinition();

        Deployment_Request__c req = new Deployment_Request__c(
            Status__c             = 'Completed',
            Target_Object__c      = 'Account',
            Workflow_Definition__c = wd.Id,
            Plan_JSON__c          = '{}',
            Completed_Date__c     = Datetime.now(),
            Requested_By__c       = UserInfo.getUserId()
        );
        insert req;

        StubGateway gw = new StubGateway();
        SchemaProvisioningService.gatewayOverride = gw;
        SchemaProvisioningService.suppressEvents  = true;

        Test.startTest();
        SchemaProvisioningService.ProvisioningResult result =
            SchemaProvisioningService.checkStatus(req.Id);
        Test.stopTest();

        System.assertEquals('Completed', result.status);
        System.assert(result.message.contains('terminal'));
    }

    @IsTest
    static void testCancelDeployment() {
        Workflow_Definition__c wd = createDefinition();

        Deployment_Request__c req = new Deployment_Request__c(
            Status__c             = 'Queued',
            Target_Object__c      = 'Account',
            Workflow_Definition__c = wd.Id,
            Plan_JSON__c          = '{}',
            Requested_By__c       = UserInfo.getUserId()
        );
        insert req;

        SchemaProvisioningService.suppressEvents = true;

        Test.startTest();
        SchemaProvisioningService.cancel(req.Id);
        Test.stopTest();

        Deployment_Request__c updated = [
            SELECT Status__c, Completed_Date__c
            FROM   Deployment_Request__c
            WHERE  Id = :req.Id
        ];
        System.assertEquals('Cancelled', updated.Status__c);
        System.assertNotEquals(null, updated.Completed_Date__c);
    }

    @IsTest
    static void testCancelAlreadyTerminalIsNoOp() {
        Workflow_Definition__c wd = createDefinition();

        Deployment_Request__c req = new Deployment_Request__c(
            Status__c             = 'Failed',
            Target_Object__c      = 'Account',
            Workflow_Definition__c = wd.Id,
            Plan_JSON__c          = '{}',
            Completed_Date__c     = Datetime.now(),
            Requested_By__c       = UserInfo.getUserId()
        );
        insert req;

        SchemaProvisioningService.suppressEvents = true;

        Test.startTest();
        SchemaProvisioningService.cancel(req.Id);
        Test.stopTest();

        Deployment_Request__c updated = [
            SELECT Status__c FROM Deployment_Request__c WHERE Id = :req.Id
        ];
        System.assertEquals('Failed', updated.Status__c, 'Should remain Failed, not Cancelled');
    }

    @IsTest
    static void testDefaultGatewayBuildPlanValidatesObject() {
        // Exercise the MetadataApiDeploymentGateway.buildPlan path
        // for an invalid object
        SchemaProvisioningService.MetadataApiDeploymentGateway gw =
            new SchemaProvisioningService.MetadataApiDeploymentGateway();

        SchemaDeploymentGateway.FieldSpec fs = new SchemaDeploymentGateway.FieldSpec();
        fs.objectApiName = 'Totally_Fake_Object__c';
        fs.fieldApiName  = 'Test__c';
        fs.fieldLabel    = 'Test';
        fs.fieldType     = 'Text';
        fs.length        = 255;

        Test.startTest();
        SchemaDeploymentGateway.DeploymentPlan plan = gw.buildPlan(
            'Totally_Fake_Object__c', 'test_wf',
            new List<SchemaDeploymentGateway.FieldSpec>{ fs }
        );
        Test.stopTest();

        System.assertEquals(false, plan.isValid());
        System.assert(plan.validationErrors[0].contains('does not exist'));
    }

    @IsTest
    static void testDefaultGatewayBuildPlanRejectsUnsupportedType() {
        SchemaProvisioningService.MetadataApiDeploymentGateway gw =
            new SchemaProvisioningService.MetadataApiDeploymentGateway();

        SchemaDeploymentGateway.FieldSpec fs = new SchemaDeploymentGateway.FieldSpec();
        fs.objectApiName = 'Account';
        fs.fieldApiName  = 'Pulse_Blob__c';
        fs.fieldLabel    = 'Blob';
        fs.fieldType     = 'Blob';

        Test.startTest();
        SchemaDeploymentGateway.DeploymentPlan plan = gw.buildPlan(
            'Account', 'test_wf',
            new List<SchemaDeploymentGateway.FieldSpec>{ fs }
        );
        Test.stopTest();

        System.assertEquals(false, plan.isValid());
        System.assert(plan.validationErrors[0].contains('Unsupported field type'));
    }

    @IsTest
    static void testDefaultGatewaySkipsExistingFields() {
        // Account.Name already exists — should be skipped, not added to plan
        SchemaProvisioningService.MetadataApiDeploymentGateway gw =
            new SchemaProvisioningService.MetadataApiDeploymentGateway();

        SchemaDeploymentGateway.FieldSpec fs = new SchemaDeploymentGateway.FieldSpec();
        fs.objectApiName = 'Account';
        fs.fieldApiName  = 'Name';
        fs.fieldLabel    = 'Name';
        fs.fieldType     = 'Text';
        fs.length        = 255;

        Test.startTest();
        SchemaDeploymentGateway.DeploymentPlan plan = gw.buildPlan(
            'Account', 'test_wf',
            new List<SchemaDeploymentGateway.FieldSpec>{ fs }
        );
        Test.stopTest();

        System.assertEquals(true, plan.isValid());
        System.assertEquals(0, plan.fields.size(), 'Existing field should be skipped');
    }
}
