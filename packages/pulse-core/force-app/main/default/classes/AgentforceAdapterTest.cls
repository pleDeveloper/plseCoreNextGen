/**
 * AgentforceAdapterTest — exercises the skeleton adapter against
 * mocked HTTP responses. These tests pin the *current contract* of
 * AgentforceAdapter; they do NOT prove the adapter is correct against
 * a real Agentforce org. See docs/agentforce-adapter-status.md.
 */
@IsTest
private class AgentforceAdapterTest {

    @IsTest
    static void testParseSuccessResponseGenerationsArray() {
        String responseBody = '{"id":"gen_001",'
            + '"generations":[{"text":"Hello from Einstein","tokenCount":42}],'
            + '"parameters":{"usage":{"promptTokens":120,"completionTokens":42}}}';

        AgentforceAdapter adapter = new AgentforceAdapter('TestNC', 'sfdc_ai__DefaultLLM');
        PulseAiModels.Response resp = adapter.parseResponse(responseBody);

        System.assertEquals(false, resp.isError, 'Should not be error');
        System.assertEquals('Hello from Einstein', resp.text);
        System.assertEquals('gen_001', resp.providerRequestId);
        System.assertNotEquals(null, resp.usage, 'Usage should be populated');
        System.assertEquals(120, resp.usage.inputTokens);
        System.assertEquals(42, resp.usage.outputTokens);
        System.assert(resp.toolCalls.isEmpty(), 'No tool calls expected');
    }

    @IsTest
    static void testParseSuccessResponseWithFlatUsage() {
        // Alternative shape: flat top-level "usage" with input/output_tokens.
        String responseBody = '{"id":"gen_002",'
            + '"generations":[{"text":"ok"}],'
            + '"usage":{"input_tokens":7,"output_tokens":3}}';

        AgentforceAdapter adapter = new AgentforceAdapter('TestNC', 'sfdc_ai__DefaultLLM');
        PulseAiModels.Response resp = adapter.parseResponse(responseBody);

        System.assertEquals(false, resp.isError);
        System.assertEquals(7, resp.usage.inputTokens);
        System.assertEquals(3, resp.usage.outputTokens);
    }

    @IsTest
    static void testParseToolCallFromFencedJsonBlock() {
        String body = '{"id":"gen_003","generations":[{"text":'
            + '"I will send the email.\\n```json\\n{\\"tool\\":\\"send_email\\",\\"input\\":{\\"toAddress\\":\\"a@b.com\\"}}\\n```"}]}';

        AgentforceAdapter adapter = new AgentforceAdapter('TestNC', 'sfdc_ai__DefaultLLM');
        PulseAiModels.Response resp = adapter.parseResponse(body);

        System.assertEquals(false, resp.isError);
        System.assertEquals(1, resp.toolCalls.size(), 'Should synthesise one ToolCall');
        PulseAiModels.ToolCall tc = resp.toolCalls[0];
        System.assertEquals('send_email', tc.toolKey);
        System.assertNotEquals(null, tc.id, 'Synthesised ToolCall should have an id');

        Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(tc.inputJson);
        System.assertEquals('a@b.com', input.get('toAddress'));
    }

    @IsTest
    static void testParseToolCallFromBareJsonObject() {
        // Some prompts coax the model into emitting bare JSON without a fence.
        String body = '{"generations":[{"text":'
            + '"{\\"tool\\":\\"update_record\\",\\"input\\":{\\"recordId\\":\\"001x\\"}}"}]}';

        AgentforceAdapter adapter = new AgentforceAdapter('TestNC', 'sfdc_ai__DefaultLLM');
        PulseAiModels.Response resp = adapter.parseResponse(body);

        System.assertEquals(1, resp.toolCalls.size());
        System.assertEquals('update_record', resp.toolCalls[0].toolKey);
    }

    @IsTest
    static void testParseMalformedResponse() {
        AgentforceAdapter adapter = new AgentforceAdapter('TestNC', 'sfdc_ai__DefaultLLM');
        PulseAiModels.Response resp = adapter.parseResponse('not json at all');

        System.assertEquals(true, resp.isError);
        System.assert(resp.errorMessage.contains('Failed to parse'), resp.errorMessage);
    }

