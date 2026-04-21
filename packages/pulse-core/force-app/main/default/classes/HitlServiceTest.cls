@IsTest
private class HitlServiceTest {

    @TestSetup
    static void setup() {
        Workflow_Definition__c def = new Workflow_Definition__c(
            Workflow_Key__c = 'hitl_test_wf',
            Version__c = 1,
            Status__c = 'Published',
            Definition_JSON__c = '{"schema":"pulse.workflow.v1"}',
            Subject_Kinds__c = 'Account'
        );
        insert def;

        Workflow_Instance__c inst = new Workflow_Instance__c(
            Workflow_Definition__c = def.Id,
            Current_State__c = 'step_one',
            Status__c = 'Active',
            Parent_Object_Type__c = 'Account'
        );
        insert inst;
    }

    private static Workflow_Instance__c getInstance() {
        return [SELECT Id FROM Workflow_Instance__c LIMIT 1];
    }

    @IsTest
    static void testCreateApproval() {
        Workflow_Instance__c inst = getInstance();

        Test.startTest();
        Workflow_Action__c action = HitlService.createApproval(
            inst.Id, 'send_email', '{"toAddress":"test@test.com"}', 'Approval_Required'
        );
        Test.stopTest();

        System.assertNotEquals(null, action.Id);
        Workflow_Action__c reloaded = [
            SELECT Status__c, Tool_Key__c, HITL_Policy__c, Action_Type__c
            FROM Workflow_Action__c WHERE Id = :action.Id
        ];
        System.assertEquals('Pending', reloaded.Status__c);
        System.assertEquals('send_email', reloaded.Tool_Key__c);
        System.assertEquals('Approval_Required', reloaded.HITL_Policy__c);
        System.assertEquals('AI_Tool_Call', reloaded.Action_Type__c);
    }

    @IsTest
    static void testResolveApprovalRejected() {
        Workflow_Instance__c inst = getInstance();
        Workflow_Action__c action = HitlService.createApproval(
            inst.Id, 'send_email', '{}', 'Approval_Required'
        );

        Test.startTest();
        PulseToolModels.Result result = HitlService.resolveApproval(
            action.Id, false, UserInfo.getUserId()
        );
        Test.stopTest();

        System.assertEquals(true, result.success);
        Workflow_Action__c reloaded = [
            SELECT Status__c, Resolved_By__c FROM Workflow_Action__c WHERE Id = :action.Id
        ];
        System.assertEquals('Rejected', reloaded.Status__c);
        System.assertEquals(UserInfo.getUserId(), reloaded.Resolved_By__c);

        List<Workflow_Event__c> events = [
            SELECT Event_Type__c FROM Workflow_Event__c
            WHERE Workflow_Instance__c = :inst.Id
        ];
        System.assert(!events.isEmpty(), 'Should have audit event');
        System.assertEquals('TOOL_REJECTED', events[0].Event_Type__c);
    }

    @IsTest
    static void testResolveApprovalAlreadyResolved() {
        Workflow_Instance__c inst = getInstance();
        Workflow_Action__c action = HitlService.createApproval(
            inst.Id, 'send_email', '{}', 'Approval_Required'
        );
        action.Status__c = 'Executed';
        update action;

        Test.startTest();
        PulseToolModels.Result result = HitlService.resolveApproval(
            action.Id, true, UserInfo.getUserId()
        );
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assert(result.errorMessage.contains('not Pending'));
    }

    @IsTest
    static void testResolveApprovalToolNotFound() {
        PulseToolRegistry.clearForTest();
        Workflow_Instance__c inst = getInstance();
        Workflow_Action__c action = HitlService.createApproval(
            inst.Id, 'nonexistent_tool', '{}', 'Approval_Required'
        );

        Test.startTest();
        PulseToolModels.Result result = HitlService.resolveApproval(
            action.Id, true, UserInfo.getUserId()
        );
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assert(result.errorMessage.contains('Tool not found'));

        Workflow_Action__c reloaded = [
            SELECT Status__c FROM Workflow_Action__c WHERE Id = :action.Id
        ];
        System.assertEquals('Failed', reloaded.Status__c);
    }

    @IsTest
    static void testResolveApprovalExecuteSuccess() {
        PulseToolRegistry.clearForTest();
        PulseToolRegistry.registerToolForTest('stub_tool', new SuccessStubTool());

        Workflow_Instance__c inst = getInstance();
        Workflow_Action__c action = HitlService.createApproval(
            inst.Id, 'stub_tool', '{"key":"value"}', 'Approval_Required'
        );

        Test.startTest();
        PulseToolModels.Result result = HitlService.resolveApproval(
            action.Id, true, UserInfo.getUserId()
        );
        Test.stopTest();

        System.assertEquals(true, result.success);

        Workflow_Action__c reloaded = [
            SELECT Status__c, Response_JSON__c FROM Workflow_Action__c WHERE Id = :action.Id
        ];
        System.assertEquals('Executed', reloaded.Status__c);

        List<Workflow_Event__c> events = [
            SELECT Event_Type__c FROM Workflow_Event__c
            WHERE Workflow_Instance__c = :inst.Id AND Event_Type__c = 'TOOL_EXECUTED'
        ];
        System.assertEquals(1, events.size());
    }

    @IsTest
    static void testWriteAuditEvent() {
        Workflow_Instance__c inst = getInstance();

        Test.startTest();
        HitlService.writeAuditEvent(inst.Id, 'TEST_EVENT', 'test_tool', '{"key":"value"}');
        Test.stopTest();

        Workflow_Event__c evt = [
            SELECT Event_Type__c, Actor_Type__c, Detail_JSON__c
            FROM Workflow_Event__c
            WHERE Workflow_Instance__c = :inst.Id LIMIT 1
        ];
        System.assertEquals('TEST_EVENT', evt.Event_Type__c);
        System.assertEquals('AI', evt.Actor_Type__c);
    }

    @IsTest
    static void testBulkCreateApprovals() {
        Workflow_Instance__c inst = getInstance();
        List<Workflow_Action__c> actions = new List<Workflow_Action__c>();
        for (Integer i = 0; i < 5; i++) {
            actions.add(new Workflow_Action__c(
                Workflow_Instance__c = inst.Id,
                Tool_Key__c = 'send_email',
                Action_Type__c = 'AI_Tool_Call',
                HITL_Policy__c = 'Approval_Required',
                Request_JSON__c = '{}',
                Status__c = 'Pending'
            ));
        }

        Test.startTest();
        HitlService.createApprovals(actions);
        Test.stopTest();

        Integer count = [SELECT COUNT() FROM Workflow_Action__c WHERE Workflow_Instance__c = :inst.Id];
        System.assertEquals(5, count);
    }

    @IsTest
    static void testEvaluatePolicy() {
        PulseToolRegistry.clearForTest();
        PulseToolRegistry.registerToolForTest('send_email', new PulseEmailTool());

        String policy = HitlService.evaluatePolicy('send_email', null);
        System.assertEquals('Approval_Required', policy);
    }

    private class SuccessStubTool implements PulseTool {
        public String getToolKey() { return 'stub_tool'; }
        public String getDescription() { return 'Stub'; }
        public Map<String, Object> getInputSchema() {
            return new Map<String, Object>{ 'type' => 'object' };
        }
        public String getDefaultHitlPolicy() { return 'Approval_Required'; }
        public PulseToolModels.Result execute(PulseToolModels.Context ctx) {
            return PulseToolModels.ok('{"status":"done"}');
        }
    }
}
