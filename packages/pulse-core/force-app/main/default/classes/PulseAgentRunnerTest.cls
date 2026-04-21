@IsTest
private class PulseAgentRunnerTest {

    @TestSetup
    static void setup() {
        Workflow_Definition__c def = new Workflow_Definition__c(
            Workflow_Key__c = 'runner_test_wf',
            Version__c = 1,
            Status__c = 'Published',
            Definition_JSON__c = '{"schema":"pulse.workflow.v1","states":[]}',
            Subject_Kinds__c = 'Account'
        );
        insert def;

        Workflow_Instance__c inst = new Workflow_Instance__c(
            Workflow_Definition__c = def.Id,
            Current_State__c = 'intake',
            Status__c = 'Active',
            Context_JSON__c = '{"patient":"John Doe"}',
            Parent_Object_Type__c = 'Account'
        );
        insert inst;
    }

    private static Id getInstanceId() {
        return [SELECT Id FROM Workflow_Instance__c LIMIT 1].Id;
    }

    @IsTest
    static void testRunWithTextOnlyResponse() {
        PulseAiFacade.setProviderForTest(new MockProvider('text_only'));
        PulseToolRegistry.clearForTest();

        Test.startTest();
        PulseAgentRunner.RunResult result = PulseAgentRunner.run(getInstanceId());
        Test.stopTest();

        System.assertEquals(true, result.success);
        System.assertEquals('I have analyzed the context.', result.responseText);
        System.assert(result.pendingApprovals.isEmpty());

        List<Workflow_Event__c> events = [
            SELECT Event_Type__c FROM Workflow_Event__c
        ];
        Boolean hasAiCall = false;
        for (Workflow_Event__c e : events) {
            if (e.Event_Type__c == 'AI_CALL') { hasAiCall = true; }
        }
        System.assert(hasAiCall, 'Should have AI_CALL audit event');
    }

    @IsTest
    static void testRunWithAutonomousTool() {
        PulseAiFacade.setProviderForTest(new MockProvider('autonomous_tool'));
        PulseToolRegistry.clearForTest();
        PulseToolRegistry.registerToolForTest('update_record', new StubTool('update_record', 'Autonomous'));

        Test.startTest();
        PulseAgentRunner.RunResult result = PulseAgentRunner.run(getInstanceId());
        Test.stopTest();

        System.assertEquals(true, result.success);

        List<Workflow_Event__c> events = [
            SELECT Event_Type__c FROM Workflow_Event__c ORDER BY CreatedDate
        ];
        Boolean hasExecuted = false;
        for (Workflow_Event__c e : events) {
            if (e.Event_Type__c == 'TOOL_EXECUTED') { hasExecuted = true; }
        }
        System.assert(hasExecuted, 'Should have TOOL_EXECUTED event');
    }

    @IsTest
    static void testRunWithApprovalRequired() {
        PulseAiFacade.setProviderForTest(new MockProvider('approval_tool'));
        PulseToolRegistry.clearForTest();
        PulseToolRegistry.registerToolForTest('send_email', new StubTool('send_email', 'Approval_Required'));

        Test.startTest();
        PulseAgentRunner.RunResult result = PulseAgentRunner.run(getInstanceId());
        Test.stopTest();

        System.assertEquals(true, result.success);

        List<Workflow_Action__c> actions = [
            SELECT Status__c, Tool_Key__c, HITL_Policy__c FROM Workflow_Action__c
        ];
        System.assertEquals(1, actions.size());
        System.assertEquals('Pending', actions[0].Status__c);
        System.assertEquals('send_email', actions[0].Tool_Key__c);
        System.assertEquals('Approval_Required', actions[0].HITL_Policy__c);

        List<Workflow_Event__c> events = [
            SELECT Event_Type__c FROM Workflow_Event__c
        ];
        Boolean hasApprovalReq = false;
        for (Workflow_Event__c e : events) {
            if (e.Event_Type__c == 'TOOL_APPROVAL_REQUESTED') { hasApprovalReq = true; }
        }
        System.assert(hasApprovalReq, 'Should have TOOL_APPROVAL_REQUESTED event');
    }

