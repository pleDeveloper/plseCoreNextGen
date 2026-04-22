global with sharing class PulseAdminConfigController {

    // ── AI Config DTOs ─────────────────────────────────────────────────
    global class AiProviderView {
        @AuraEnabled public String developerName;
        @AuraEnabled public String providerName;
        @AuraEnabled public String modelId;
        @AuraEnabled public String namedCredential;
        @AuraEnabled public Integer priority;
        @AuraEnabled public Boolean active;
    }

    global class ToolRegistrationView {
        @AuraEnabled public String developerName;
        @AuraEnabled public String toolKey;
        @AuraEnabled public String apexClass;
        @AuraEnabled public String defaultHitlPolicy;
        @AuraEnabled public Boolean active;
    }

    global class ExtractionProfileView {
        @AuraEnabled public String developerName;
        @AuraEnabled public String profileKey;
        @AuraEnabled public String medium;
        @AuraEnabled public Integer schemaSize;
    }

    global class AiConfigView {
        @AuraEnabled public List<AiProviderView>        providers;
        @AuraEnabled public List<ToolRegistrationView>  tools;
        @AuraEnabled public List<ExtractionProfileView> extractionProfiles;
    }

    // ── Integrations Hub DTOs ──────────────────────────────────────────
    global class NamedCredentialView {
        @AuraEnabled public String developerName;
        @AuraEnabled public String label;
        @AuraEnabled public String endpoint;
        @AuraEnabled public String principalType;
    }

    global class ChannelAdapterView {
        @AuraEnabled public String developerName;
        @AuraEnabled public String channelKey;
        @AuraEnabled public String adapterClass;
        @AuraEnabled public Boolean active;
    }

    global class ConversationSourceView {
        @AuraEnabled public String developerName;
        @AuraEnabled public String sourceKey;
        @AuraEnabled public String adapterClass;
        @AuraEnabled public Boolean active;
    }

    global class IntegrationsHubView {
        @AuraEnabled public List<NamedCredentialView>    namedCredentials;
        @AuraEnabled public List<ChannelAdapterView>     channelAdapters;
        @AuraEnabled public List<ConversationSourceView> conversationSources;
    }

    // ── Settings DTOs ──────────────────────────────────────────────────
    global class FeatureFlagView {
        @AuraEnabled public String  developerName;
        @AuraEnabled public String  featureKey;
        @AuraEnabled public Boolean enabled;
        @AuraEnabled public String  description;
    }

    global class PermissionSetView {
        @AuraEnabled public String  developerName;
        @AuraEnabled public String  label;
        @AuraEnabled public Boolean assignedToCurrentUser;
    }

    global class DeploymentHistoryView {
        @AuraEnabled public Id       deploymentRequestId;
        @AuraEnabled public String   targetObject;
        @AuraEnabled public String   status;
        @AuraEnabled public Datetime completedDate;
        @AuraEnabled public String   errorMessage;
    }

    global class SettingsView {
        @AuraEnabled public List<FeatureFlagView>       featureFlags;
        @AuraEnabled public List<PermissionSetView>     pulsePermissionSets;
        @AuraEnabled public List<DeploymentHistoryView> recentDeployments;
    }

    // ── AI Config ──────────────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    global static AiConfigView getAiConfig() {
        AiConfigView view = new AiConfigView();
        view.providers = mapProviders([
            SELECT DeveloperName, Provider_Name__c, Model_Id__c,
                   Named_Credential__c, Priority__c, Active__c
            FROM AI_Provider_Registration__mdt
            ORDER BY Priority__c ASC NULLS LAST, DeveloperName ASC
        ]);
        view.tools = mapTools([
            SELECT DeveloperName, Tool_Key__c, Apex_Class__c,
                   Default_HITL_Policy__c, Active__c
            FROM Workflow_Tool_Registration__mdt
            ORDER BY Tool_Key__c ASC
        ]);
        view.extractionProfiles = mapProfiles([
            SELECT DeveloperName, Profile_Key__c, Medium__c, Schema_JSON__c
            FROM Extraction_Profile__mdt
            ORDER BY Profile_Key__c ASC
        ]);
        return view;
    }

    @TestVisible
    private static List<AiProviderView> mapProviders(List<AI_Provider_Registration__mdt> records) {
        List<AiProviderView> result = new List<AiProviderView>();
        for (AI_Provider_Registration__mdt p : records) {
            AiProviderView v = new AiProviderView();
            v.developerName   = p.DeveloperName;
            v.providerName    = p.Provider_Name__c;
            v.modelId         = p.Model_Id__c;
            v.namedCredential = p.Named_Credential__c;
            v.priority        = p.Priority__c != null ? p.Priority__c.intValue() : null;
            v.active          = p.Active__c == true;
            result.add(v);
        }
        return result;
    }

    @TestVisible
    private static List<ToolRegistrationView> mapTools(List<Workflow_Tool_Registration__mdt> records) {
        List<ToolRegistrationView> result = new List<ToolRegistrationView>();
        for (Workflow_Tool_Registration__mdt t : records) {
            ToolRegistrationView v = new ToolRegistrationView();
            v.developerName    = t.DeveloperName;
            v.toolKey          = t.Tool_Key__c;
            v.apexClass        = t.Apex_Class__c;
            v.defaultHitlPolicy = t.Default_HITL_Policy__c;
            v.active           = t.Active__c == true;
            result.add(v);
        }
        return result;
    }

    @TestVisible
    private static List<ExtractionProfileView> mapProfiles(List<Extraction_Profile__mdt> records) {
        List<ExtractionProfileView> result = new List<ExtractionProfileView>();
        for (Extraction_Profile__mdt e : records) {
            ExtractionProfileView v = new ExtractionProfileView();
            v.developerName = e.DeveloperName;
            v.profileKey    = e.Profile_Key__c;
            v.medium        = e.Medium__c;
            v.schemaSize    = e.Schema_JSON__c != null ? e.Schema_JSON__c.length() : 0;
            result.add(v);
        }
        return result;
    }

    // ── Integrations Hub ───────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    global static IntegrationsHubView getIntegrationsHub() {
        IntegrationsHubView view = new IntegrationsHubView();
        view.namedCredentials = mapNamedCredentials([
            SELECT DeveloperName, MasterLabel, Endpoint, PrincipalType
            FROM NamedCredential
            ORDER BY MasterLabel ASC
        ]);
        view.channelAdapters = mapChannelAdapters([
            SELECT DeveloperName, Channel_Type__c, Adapter_Class__c, Active__c
            FROM Channel_Adapter_Registration__mdt
            ORDER BY Channel_Type__c ASC
        ]);
        view.conversationSources = mapConversationSources([
            SELECT DeveloperName, Medium__c, Adapter_Class__c, Active__c
            FROM Conversation_Source_Registration__mdt
            ORDER BY DeveloperName ASC
        ]);
        return view;
    }

    @TestVisible
    private static List<NamedCredentialView> mapNamedCredentials(List<NamedCredential> records) {
        List<NamedCredentialView> result = new List<NamedCredentialView>();
        for (NamedCredential nc : records) {
            NamedCredentialView v = new NamedCredentialView();
            v.developerName = nc.DeveloperName;
            v.label         = nc.MasterLabel;
            v.endpoint      = nc.Endpoint;
            v.principalType = nc.PrincipalType;
            result.add(v);
        }
        return result;
    }

    @TestVisible
    private static List<ChannelAdapterView> mapChannelAdapters(List<Channel_Adapter_Registration__mdt> records) {
        List<ChannelAdapterView> result = new List<ChannelAdapterView>();
        for (Channel_Adapter_Registration__mdt ca : records) {
            ChannelAdapterView v = new ChannelAdapterView();
            v.developerName = ca.DeveloperName;
            v.channelKey    = ca.Channel_Type__c;
            v.adapterClass  = ca.Adapter_Class__c;
            v.active        = ca.Active__c == true;
            result.add(v);
        }
        return result;
    }

    @TestVisible
    private static List<ConversationSourceView> mapConversationSources(List<Conversation_Source_Registration__mdt> records) {
        List<ConversationSourceView> result = new List<ConversationSourceView>();
        for (Conversation_Source_Registration__mdt cs : records) {
            ConversationSourceView v = new ConversationSourceView();
            v.developerName = cs.DeveloperName;
            v.sourceKey     = cs.Medium__c;
            v.adapterClass  = cs.Adapter_Class__c;
            v.active        = cs.Active__c == true;
            result.add(v);
        }
        return result;
    }

    // ── Settings ───────────────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    global static SettingsView getSettings() {
        SettingsView view = new SettingsView();

        view.featureFlags = mapFeatureFlags([
            SELECT DeveloperName, Flag_Key__c, Active__c, Description__c
            FROM Feature_Flag__mdt
            ORDER BY Flag_Key__c ASC
        ]);

        // Pulse permission sets
        view.pulsePermissionSets = new List<PermissionSetView>();
        List<PermissionSet> psList = [
            SELECT Id, Name, Label
            FROM PermissionSet
            WHERE Name LIKE 'Pulse_%'
            ORDER BY Label ASC
        ];

        Set<Id> assignedPsIds = new Set<Id>();
        if (!psList.isEmpty()) {
            for (PermissionSetAssignment psa : [
                SELECT PermissionSetId
                FROM PermissionSetAssignment
                WHERE AssigneeId = :UserInfo.getUserId()
                  AND PermissionSetId IN :psList
            ]) {
                assignedPsIds.add(psa.PermissionSetId);
            }
        }

        for (PermissionSet ps : psList) {
            PermissionSetView pv = new PermissionSetView();
            pv.developerName         = ps.Name;
            pv.label                 = ps.Label;
            pv.assignedToCurrentUser = assignedPsIds.contains(ps.Id);
            view.pulsePermissionSets.add(pv);
        }

        // Recent deployments (top 10)
        view.recentDeployments = mapDeployments([
            SELECT Id, Target_Object__c, Status__c, Completed_Date__c, Error_Message__c
            FROM Deployment_Request__c
            ORDER BY CreatedDate DESC
            LIMIT 10
        ]);

        return view;
    }

    @TestVisible
    private static List<FeatureFlagView> mapFeatureFlags(List<Feature_Flag__mdt> records) {
        List<FeatureFlagView> result = new List<FeatureFlagView>();
        for (Feature_Flag__mdt ff : records) {
            FeatureFlagView v = new FeatureFlagView();
            v.developerName = ff.DeveloperName;
            v.featureKey    = ff.Flag_Key__c;
            v.enabled       = ff.Active__c == true;
            v.description   = ff.Description__c;
            result.add(v);
        }
        return result;
    }

    @TestVisible
    private static List<DeploymentHistoryView> mapDeployments(List<Deployment_Request__c> records) {
        List<DeploymentHistoryView> result = new List<DeploymentHistoryView>();
        for (Deployment_Request__c dr : records) {
            DeploymentHistoryView v = new DeploymentHistoryView();
            v.deploymentRequestId = dr.Id;
            v.targetObject        = dr.Target_Object__c;
            v.status              = dr.Status__c;
            v.completedDate       = dr.Completed_Date__c;
            v.errorMessage        = dr.Error_Message__c;
            result.add(v);
        }
        return result;
    }
}
