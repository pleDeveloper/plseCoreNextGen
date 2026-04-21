/**
 * Interface for conversation source adapters (Recall, email, etc.).
 * Each adapter normalizes external payloads into ConversationIngestionService inputs.
 */
public interface PulseConversationAdapter {
    String getAdapterKey();
    List<ConversationIngestionService.ConversationInput> normalizePayload(String rawPayload);
}
