public class PulseAiModels {

    public class Request {
        public String systemPrompt;
        public List<Message> messages;
        public List<ToolDefinition> tools;
        public Integer maxTokens;
        public String modelId;

        public Request() {
            this.messages = new List<Message>();
            this.tools = new List<ToolDefinition>();
            this.maxTokens = 4096;
        }
    }

    public class Response {
        public String text;
        public List<ToolCall> toolCalls;
        public Usage usage;
        public String providerRequestId;
        public String rawJson;
        public Boolean isError;
        public String errorMessage;

        public Response() {
            this.toolCalls = new List<ToolCall>();
            this.isError = false;
        }
    }

    public class Message {
        public String role;
        public String content;
        public List<ToolCall> toolCalls;
        public String toolCallId;

        public Message(String role, String content) {
            this.role = role;
            this.content = content;
        }
    }

    public class ToolCall {
        public String id;
        public String toolKey;
        public String inputJson;
    }

    public class ToolDefinition {
        public String name;
        public String description;
        public Map<String, Object> inputSchema;

        public ToolDefinition(String name, String description, Map<String, Object> inputSchema) {
            this.name = name;
            this.description = description;
            this.inputSchema = inputSchema;
        }
    }

    public class Usage {
        public Integer inputTokens;
        public Integer outputTokens;
    }
}
