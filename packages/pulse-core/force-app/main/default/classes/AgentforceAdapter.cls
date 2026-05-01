/**
 * AgentforceAdapter — routes Pulse agent calls through Salesforce's
 * Einstein / Agentforce Models API.
 *
 * Lives in pulse-core (not a separate add-on package) because Agentforce
 * is Salesforce-native and always available wherever pulse-core is
 * installed; subscriber orgs that skip the Anthropic add-on still need
 * a working AI provider out of the box.
 *
 * STATUS: SKELETON — see docs/agentforce-adapter-status.md.
 *
 * Validated:
 *   - implements PulseAiProvider
 *   - configure() / chat() shape matches AnthropicAdapter
 *   - error envelope handling, malformed JSON handling, mock callouts (tests)
 *
 * Assumed (not yet verified against a live org):
 *   - Endpoint shape: callout:<NC>/services/data/v60.0/einstein/llm/generations
 *   - Request body keys: model, prompt (assembled from system + messages),
 *     locale, num_generations, max_tokens
 *   - Response body shape:
 *       { "id": "...",
 *         "generations": [ { "text": "...", "tokenCount": N } ],
 *         "parameters": { "usage": { "promptTokens": N, "completionTokens": N } } }
 *   - Tool use: Einstein generations endpoint does NOT (today) speak the
 *     same tool_use schema as Anthropic. We therefore serialise tool
 *     definitions into the prompt and parse a fenced ```json block in
 *     the response as a synthesised ToolCall. When Salesforce ships
 *     first-class tool calling on the Models API, swap parseResponse()
 *     and the prompt assembly accordingly.
 *
 * Each unverified assumption is tagged `// TODO(agentforce):` so the
 * next engineer with a real org can confirm or correct.
 */
