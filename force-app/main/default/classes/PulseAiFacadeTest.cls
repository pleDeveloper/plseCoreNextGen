@IsTest
private class PulseAiFacadeTest {

    @TestSetup
    static void setup() {
        Workflow_Definition__c def = new Workflow_Definition__c(
            Workflow_Key__c = 'facade_test_wf',
            Version__c = 1,
            Status__c = 'Published',
            Definition_JSON__c = '{"schema":"pulse.workflow.v1"}',
            Subject_Kinds__c = 'Account'
        );
        insert def;

        Workflow_Instance__c inst = new Workflow_Instance__c(
            Workflow_Definition__c = def.Id,
            Current_State__c = 'review',
            Status__c = 'Active',
            Context_JSON__c = '{"notes":"test context"}',
            Parent_Object_Type__c = 'Account'
        );
        insert inst;
    }

    @IsTest
    static void testBuildRequest() {
        Workflow_Instance__c inst = [
            SELECT Id, Current_State__c, Context_JSON__c,
                   Workflow_Definition__r.Workflow_Key__c
            FROM Workflow_Instance__c LIMIT 1
        ];

        PulseToolRegistry.clearForTest();
        PulseToolRegistry.registerToolForTest('send_email', new PulseEmailTool());

        Test.startTest();
        PulseAiModels.Request req = PulseAiFacade.buildRequest(inst);
        Test.stopTest();

        System.assert(req.systemPrompt.contains('facade_test_wf'),
            'System prompt should reference workflow key');
        System.assert(req.systemPrompt.contains('review'),
            'System prompt should reference current state');
        System.assertEquals(1, req.messages.size());
        System.assert(req.messages[0].content.contains('test context'));
        System.assertEquals(1, req.tools.size());
        System.assertEquals('send_email', req.tools[0].name);
    }

    @IsTest
    static void testBuildRequestWithEmptyContext() {
        Workflow_Instance__c inst = [
            SELECT Id, Current_State__c, Context_JSON__c,
                   Workflow_Definition__r.Workflow_Key__c
            FROM Workflow_Instance__c LIMIT 1
        ];
        inst.Context_JSON__c = null;
        // Do not update — just test buildRequest with null context
        update inst;

        inst = [
            SELECT Id, Current_State__c, Context_JSON__c,
                   Workflow_Definition__r.Workflow_Key__c
            FROM Workflow_Instance__c LIMIT 1
        ];

        PulseToolRegistry.clearForTest();

        Test.startTest();
        PulseAiModels.Request req = PulseAiFacade.buildRequest(inst);
        Test.stopTest();

        System.assert(req.messages[0].content.contains('{}'),
            'Should default to empty JSON object');
    }

    @IsTest
    static void testInvokeWithMockProvider() {
        PulseAiFacade.setProviderForTest(new MockTextProvider());

        PulseAiModels.Request req = new PulseAiModels.Request();
        req.messages.add(new PulseAiModels.Message('user', 'test'));

        Test.startTest();
        PulseAiModels.Response resp = PulseAiFacade.invoke(req);
        Test.stopTest();

        System.assertEquals(false, resp.isError);
        System.assertEquals('Mocked response', resp.text);
    }

    @IsTest
    static void testNoProviderConfigured() {
        PulseAiFacade.clearProviderForTest();

        PulseAiModels.Request req = new PulseAiModels.Request();
        req.messages.add(new PulseAiModels.Message('user', 'test'));

        Test.startTest();
        try {
            PulseAiFacade.invoke(req);
            System.assert(false, 'Should have thrown PulseAiException');
        } catch (PulseAiFacade.PulseAiException e) {
            System.assert(e.getMessage().contains('No active AI provider'));
        }
        Test.stopTest();
    }

    private class MockTextProvider implements PulseAiProvider {
        public PulseAiModels.Response chat(PulseAiModels.Request req) {
            PulseAiModels.Response resp = new PulseAiModels.Response();
            resp.text = 'Mocked response';
            resp.providerRequestId = 'mock_123';
            resp.usage = new PulseAiModels.Usage();
            resp.usage.inputTokens = 5;
            resp.usage.outputTokens = 3;
            return resp;
        }
    }
}
