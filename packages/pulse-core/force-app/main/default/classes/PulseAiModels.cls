global class PulseAiModels {

    global class Request {
        global String systemPrompt;
        global List<Message> messages;
        global List<ToolDefinition> tools;
        global Integer maxTokens;
        global String modelId;

        global Request() {
            this.messages = new List<Message>();
            this.tools = new List<ToolDefinition>();
            this.maxTokens = 4096;
        }
    }

    global class Response {
        global String text;
        global List<ToolCall> toolCalls;
        global Usage usage;
        global String providerRequestId;
        global String rawJson;
        global Boolean isError;
        global String errorMessage;

        global Response() {
            this.toolCalls = new List<ToolCall>();
            this.isError = false;
        }
    }

    global class Message {
        global String role;
        global String content;
        global List<ToolCall> toolCalls;
        global String toolCallId;

        global Message(String role, String content) {
            this.role = role;
            this.content = content;
        }
    }

    global class ToolCall {
        global String id;
        global String toolKey;
        global String inputJson;
    }

    global class ToolDefinition {
        global String name;
        global String description;
        global Map<String, Object> inputSchema;

        global ToolDefinition(String name, String description, Map<String, Object> inputSchema) {
            this.name = name;
            this.description = description;
            this.inputSchema = inputSchema;
        }
    }

    global class Usage {
        global Integer inputTokens;
        global Integer outputTokens;
    }
}
