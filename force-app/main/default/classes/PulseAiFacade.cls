public with sharing class PulseAiFacade {

    private static PulseAiProvider providerOverride;

    public static PulseAiProvider.Request buildRequest(Workflow_Instance__c instance) {
        PulseAiProvider.Request req = new PulseAiProvider.Request();

        req.systemPrompt = 'You are an AI assistant for Pulse workflow automation. '
            + 'You are operating on workflow "' + instance.Workflow_Definition__r.Workflow_Key__c + '" '
            + 'in state "' + instance.Current_State__c + '". '
            + 'Use the available tools to complete the required actions. '
            + 'Only call tools that are necessary. Explain your reasoning.';

        PulseAiProvider.Message userMsg = new PulseAiProvider.Message('user',
            'Workflow context: ' + (String.isNotBlank(instance.Context_JSON__c)
                ? instance.Context_JSON__c : '{}'));
        req.messages.add(userMsg);

        req.tools = PulseToolRegistry.getToolDefinitions();

        return req;
    }

    public static PulseAiProvider.Response invoke(PulseAiProvider.Request req) {
        PulseAiProvider provider = getProvider();
        return provider.chat(req);
    }

    private static PulseAiProvider getProvider() {
        if (providerOverride != null) {
            return providerOverride;
        }

        AI_Provider_Registration__mdt reg = selectProvider();
        if (reg == null) {
            throw new PulseAiException('No active AI provider configured');
        }

        if (reg.Provider_Name__c == 'Anthropic') {
            return new AnthropicAdapter(reg.Named_Credential__c, reg.Model_Id__c);
        }

        throw new PulseAiException('Unsupported provider: ' + reg.Provider_Name__c);
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
