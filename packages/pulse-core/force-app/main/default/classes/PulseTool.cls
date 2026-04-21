global interface PulseTool {
    String getToolKey();
    String getDescription();
    Map<String, Object> getInputSchema();
    String getDefaultHitlPolicy();
    PulseToolModels.Result execute(PulseToolModels.Context ctx);
}