global with sharing class AgentforceAdapter implements PulseAiProvider {

    // TODO(agentforce): confirm correct API version once validated against a live org.
    // The Models API surface has shifted across releases; v60.0 is the
    // version documented in early Agentforce GA materials.
    @TestVisible
    private static final String API_VERSION = 'v60.0';

    private String namedCredential;
    private String defaultModelId;

    global AgentforceAdapter() {}

    global AgentforceAdapter(String namedCredential, String modelId) {
        configure(namedCredential, modelId);
    }

    public void configure(String namedCredential, String modelId) {
        this.namedCredential = namedCredential;
        this.defaultModelId = modelId;
    }

    public PulseAiModels.Response chat(PulseAiModels.Request req) {
        HttpRequest httpReq = buildHttpRequest(req);
        HttpResponse httpRes;

        try {
            httpRes = new Http().send(httpReq);
        } catch (System.CalloutException e) {
            return buildErrorResponse('Callout failed: ' + e.getMessage());
        }

        if (httpRes.getStatusCode() < 200 || httpRes.getStatusCode() >= 300) {
            return buildErrorResponse(formatApiError(httpRes));
        }

        return parseResponse(httpRes.getBody());
    }

    @TestVisible
    private HttpRequest buildHttpRequest(PulseAiModels.Request req) {
        HttpRequest httpReq = new HttpRequest();

        String modelId = String.isNotBlank(req.modelId) ? req.modelId : this.defaultModelId;

        // TODO(agentforce): verify the exact endpoint path. Two shapes are
        // documented in different Salesforce sources:
        //   1) /services/data/{v}/einstein/llm/generations    (model in body)
        //   2) /services/data/{v}/einstein/llm/models/{model}/generations
        // We use shape (1) here for symmetry with REST tooling. Swap to
        // shape (2) by changing the endpoint string and removing 'model'
        // from the body.
        httpReq.setEndpoint('callout:' + this.namedCredential
            + '/services/data/' + API_VERSION + '/einstein/llm/generations');
        httpReq.setMethod('POST');
        httpReq.setHeader('Content-Type', 'application/json');
        httpReq.setHeader('Accept', 'application/json');
        // TODO(agentforce): confirm header name. Some Models API endpoints
        // require 'x-sfdc-app-context: EinsteinGPT' / 'x-client-feature-id'.
        httpReq.setHeader('x-sfdc-app-context', 'EinsteinGPT');
        httpReq.setHeader('x-client-feature-id', 'ai-platform-models-connected-app');
        httpReq.setTimeout(120000);

        Map<String, Object> body = new Map<String, Object>();
        if (String.isNotBlank(modelId)) {
            body.put('model', modelId);
        }
        body.put('prompt', assemblePrompt(req));
        body.put('locale', 'en_US');
        body.put('num_generations', 1);
        body.put('max_tokens', req.maxTokens != null ? req.maxTokens : 4096);

        // TODO(agentforce): when first-class tool calling lands on the Models
        // API, replace this with a structured 'tools' field. Until then we
        // bake tool descriptors into the prompt and parse a JSON block out
        // of the response (see parseResponse).
        httpReq.setBody(JSON.serialize(body));
        return httpReq;
    }

    /**
     * Flattens system prompt + messages + tool catalog into a single
     * prompt string. This is a stop-gap until the Models API speaks
     * structured chat + tool messages.
     */
    @TestVisible
    private String assemblePrompt(PulseAiModels.Request req) {
        List<String> parts = new List<String>();

        if (String.isNotBlank(req.systemPrompt)) {
            parts.add('[SYSTEM]\n' + req.systemPrompt);
        }

        if (req.tools != null && !req.tools.isEmpty()) {
            List<Object> toolDescriptors = new List<Object>();
            for (PulseAiModels.ToolDefinition td : req.tools) {
                toolDescriptors.add(new Map<String, Object>{
                    'name' => td.name,
                    'description' => td.description,
                    'input_schema' => td.inputSchema
                });
            }
            parts.add('[TOOLS]\nYou may invoke one of the following tools by'
                + ' replying with a fenced ```json code block of the form'
                + ' {"tool":"<name>","input":{...}}.\n'
                + JSON.serializePretty(toolDescriptors));
        }

        if (req.messages != null) {
            for (PulseAiModels.Message msg : req.messages) {
                String role = (msg.role != null ? msg.role.toUpperCase() : 'USER');
                String content = msg.content != null ? msg.content : '';

                if (msg.role == 'assistant' && msg.toolCalls != null && !msg.toolCalls.isEmpty()) {
                    List<Object> tcDump = new List<Object>();
                    for (PulseAiModels.ToolCall tc : msg.toolCalls) {
                        tcDump.add(new Map<String, Object>{
                            'id' => tc.id,
                            'tool' => tc.toolKey,
                            'input' => (String.isNotBlank(tc.inputJson)
                                ? JSON.deserializeUntyped(tc.inputJson) : new Map<String, Object>())
                        });
                    }
                    content = (String.isNotBlank(content) ? content + '\n' : '')
                        + '[tool_calls]\n' + JSON.serialize(tcDump);
                } else if (msg.role == 'user' && String.isNotBlank(msg.toolCallId)) {
                    content = '[tool_result id=' + msg.toolCallId + ']\n' + content;
                }

                parts.add('[' + role + ']\n' + content);
            }
        }

        return String.join(parts, '\n\n');
    }

    @TestVisible
    private PulseAiModels.Response parseResponse(String body) {
        PulseAiModels.Response resp = new PulseAiModels.Response();
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

        // TODO(agentforce): confirm 'generations' is the canonical field.
        // Alternative observed shape uses 'generation' (singular) at the top
        // level with no array — fall back to that if present.
        String text = null;
        Integer outputTokens = null;

        Object generationsObj = parsed.get('generations');
        if (generationsObj instanceof List<Object>) {
            List<Object> generations = (List<Object>) generationsObj;
            if (!generations.isEmpty()) {
                Map<String, Object> first = (Map<String, Object>) generations[0];
                text = (String) first.get('text');
                if (first.get('tokenCount') instanceof Integer) {
                    outputTokens = (Integer) first.get('tokenCount');
                }
            }
        } else if (parsed.get('generation') instanceof Map<String, Object>) {
            Map<String, Object> gen = (Map<String, Object>) parsed.get('generation');
            text = (String) gen.get('text');
        }

        resp.text = text;

        // Usage: try the parameters.usage shape first, then a flat usage map.
        Map<String, Object> usageMap = null;
        Object parameters = parsed.get('parameters');
        if (parameters instanceof Map<String, Object>) {
            Object u = ((Map<String, Object>) parameters).get('usage');
            if (u instanceof Map<String, Object>) {
                usageMap = (Map<String, Object>) u;
            }
        }
        if (usageMap == null && parsed.get('usage') instanceof Map<String, Object>) {
            usageMap = (Map<String, Object>) parsed.get('usage');
        }

        if (usageMap != null) {
            resp.usage = new PulseAiModels.Usage();
            // TODO(agentforce): verify field names. promptTokens/completionTokens
            // is the OpenAI-style shape; Salesforce may use input_tokens/output_tokens
            // or generationsTokenCount/promptTokenCount.
            resp.usage.inputTokens = readInt(usageMap, new List<String>{
                'promptTokens', 'input_tokens', 'promptTokenCount' });
            resp.usage.outputTokens = readInt(usageMap, new List<String>{
                'completionTokens', 'output_tokens', 'generationsTokenCount' });
            if (resp.usage.outputTokens == null && outputTokens != null) {
                resp.usage.outputTokens = outputTokens;
            }
        } else if (outputTokens != null) {
            resp.usage = new PulseAiModels.Usage();
            resp.usage.outputTokens = outputTokens;
        }

        // Synthesise a ToolCall when the response text contains a fenced
        // JSON block of the form {"tool":"<name>","input":{...}}. This is
        // the workaround for Einstein not yet speaking structured tool_use.
        PulseAiModels.ToolCall synthesised = extractToolCall(text);
        if (synthesised != null) {
            resp.toolCalls.add(synthesised);
        }

        return resp;
    }

    @TestVisible
    private PulseAiModels.ToolCall extractToolCall(String text) {
        if (String.isBlank(text)) {
            return null;
        }

        // Find the first ```json ... ``` fenced block.
        Integer fenceStart = text.indexOf('```json');
        Integer fenceEnd = -1;
        if (fenceStart >= 0) {
            Integer payloadStart = fenceStart + '```json'.length();
            fenceEnd = text.indexOf('```', payloadStart);
            if (fenceEnd > payloadStart) {
                String payload = text.substring(payloadStart, fenceEnd).trim();
                return parseToolCallPayload(payload);
            }
        }

        // Fallback: a bare JSON object that looks like a tool call.
        String trimmed = text.trim();
        if (trimmed.startsWith('{') && trimmed.contains('"tool"')) {
            return parseToolCallPayload(trimmed);
        }
        return null;
    }

    private PulseAiModels.ToolCall parseToolCallPayload(String payload) {
        try {
            Object parsed = JSON.deserializeUntyped(payload);
            if (!(parsed instanceof Map<String, Object>)) {
                return null;
            }
            Map<String, Object> obj = (Map<String, Object>) parsed;
            String toolKey = (String) obj.get('tool');
            if (String.isBlank(toolKey)) {
                return null;
            }
            PulseAiModels.ToolCall tc = new PulseAiModels.ToolCall();
            // No provider-supplied id; mint one so downstream tool_result
            // wiring still has a stable correlation key.
            tc.id = 'agentforce_' + System.now().getTime();
            tc.toolKey = toolKey;
            Object input = obj.get('input');
            tc.inputJson = input != null ? JSON.serialize(input) : '{}';
            return tc;
        } catch (Exception e) {
            return null;
        }
    }

    private Integer readInt(Map<String, Object> source, List<String> keys) {
        for (String k : keys) {
            Object v = source.get(k);
            if (v instanceof Integer) {
                return (Integer) v;
            }
            if (v instanceof Decimal) {
                return ((Decimal) v).intValue();
            }
        }
        return null;
    }

    private PulseAiModels.Response buildErrorResponse(String message) {
        PulseAiModels.Response resp = new PulseAiModels.Response();
        resp.isError = true;
        resp.errorMessage = message;
        return resp;
    }

    @TestVisible
    private String formatApiError(HttpResponse httpRes) {
        Integer status = httpRes.getStatusCode();
        String body = httpRes.getBody();

        // Salesforce REST error envelope: [{"errorCode":"...","message":"..."}]
        // Models-API envelope (observed): {"error":{"code":"...","message":"..."}}
        if (String.isNotBlank(body)) {
            try {
                Object parsed = JSON.deserializeUntyped(body);

                if (parsed instanceof List<Object>) {
                    List<Object> errs = (List<Object>) parsed;
                    if (!errs.isEmpty() && errs[0] instanceof Map<String, Object>) {
                        Map<String, Object> first = (Map<String, Object>) errs[0];
                        String code = (String) first.get('errorCode');
                        String msg = (String) first.get('message');
                        if (String.isNotBlank(msg)) {
                            return 'Agentforce API error ' + status
                                + (String.isNotBlank(code) ? ' [' + code + ']' : '')
                                + ': ' + msg;
                        }
                    }
                } else if (parsed instanceof Map<String, Object>) {
                    Map<String, Object> top = (Map<String, Object>) parsed;
                    Object errObj = top.get('error');
                    if (errObj instanceof Map<String, Object>) {
                        Map<String, Object> err = (Map<String, Object>) errObj;
                        String code = (String) err.get('code');
                        String msg = (String) err.get('message');
                        if (String.isNotBlank(msg)) {
                            return 'Agentforce API error ' + status
                                + (String.isNotBlank(code) ? ' [' + code + ']' : '')
                                + ': ' + msg;
                        }
                    }
                    String topMessage = (String) top.get('message');
                    if (String.isNotBlank(topMessage)) {
                        return 'Agentforce API error ' + status + ': ' + topMessage;
                    }
                }
            } catch (Exception ignored) {
                // fall through to raw body
            }
        }

        return 'Agentforce API error ' + status + ': '
            + (String.isNotBlank(body) ? body : '(empty body)');
    }
}
