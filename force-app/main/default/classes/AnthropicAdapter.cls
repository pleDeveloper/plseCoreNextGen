public with sharing class AnthropicAdapter implements PulseAiProvider {

    private final String namedCredential;
    private final String defaultModelId;

    public AnthropicAdapter(String namedCredential, String modelId) {
        this.namedCredential = namedCredential;
        this.defaultModelId = modelId;
    }

    public PulseAiProvider.Response chat(PulseAiProvider.Request req) {
        HttpRequest httpReq = buildHttpRequest(req);
        HttpResponse httpRes;

        try {
            httpRes = new Http().send(httpReq);
        } catch (System.CalloutException e) {
            return buildErrorResponse('Callout failed: ' + e.getMessage());
        }

        if (httpRes.getStatusCode() < 200 || httpRes.getStatusCode() >= 300) {
            return buildErrorResponse(
                'API error ' + httpRes.getStatusCode() + ': ' + httpRes.getBody()
            );
        }

        return parseResponse(httpRes.getBody());
    }

    @TestVisible
    private HttpRequest buildHttpRequest(PulseAiProvider.Request req) {
        HttpRequest httpReq = new HttpRequest();
        httpReq.setEndpoint('callout:' + this.namedCredential + '/v1/messages');
        httpReq.setMethod('POST');
        httpReq.setHeader('Content-Type', 'application/json');
        httpReq.setHeader('anthropic-version', '2023-06-01');
        httpReq.setTimeout(120000);

        Map<String, Object> body = new Map<String, Object>();
        body.put('model', String.isNotBlank(req.modelId) ? req.modelId : this.defaultModelId);
        body.put('max_tokens', req.maxTokens != null ? req.maxTokens : 4096);

        if (String.isNotBlank(req.systemPrompt)) {
            body.put('system', req.systemPrompt);
        }

        body.put('messages', buildMessages(req.messages));

        if (req.tools != null && !req.tools.isEmpty()) {
            body.put('tools', buildTools(req.tools));
        }

        httpReq.setBody(JSON.serialize(body));
        return httpReq;
    }

    private List<Object> buildMessages(List<PulseAiProvider.Message> messages) {
        List<Object> result = new List<Object>();
        if (messages == null) {
            return result;
        }

        for (PulseAiProvider.Message msg : messages) {
            Map<String, Object> m = new Map<String, Object>();
            m.put('role', msg.role);

            if (msg.role == 'assistant' && msg.toolCalls != null && !msg.toolCalls.isEmpty()) {
                List<Object> contentBlocks = new List<Object>();
                if (String.isNotBlank(msg.content)) {
                    contentBlocks.add(new Map<String, Object>{
                        'type' => 'text',
                        'text' => msg.content
                    });
                }
                for (PulseAiProvider.ToolCall tc : msg.toolCalls) {
                    contentBlocks.add(new Map<String, Object>{
                        'type' => 'tool_use',
                        'id' => tc.id,
                        'name' => tc.toolKey,
                        'input' => JSON.deserializeUntyped(tc.inputJson)
                    });
                }
                m.put('content', contentBlocks);
            } else if (msg.role == 'user' && String.isNotBlank(msg.toolCallId)) {
                m.put('content', new List<Object>{
                    new Map<String, Object>{
                        'type' => 'tool_result',
                        'tool_use_id' => msg.toolCallId,
                        'content' => msg.content
                    }
                });
            } else {
                m.put('content', msg.content);
            }

            result.add(m);
        }
        return result;
    }

    private List<Object> buildTools(List<PulseAiProvider.ToolDefinition> tools) {
        List<Object> result = new List<Object>();
        for (PulseAiProvider.ToolDefinition td : tools) {
            result.add(new Map<String, Object>{
                'name' => td.name,
                'description' => td.description,
                'input_schema' => td.inputSchema
            });
        }
        return result;
    }

    @TestVisible
    private PulseAiProvider.Response parseResponse(String body) {
        PulseAiProvider.Response resp = new PulseAiProvider.Response();
        resp.rawJson = body;

        Map<String, Object> parsed;
        try {
            parsed = (Map<String, Object>) JSON.deserializeUntyped(body);
        } catch (Exception e) {
            resp.isError = true;
            resp.errorMessage = 'Failed to parse response: ' + e.getMessage();
            return resp;
        }

        resp.providerRequestId = (String) parsed.get('id');

        Map<String, Object> usageMap = (Map<String, Object>) parsed.get('usage');
        if (usageMap != null) {
            resp.usage = new PulseAiProvider.Usage();
            resp.usage.inputTokens = (Integer) usageMap.get('input_tokens');
            resp.usage.outputTokens = (Integer) usageMap.get('output_tokens');
        }

        List<Object> content = (List<Object>) parsed.get('content');
        if (content != null) {
            for (Object block : content) {
                Map<String, Object> b = (Map<String, Object>) block;
                String blockType = (String) b.get('type');

                if (blockType == 'text') {
                    resp.text = (String) b.get('text');
                } else if (blockType == 'tool_use') {
                    PulseAiProvider.ToolCall tc = new PulseAiProvider.ToolCall();
                    tc.id = (String) b.get('id');
                    tc.toolKey = (String) b.get('name');
                    Object inputObj = b.get('input');
                    tc.inputJson = inputObj != null ? JSON.serialize(inputObj) : '{}';
                    resp.toolCalls.add(tc);
                }
            }
        }

        return resp;
    }

    private PulseAiProvider.Response buildErrorResponse(String message) {
        PulseAiProvider.Response resp = new PulseAiProvider.Response();
        resp.isError = true;
        resp.errorMessage = message;
        return resp;
    }
}
