public with sharing class PulseAiFacade {

    private static PulseAiProvider providerOverride;

    public static PulseAiModels.Request buildRequest(Workflow_Instance__c instance) {
        PulseAiModels.Request req = new PulseAiModels.Request();

        req.systemPrompt = 'You are an AI assistant for Pulse workflow automation. '
            + 'You are operating on workflow "' + instance.Workflow_Definition__r.Workflow_Key__c + '" '
            + 'in state "' + instance.Current_State__c + '". '
            + 'Use the available tools to complete the required actions. '
            + 'Only call tools that are necessary. Explain your reasoning.';

        PulseAiModels.Message userMsg = new PulseAiModels.Message('user',
            'Workflow context: ' + (String.isNotBlank(instance.Context_JSON__c)
                ? instance.Context_JSON__c : '{}'));
        req.messages.add(userMsg);

        req.tools = PulseToolRegistry.getToolDefinitions();

        return req;
    }

    public static PulseAiModels.Response invoke(PulseAiModels.Request req) {
        PulseAiProvider provider = getProvider();
        return provider.chat(req);
    }

    // Provider class name convention: Provider_Name__c + 'Adapter'
    private static final Map<String, String> PROVIDER_CLASS_MAP = new Map<String, String>{
        'Anthropic' => 'AnthropicAdapter'
    };

    private static PulseAiProvider getProvider() {
        if (providerOverride != null) {
            return providerOverride;
        }

        AI_Provider_Registration__mdt reg = selectProvider();
        if (reg == null) {
            throw new PulseAiException('No active AI provider configured');
        }

        String className = PROVIDER_CLASS_MAP.get(reg.Provider_Name__c);
        if (String.isBlank(className)) {
            throw new PulseAiException('Unsupported provider: ' + reg.Provider_Name__c);
        }

        Type providerType = Type.forName(className);
        if (providerType == null) {
            throw new PulseAiException('Provider class not found: ' + className);
        }

        PulseAiProvider provider = (PulseAiProvider) providerType.newInstance();
        provider.configure(reg.Named_Credential__c, reg.Model_Id__c);
        return provider;
    }

    private static AI_Provider_Registration__mdt selectProvider() {
        AI_Provider_Registration__mdt selected = null;
        for (AI_Provider_Registration__mdt reg : AI_Provider_Registration__mdt.getAll().values()) {
            if (reg.Active__c != true) {
                continue;
            }
            if (selected == null || (reg.Priority__c != null
                    && (selected.Priority__c == null || reg.Priority__c < selected.Priority__c))) {
                selected = reg;
            }
        }
        return selected;
    }

    @TestVisible
    private static void setProviderForTest(PulseAiProvider provider) {
        providerOverride = provider;
    }

    @TestVisible
    private static void clearProviderForTest() {
        providerOverride = null;
    }

    public class PulseAiException extends Exception {}
}