    @IsTest
    static void testBuildHttpRequestShape() {
        AgentforceAdapter adapter = new AgentforceAdapter('TestNC', 'sfdc_ai__DefaultLLM');

        PulseAiModels.Request req = new PulseAiModels.Request();
        req.systemPrompt = 'You are a Pulse agent.';
        req.messages.add(new PulseAiModels.Message('user', 'Process this lead.'));
        req.maxTokens = 1024;

        req.tools.add(new PulseAiModels.ToolDefinition(
            'send_email', 'Send an email',
            new Map<String, Object>{ 'type' => 'object' }
        ));

        HttpRequest httpReq = adapter.buildHttpRequest(req);

        System.assertEquals(
            'callout:TestNC/services/data/v60.0/einstein/llm/generations',
            httpReq.getEndpoint()
        );
        System.assertEquals('POST', httpReq.getMethod());
        System.assertEquals('application/json', httpReq.getHeader('Content-Type'));

        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(httpReq.getBody());
        System.assertEquals('sfdc_ai__DefaultLLM', body.get('model'));
        System.assertEquals(1024, body.get('max_tokens'));

        String prompt = (String) body.get('prompt');
        System.assert(prompt.contains('[SYSTEM]'), 'System prompt should be inlined');
        System.assert(prompt.contains('You are a Pulse agent.'), prompt);
        System.assert(prompt.contains('[TOOLS]'), 'Tools should be inlined for the skeleton adapter');
        System.assert(prompt.contains('send_email'), prompt);
        System.assert(prompt.contains('[USER]'), 'User messages should be tagged');
    }

    @IsTest
    static void testBuildPromptWithToolResultMessage() {
        AgentforceAdapter adapter = new AgentforceAdapter('TestNC', 'sfdc_ai__DefaultLLM');

        PulseAiModels.Request req = new PulseAiModels.Request();

        PulseAiModels.Message assistantMsg = new PulseAiModels.Message('assistant', 'I will call a tool');
        PulseAiModels.ToolCall tc = new PulseAiModels.ToolCall();
        tc.id = 'tcall_001';
        tc.toolKey = 'send_email';
        tc.inputJson = '{"toAddress":"a@b.com"}';
        assistantMsg.toolCalls = new List<PulseAiModels.ToolCall>{ tc };
        req.messages.add(assistantMsg);

        PulseAiModels.Message toolResultMsg = new PulseAiModels.Message('user', '{"status":"sent"}');
        toolResultMsg.toolCallId = 'tcall_001';
        req.messages.add(toolResultMsg);

        HttpRequest httpReq = adapter.buildHttpRequest(req);
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(httpReq.getBody());
        String prompt = (String) body.get('prompt');

        System.assert(prompt.contains('[ASSISTANT]'), prompt);
        System.assert(prompt.contains('[tool_calls]'), prompt);
        System.assert(prompt.contains('[tool_result id=tcall_001]'), prompt);
    }

    @IsTest
    static void testChatWithMockSuccess() {
        Test.setMock(HttpCalloutMock.class, new AgentforceSuccessMock());

        AgentforceAdapter adapter = new AgentforceAdapter('TestNC', 'sfdc_ai__DefaultLLM');
        PulseAiModels.Request req = new PulseAiModels.Request();
        req.messages.add(new PulseAiModels.Message('user', 'Hello'));

        Test.startTest();
        PulseAiModels.Response resp = adapter.chat(req);
        Test.stopTest();

        System.assertEquals(false, resp.isError, 'Expected success: ' + resp.errorMessage);
        System.assertEquals('Test response from Einstein', resp.text);
        System.assertNotEquals(null, resp.usage);
        System.assertEquals(10, resp.usage.inputTokens);
        System.assertEquals(5, resp.usage.outputTokens);
    }

    @IsTest
    static void testChatWithMockSalesforceErrorEnvelope() {
        Test.setMock(HttpCalloutMock.class, new AgentforceSfErrorMock());

        AgentforceAdapter adapter = new AgentforceAdapter('TestNC', 'sfdc_ai__DefaultLLM');
        PulseAiModels.Request req = new PulseAiModels.Request();
        req.messages.add(new PulseAiModels.Message('user', 'Hello'));

        Test.startTest();
        PulseAiModels.Response resp = adapter.chat(req);
        Test.stopTest();

        System.assertEquals(true, resp.isError);
        System.assert(resp.errorMessage.contains('400'), resp.errorMessage);
        System.assert(resp.errorMessage.contains('INVALID_REQUEST'),
            'Salesforce errorCode should surface: ' + resp.errorMessage);
        System.assert(resp.errorMessage.contains('Bad model'),
            'Error message should surface: ' + resp.errorMessage);
    }