    @IsTest
    static void testRunWithAiError() {
        PulseAiFacade.setProviderForTest(new MockProvider('error'));
        PulseToolRegistry.clearForTest();

        Test.startTest();
        PulseAgentRunner.RunResult result = PulseAgentRunner.run(getInstanceId());
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assert(result.errorMessage.contains('Provider error'));

        List<Workflow_Event__c> events = [
            SELECT Event_Type__c FROM Workflow_Event__c
        ];
        Boolean hasAiError = false;
        for (Workflow_Event__c e : events) {
            if (e.Event_Type__c == 'AI_ERROR') { hasAiError = true; }
        }
        System.assert(hasAiError, 'Should have AI_ERROR event');
    }

    @IsTest
    static void testRunInactiveInstance() {
        Workflow_Instance__c inst = [SELECT Id, Status__c FROM Workflow_Instance__c LIMIT 1];
        inst.Status__c = 'Completed';
        update inst;

        PulseAiFacade.setProviderForTest(new MockProvider('text_only'));

        Test.startTest();
        PulseAgentRunner.RunResult result = PulseAgentRunner.run(inst.Id);
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assert(result.errorMessage.contains('not active'));
    }

    @IsTest
    static void testRunWithMalformedToolInput() {
        PulseAiFacade.setProviderForTest(new MockProvider('malformed_input'));
        PulseToolRegistry.clearForTest();
        PulseToolRegistry.registerToolForTest('send_email', new StubTool('send_email', 'Autonomous'));

        Test.startTest();
        PulseAgentRunner.RunResult result = PulseAgentRunner.run(getInstanceId());
        Test.stopTest();

        System.assertEquals(true, result.success);

        List<Workflow_Event__c> events = [
            SELECT Event_Type__c FROM Workflow_Event__c
        ];
        Boolean hasInvalid = false;
        for (Workflow_Event__c e : events) {
            if (e.Event_Type__c == 'TOOL_INVALID_INPUT') { hasInvalid = true; }
        }
        System.assert(hasInvalid, 'Should have TOOL_INVALID_INPUT event');
    }

    @IsTest
    static void testRunWithDisabledTool() {
        PulseAiFacade.setProviderForTest(new MockProvider('disabled_tool'));
        PulseToolRegistry.clearForTest();
        PulseToolRegistry.registerToolForTest('send_email', new StubTool('send_email', 'Disabled'));

        Test.startTest();
        PulseAgentRunner.RunResult result = PulseAgentRunner.run(getInstanceId());
        Test.stopTest();

        System.assertEquals(true, result.success);

        List<Workflow_Event__c> events = [
            SELECT Event_Type__c FROM Workflow_Event__c
        ];
        Boolean hasDisabled = false;
        for (Workflow_Event__c e : events) {
            if (e.Event_Type__c == 'TOOL_DISABLED') { hasDisabled = true; }
        }
        System.assert(hasDisabled, 'Should have TOOL_DISABLED event');
    }

    @IsTest
    static void testRunWithToolNotFound() {
        PulseAiFacade.setProviderForTest(new MockProvider('autonomous_tool'));
        PulseToolRegistry.clearForTest();
        // Do not register 'update_record' — it should produce TOOL_NOT_FOUND

        Test.startTest();
        PulseAgentRunner.RunResult result = PulseAgentRunner.run(getInstanceId());
        Test.stopTest();

        System.assertEquals(true, result.success);

        List<Workflow_Event__c> events = [
            SELECT Event_Type__c FROM Workflow_Event__c
        ];
        Boolean hasNotFound = false;
        for (Workflow_Event__c e : events) {
            if (e.Event_Type__c == 'TOOL_NOT_FOUND') { hasNotFound = true; }
        }
        System.assert(hasNotFound, 'Should have TOOL_NOT_FOUND event');
    }

