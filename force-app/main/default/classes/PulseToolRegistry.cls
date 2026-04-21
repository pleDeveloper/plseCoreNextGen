public with sharing class PulseToolRegistry {

    private static Map<String, PulseTool> toolsByKey;
    private static Map<String, Workflow_Tool_Registration__mdt> registrationsByKey;

    public static void initialize() {
        if (toolsByKey != null) {
            return;
        }

        toolsByKey = new Map<String, PulseTool>();
        registrationsByKey = new Map<String, Workflow_Tool_Registration__mdt>();

        for (Workflow_Tool_Registration__mdt reg : Workflow_Tool_Registration__mdt.getAll().values()) {
            if (reg.Active__c != true) {
                continue;
            }
            if (String.isBlank(reg.Tool_Key__c) || String.isBlank(reg.Apex_Class__c)) {
                continue;
            }

            registrationsByKey.put(reg.Tool_Key__c, reg);

            try {
                Type toolType = Type.forName(reg.Apex_Class__c);
                if (toolType != null) {
                    PulseTool tool = (PulseTool) toolType.newInstance();
                    toolsByKey.put(reg.Tool_Key__c, tool);
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR,
                    'PulseToolRegistry: failed to load ' + reg.Apex_Class__c + ': ' + e.getMessage());
            }
        }
    }

    public static PulseTool getTool(String toolKey) {
        initialize();
        return toolsByKey.get(toolKey);
    }

    public static Map<String, PulseTool> getActiveTools() {
        initialize();
        return new Map<String, PulseTool>(toolsByKey);
    }

    public static String getEffectiveHitlPolicy(String toolKey) {
        initialize();
        Workflow_Tool_Registration__mdt reg = registrationsByKey.get(toolKey);
        if (reg != null && String.isNotBlank(reg.Default_HITL_Policy__c)) {
            return reg.Default_HITL_Policy__c;
        }
        PulseTool tool = toolsByKey.get(toolKey);
        if (tool != null) {
            return tool.getDefaultHitlPolicy();
        }
        return 'Approval_Required';
    }

    public static List<PulseAiModels.ToolDefinition> getToolDefinitions() {
        initialize();
        List<PulseAiModels.ToolDefinition> defs = new List<PulseAiModels.ToolDefinition>();
        for (String key : toolsByKey.keySet()) {
            PulseTool tool = toolsByKey.get(key);
            defs.add(new PulseAiModels.ToolDefinition(
                tool.getToolKey(),
                tool.getDescription(),
                tool.getInputSchema()
            ));
        }
        return defs;
    }

    @TestVisible
    private static void registerToolForTest(String key, PulseTool tool) {
        if (toolsByKey == null) {
            toolsByKey = new Map<String, PulseTool>();
            registrationsByKey = new Map<String, Workflow_Tool_Registration__mdt>();
        }
        toolsByKey.put(key, tool);
    }

    @TestVisible
    private static void clearForTest() {
        toolsByKey = null;
        registrationsByKey = null;
    }
}
