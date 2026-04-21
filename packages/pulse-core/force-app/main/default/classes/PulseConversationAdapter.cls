/**
 * Interface for conversation source adapters (Recall, email, etc.).
 * Each adapter normalizes external payloads into PulseConversationModels inputs.
 */
global interface PulseConversationAdapter {
    String getAdapterKey();
    List<PulseConversationModels.ConversationInput> normalizePayload(String rawPayload);
}
