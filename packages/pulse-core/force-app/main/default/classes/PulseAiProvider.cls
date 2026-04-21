global interface PulseAiProvider {
    void configure(String namedCredential, String modelId);
    PulseAiModels.Response chat(PulseAiModels.Request req);
}