    @IsTest
    static void testRunWithReviewAfterPolicy() {
        PulseAiFacade.setProviderForTest(new MockProvider('autonomous_tool'));
        PulseToolRegistry.clearForTest();
        PulseToolRegistry.registerToolForTest('update_record', new StubTool('update_record', 'Review_After'));

        Test.startTest();
        PulseAgentRunner.RunResult result = PulseAgentRunner.run(getInstanceId());
        Test.stopTest();

        System.assertEquals(true, result.success);

        // Tool executes immediately AND creates a review action
        List<Workflow_Event__c> events = [
            SELECT Event_Type__c FROM Workflow_Event__c
        ];
        Boolean hasExecuted = false;
        for (Workflow_Event__c e : events) {
            if (e.Event_Type__c == 'TOOL_EXECUTED') { hasExecuted = true; }
        }
        System.assert(hasExecuted, 'Should have TOOL_EXECUTED event');

        List<Workflow_Action__c> actions = [
            SELECT Status__c, HITL_Policy__c FROM Workflow_Action__c
        ];
        System.assertEquals(1, actions.size());
        System.assertEquals('Executed', actions[0].Status__c);
        System.assertEquals('Review_After', actions[0].HITL_Policy__c);
    }

    // ─── Mock Provider ────────────────────────────────────────────

    private class MockProvider implements PulseAiProvider {
        private String scenario;
        MockProvider(String scenario) { this.scenario = scenario; }

        public void configure(String namedCredential, String modelId) {}

        public PulseAiModels.Response chat(PulseAiModels.Request req) {
            PulseAiModels.Response resp = new PulseAiModels.Response();
            resp.providerRequestId = 'mock_req_123';
            resp.usage = new PulseAiModels.Usage();
            resp.usage.inputTokens = 10;
            resp.usage.outputTokens = 5;

            if (scenario == 'text_only') {
                resp.text = 'I have analyzed the context.';
            } else if (scenario == 'autonomous_tool') {
                resp.text = 'I will update the record.';
                PulseAiModels.ToolCall tc = new PulseAiModels.ToolCall();
                tc.id = 'toolu_001';
                tc.toolKey = 'update_record';
                tc.inputJson = '{"recordId":"001000000000001","objectType":"Account","fields":{"Name":"Test"}}';
                resp.toolCalls.add(tc);
            } else if (scenario == 'approval_tool') {
                resp.text = 'I will send an email.';
                PulseAiModels.ToolCall tc = new PulseAiModels.ToolCall();
                tc.id = 'toolu_002';
                tc.toolKey = 'send_email';
                tc.inputJson = '{"toAddress":"test@test.com","subject":"Hi","body":"Hello"}';
                resp.toolCalls.add(tc);
            } else if (scenario == 'error') {
                resp.isError = true;
                resp.errorMessage = 'Provider error: timeout';
            } else if (scenario == 'malformed_input') {
                PulseAiModels.ToolCall tc = new PulseAiModels.ToolCall();
                tc.id = 'toolu_003';
                tc.toolKey = 'send_email';
                tc.inputJson = 'not valid json [[[';
                resp.toolCalls.add(tc);
            } else if (scenario == 'disabled_tool') {
                PulseAiModels.ToolCall tc = new PulseAiModels.ToolCall();
                tc.id = 'toolu_004';
                tc.toolKey = 'send_email';
                tc.inputJson = '{}';
                resp.toolCalls.add(tc);
            }
            return resp;
        }
    }

    // ─── Stub Tool ────────────────────────────────────────────────

    private class StubTool implements PulseTool {
        private String key;
        private String policy;
        StubTool(String key, String policy) {
            this.key = key;
            this.policy = policy;
        }
        public String getToolKey() { return key; }
        public String getDescription() { return 'Stub tool for testing'; }
        public Map<String, Object> getInputSchema() {
            return new Map<String, Object>{ 'type' => 'object' };
        }
        public String getDefaultHitlPolicy() { return policy; }
        public PulseToolModels.Result execute(PulseToolModels.Context ctx) {
            return PulseToolModels.ok('{"status":"done"}');
        }
    }
}
