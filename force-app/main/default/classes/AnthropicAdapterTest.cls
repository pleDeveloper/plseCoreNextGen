@IsTest
private class AnthropicAdapterTest {

    @IsTest
    static void testParseSuccessResponse() {
        String responseBody = '{"id":"msg_123","type":"message","role":"assistant",'
            + '"content":[{"type":"text","text":"Here is my response"}],'
            + '"usage":{"input_tokens":100,"output_tokens":50}}';

        AnthropicAdapter adapter = new AnthropicAdapter('TestCredential', 'claude-sonnet-4-20250514');
        PulseAiProvider.Response resp = adapter.parseResponse(responseBody);

        System.assertEquals(false, resp.isError, 'Should not be error');
        System.assertEquals('Here is my response', resp.text);
        System.assertEquals('msg_123', resp.providerRequestId);
        System.assertEquals(100, resp.usage.inputTokens);
        System.assertEquals(50, resp.usage.outputTokens);
        System.assert(resp.toolCalls.isEmpty(), 'No tool calls expected');
    }

    @IsTest
    static void testParseToolUseResponse() {
        String responseBody = '{"id":"msg_456","type":"message","role":"assistant",'
            + '"content":[{"type":"text","text":"I will send an email"},'
            + '{"type":"tool_use","id":"toolu_001","name":"send_email",'
            + '"input":{"toAddress":"test@example.com","subject":"Hello","body":"World"}}],'
            + '"usage":{"input_tokens":200,"output_tokens":100}}';

        AnthropicAdapter adapter = new AnthropicAdapter('TestCredential', 'claude-sonnet-4-20250514');
        PulseAiProvider.Response resp = adapter.parseResponse(responseBody);

        System.assertEquals(false, resp.isError);
        System.assertEquals('I will send an email', resp.text);
        System.assertEquals(1, resp.toolCalls.size());

        PulseAiProvider.ToolCall tc = resp.toolCalls[0];
        System.assertEquals('toolu_001', tc.id);
        System.assertEquals('send_email', tc.toolKey);

        Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(tc.inputJson);
        System.assertEquals('test@example.com', input.get('toAddress'));
    }

    @IsTest
    static void testParseMalformedResponse() {
        AnthropicAdapter adapter = new AnthropicAdapter('TestCredential', 'claude-sonnet-4-20250514');
        PulseAiProvider.Response resp = adapter.parseResponse('not json at all');

        System.assertEquals(true, resp.isError);
        System.assert(resp.errorMessage.contains('Failed to parse'), resp.errorMessage);
    }

    @IsTest
    static void testBuildHttpRequest() {
        AnthropicAdapter adapter = new AnthropicAdapter('TestCredential', 'claude-sonnet-4-20250514');

        PulseAiProvider.Request req = new PulseAiProvider.Request();
        req.systemPrompt = 'You are a test assistant';
        req.messages.add(new PulseAiProvider.Message('user', 'Hello'));
        req.maxTokens = 1024;

        PulseAiProvider.ToolDefinition toolDef = new PulseAiProvider.ToolDefinition(
            'send_email', 'Send an email',
            new Map<String, Object>{ 'type' => 'object' }
        );
        req.tools.add(toolDef);

        HttpRequest httpReq = adapter.buildHttpRequest(req);

        System.assertEquals('callout:TestCredential/v1/messages', httpReq.getEndpoint());
        System.assertEquals('POST', httpReq.getMethod());
        System.assertEquals('application/json', httpReq.getHeader('Content-Type'));
        System.assertEquals('2023-06-01', httpReq.getHeader('anthropic-version'));

        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(httpReq.getBody());
        System.assertEquals('claude-sonnet-4-20250514', body.get('model'));
        System.assertEquals(1024, body.get('max_tokens'));
        System.assertEquals('You are a test assistant', body.get('system'));
    }

    @IsTest
    static void testBuildHttpRequestWithToolResultMessage() {
        AnthropicAdapter adapter = new AnthropicAdapter('TestCred', 'claude-sonnet-4-20250514');

        PulseAiProvider.Request req = new PulseAiProvider.Request();

        PulseAiProvider.Message assistantMsg = new PulseAiProvider.Message('assistant', 'I will call a tool');
        PulseAiProvider.ToolCall tc = new PulseAiProvider.ToolCall();
        tc.id = 'toolu_001';
        tc.toolKey = 'send_email';
        tc.inputJson = '{"toAddress":"a@b.com"}';
        assistantMsg.toolCalls = new List<PulseAiProvider.ToolCall>{ tc };
        req.messages.add(assistantMsg);

        PulseAiProvider.Message toolResultMsg = new PulseAiProvider.Message('user', '{"status":"sent"}');
        toolResultMsg.toolCallId = 'toolu_001';
        req.messages.add(toolResultMsg);

        HttpRequest httpReq = adapter.buildHttpRequest(req);
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(httpReq.getBody());
        List<Object> messages = (List<Object>) body.get('messages');
        System.assertEquals(2, messages.size());
    }

    @IsTest
    static void testChatWithMockSuccess() {
        Test.setMock(HttpCalloutMock.class, new AnthropicSuccessMock());

        AnthropicAdapter adapter = new AnthropicAdapter('TestCredential', 'claude-sonnet-4-20250514');
        PulseAiProvider.Request req = new PulseAiProvider.Request();
        req.messages.add(new PulseAiProvider.Message('user', 'Hello'));

        Test.startTest();
        PulseAiProvider.Response resp = adapter.chat(req);
        Test.stopTest();

        System.assertEquals(false, resp.isError);
        System.assertEquals('Test response', resp.text);
    }

    @IsTest
    static void testChatWithMockApiError() {
        Test.setMock(HttpCalloutMock.class, new AnthropicErrorMock());

        AnthropicAdapter adapter = new AnthropicAdapter('TestCredential', 'claude-sonnet-4-20250514');
        PulseAiProvider.Request req = new PulseAiProvider.Request();
        req.messages.add(new PulseAiProvider.Message('user', 'Hello'));

        Test.startTest();
        PulseAiProvider.Response resp = adapter.chat(req);
        Test.stopTest();

        System.assertEquals(true, resp.isError);
        System.assert(resp.errorMessage.contains('429'), resp.errorMessage);
    }

    @IsTest
    static void testParseResponseMultipleToolUse() {
        String responseBody = '{"id":"msg_789","type":"message","role":"assistant",'
            + '"content":['
            + '{"type":"tool_use","id":"toolu_a","name":"send_email","input":{"toAddress":"a@b.com"}},'
            + '{"type":"tool_use","id":"toolu_b","name":"update_record","input":{"recordId":"001x"}}'
            + '],"usage":{"input_tokens":50,"output_tokens":25}}';

        AnthropicAdapter adapter = new AnthropicAdapter('TestCred', 'claude-sonnet-4-20250514');
        PulseAiProvider.Response resp = adapter.parseResponse(responseBody);

        System.assertEquals(2, resp.toolCalls.size());
        System.assertEquals('send_email', resp.toolCalls[0].toolKey);
        System.assertEquals('update_record', resp.toolCalls[1].toolKey);
    }

    private class AnthropicSuccessMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"id":"msg_test","type":"message","role":"assistant",'
                + '"content":[{"type":"text","text":"Test response"}],'
                + '"usage":{"input_tokens":10,"output_tokens":5}}');
            return res;
        }
    }

    private class AnthropicErrorMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(429);
            res.setBody('{"error":{"type":"rate_limit_error","message":"Too many requests"}}');
            return res;
        }
    }
}