    @IsTest
    static void testChatWithMockModelsApiErrorEnvelope() {
        Test.setMock(HttpCalloutMock.class, new AgentforceModelsErrorMock());

        AgentforceAdapter adapter = new AgentforceAdapter('TestNC', 'sfdc_ai__DefaultLLM');
        PulseAiModels.Request req = new PulseAiModels.Request();
        req.messages.add(new PulseAiModels.Message('user', 'Hello'));

        Test.startTest();
        PulseAiModels.Response resp = adapter.chat(req);
        Test.stopTest();

        System.assertEquals(true, resp.isError);
        System.assert(resp.errorMessage.contains('429'), resp.errorMessage);
        System.assert(resp.errorMessage.contains('rate_limit'),
            'Error code should surface: ' + resp.errorMessage);
        System.assert(resp.errorMessage.contains('Slow down'),
            'Error message should surface: ' + resp.errorMessage);
    }

    @IsTest
    static void testChatWithNonJsonErrorBody() {
        Test.setMock(HttpCalloutMock.class, new AgentforcePlainTextErrorMock());

        AgentforceAdapter adapter = new AgentforceAdapter('TestNC', 'sfdc_ai__DefaultLLM');
        PulseAiModels.Request req = new PulseAiModels.Request();
        req.messages.add(new PulseAiModels.Message('user', 'Hello'));

        Test.startTest();
        PulseAiModels.Response resp = adapter.chat(req);
        Test.stopTest();

        System.assertEquals(true, resp.isError);
        System.assert(resp.errorMessage.contains('500'), resp.errorMessage);
        System.assert(resp.errorMessage.contains('Internal Server Error'),
            'Should include raw body when envelope missing: ' + resp.errorMessage);
    }

    @IsTest
    static void testFacadeResolvesAgentforceAdapter() {
        // Ensure the facade can map Provider_Name__c='Agentforce' to this class.
        AI_Provider_Registration__mdt reg = new AI_Provider_Registration__mdt(
            DeveloperName = 'AgentforceTest',
            Provider_Name__c = 'Agentforce',
            Named_Credential__c = 'TestNC',
            Model_Id__c = 'sfdc_ai__DefaultLLM',
            Active__c = true,
            Priority__c = 1
        );
        PulseAiFacade.setRegistrationsForTest(new List<AI_Provider_Registration__mdt>{ reg });

        // Stub the actual chat call so we don't need a callout here.
        PulseAiFacade.setProviderForTest(new StubProvider());

        PulseAiModels.Request req = new PulseAiModels.Request();
        req.messages.add(new PulseAiModels.Message('user', 'ping'));

        Test.startTest();
        PulseAiModels.Response resp = PulseAiFacade.invoke(req, 'Agentforce');
        Test.stopTest();

        System.assertEquals('stub-ok', resp.text);
        PulseAiFacade.clearProviderForTest();
    }

    private class StubProvider implements PulseAiProvider {
        public void configure(String namedCredential, String modelId) {}
        public PulseAiModels.Response chat(PulseAiModels.Request req) {
            PulseAiModels.Response r = new PulseAiModels.Response();
            r.text = 'stub-ok';
            return r;
        }
    }

    private class AgentforceSuccessMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"id":"gen_test",'
                + '"generations":[{"text":"Test response from Einstein","tokenCount":5}],'
                + '"parameters":{"usage":{"promptTokens":10,"completionTokens":5}}}');
            return res;
        }
    }

    private class AgentforceSfErrorMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(400);
            res.setBody('[{"errorCode":"INVALID_REQUEST","message":"Bad model id"}]');
            return res;
        }
    }

    private class AgentforceModelsErrorMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(429);
            res.setBody('{"error":{"code":"rate_limit","message":"Slow down"}}');
            return res;
        }
    }

    private class AgentforcePlainTextErrorMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(500);
            res.setBody('Internal Server Error');
            return res;
        }
    }
}
