@IsTest
private class PulseAdminConfigControllerTest {

    // ── getAiConfig ─────────────────────────────────────────────────

    @IsTest
    static void getAiConfig_returnsNonNullLists() {
        PulseAdminConfigController.AiConfigView result =
            PulseAdminConfigController.getAiConfig();
        System.assertNotEquals(null, result, 'AiConfigView should not be null');
        System.assertNotEquals(null, result.providers, 'providers list should not be null');
        System.assertNotEquals(null, result.tools, 'tools list should not be null');
        System.assertNotEquals(null, result.extractionProfiles, 'extractionProfiles list should not be null');
    }

    @IsTest
    static void mapProviders_mapsFieldsCorrectly() {
        AI_Provider_Registration__mdt rec = new AI_Provider_Registration__mdt(
            DeveloperName    = 'TestProvider',
            Provider_Name__c = 'Anthropic',
            Model_Id__c      = 'claude-sonnet-4-20250514',
            Named_Credential__c = 'Anthropic_API',
            Priority__c      = 1,
            Active__c        = true
        );
        List<PulseAdminConfigController.AiProviderView> result =
            PulseAdminConfigController.mapProviders(
                new List<AI_Provider_Registration__mdt>{ rec }
            );
        System.assertEquals(1, result.size());
        System.assertEquals('TestProvider', result[0].developerName);
        System.assertEquals('Anthropic', result[0].providerName);
        System.assertEquals('claude-sonnet-4-20250514', result[0].modelId);
        System.assertEquals('Anthropic_API', result[0].namedCredential);
        System.assertEquals(1, result[0].priority);
        System.assertEquals(true, result[0].active);
    }

    @IsTest
    static void mapProviders_handlesNullPriority() {
        AI_Provider_Registration__mdt rec = new AI_Provider_Registration__mdt(
            DeveloperName    = 'NoPriority',
            Provider_Name__c = 'Test',
            Active__c        = false
        );
        List<PulseAdminConfigController.AiProviderView> result =
            PulseAdminConfigController.mapProviders(
                new List<AI_Provider_Registration__mdt>{ rec }
            );
        System.assertEquals(null, result[0].priority);
        System.assertEquals(false, result[0].active);
    }

    @IsTest
    static void mapTools_mapsFieldsCorrectly() {
        Workflow_Tool_Registration__mdt rec = new Workflow_Tool_Registration__mdt(
            DeveloperName        = 'Send_Email',
            Tool_Key__c          = 'send_email',
            Apex_Class__c        = 'EmailToolHandler',
            Default_HITL_Policy__c = 'Approval_Required',
            Active__c            = true
        );
        List<PulseAdminConfigController.ToolRegistrationView> result =
            PulseAdminConfigController.mapTools(
                new List<Workflow_Tool_Registration__mdt>{ rec }
            );
        System.assertEquals(1, result.size());
        System.assertEquals('send_email', result[0].toolKey);
        System.assertEquals('EmailToolHandler', result[0].apexClass);
        System.assertEquals('Approval_Required', result[0].defaultHitlPolicy);
        System.assertEquals(true, result[0].active);
    }

    @IsTest
    static void mapProfiles_computesSchemaSize() {
        Extraction_Profile__mdt rec = new Extraction_Profile__mdt(
            DeveloperName  = 'Contact_Extract',
            Profile_Key__c = 'contact_extract',
            Medium__c      = 'email',
            Schema_JSON__c = '{"fields":["Name"]}'
        );
        List<PulseAdminConfigController.ExtractionProfileView> result =
            PulseAdminConfigController.mapProfiles(
                new List<Extraction_Profile__mdt>{ rec }
            );
        System.assertEquals(1, result.size());
        System.assertEquals('contact_extract', result[0].profileKey);
        System.assertEquals('email', result[0].medium);
        System.assertEquals(19, result[0].schemaSize);
    }

    @IsTest
    static void mapProfiles_handlesNullSchema() {
        Extraction_Profile__mdt rec = new Extraction_Profile__mdt(
            DeveloperName  = 'Blank',
            Profile_Key__c = 'blank'
        );
        List<PulseAdminConfigController.ExtractionProfileView> result =
            PulseAdminConfigController.mapProfiles(
                new List<Extraction_Profile__mdt>{ rec }
            );
        System.assertEquals(0, result[0].schemaSize);
    }

    // ── getIntegrationsHub ──────────────────────────────────────────

    @IsTest
    static void getIntegrationsHub_returnsNonNullLists() {
        PulseAdminConfigController.IntegrationsHubView result =
            PulseAdminConfigController.getIntegrationsHub();
        System.assertNotEquals(null, result, 'IntegrationsHubView should not be null');
        System.assertNotEquals(null, result.namedCredentials, 'namedCredentials should not be null');
        System.assertNotEquals(null, result.channelAdapters, 'channelAdapters should not be null');
        System.assertNotEquals(null, result.conversationSources, 'conversationSources should not be null');
    }

    @IsTest
    static void mapChannelAdapters_mapsFieldsCorrectly() {
        Channel_Adapter_Registration__mdt rec = new Channel_Adapter_Registration__mdt(
            DeveloperName    = 'Slack_Adapter',
            Channel_Type__c  = 'slack',
            Adapter_Class__c = 'SlackInboundAdapter',
            Active__c        = true
        );
        List<PulseAdminConfigController.ChannelAdapterView> result =
            PulseAdminConfigController.mapChannelAdapters(
                new List<Channel_Adapter_Registration__mdt>{ rec }
            );
        System.assertEquals(1, result.size());
        System.assertEquals('slack', result[0].channelKey);
        System.assertEquals('SlackInboundAdapter', result[0].adapterClass);
        System.assertEquals(true, result[0].active);
    }

    @IsTest
    static void mapConversationSources_mapsFieldsCorrectly() {
        Conversation_Source_Registration__mdt rec = new Conversation_Source_Registration__mdt(
            DeveloperName    = 'Email_Source',
            Medium__c        = 'email',
            Adapter_Class__c = 'EmailIngestAdapter',
            Active__c        = false
        );
        List<PulseAdminConfigController.ConversationSourceView> result =
            PulseAdminConfigController.mapConversationSources(
                new List<Conversation_Source_Registration__mdt>{ rec }
            );
        System.assertEquals(1, result.size());
        System.assertEquals('email', result[0].sourceKey);
        System.assertEquals('EmailIngestAdapter', result[0].adapterClass);
        System.assertEquals(false, result[0].active);
    }

    @IsTest
    static void mapNamedCredentials_mapsFieldsCorrectly() {
        // NamedCredential cannot be inserted in tests; verify empty-list mapping
        List<PulseAdminConfigController.NamedCredentialView> result =
            PulseAdminConfigController.mapNamedCredentials(
                new List<NamedCredential>()
            );
        System.assertEquals(0, result.size());
    }

    // ── getSettings ─────────────────────────────────────────────────

    @IsTest
    static void getSettings_returnsNonNullLists() {
        PulseAdminConfigController.SettingsView result =
            PulseAdminConfigController.getSettings();
        System.assertNotEquals(null, result, 'SettingsView should not be null');
        System.assertNotEquals(null, result.featureFlags, 'featureFlags should not be null');
        System.assertNotEquals(null, result.pulsePermissionSets, 'pulsePermissionSets should not be null');
        System.assertNotEquals(null, result.recentDeployments, 'recentDeployments should not be null');
    }

    @IsTest
    static void mapFeatureFlags_mapsFieldsCorrectly() {
        Feature_Flag__mdt rec = new Feature_Flag__mdt(
            DeveloperName  = 'Enable_AI',
            Flag_Key__c    = 'enable_ai',
            Active__c      = true,
            Description__c = 'Enable AI features'
        );
        List<PulseAdminConfigController.FeatureFlagView> result =
            PulseAdminConfigController.mapFeatureFlags(
                new List<Feature_Flag__mdt>{ rec }
            );
        System.assertEquals(1, result.size());
        System.assertEquals('enable_ai', result[0].featureKey);
        System.assertEquals(true, result[0].enabled);
        System.assertEquals('Enable AI features', result[0].description);
    }

    @IsTest
    static void getSettings_limitsDeploymentsToTen() {
        List<Deployment_Request__c> requests = new List<Deployment_Request__c>();
        for (Integer i = 0; i < 15; i++) {
            requests.add(new Deployment_Request__c(
                Target_Object__c = 'TestObject_' + i,
                Status__c        = 'Completed'
            ));
        }
        insert requests;

        PulseAdminConfigController.SettingsView result =
            PulseAdminConfigController.getSettings();
        System.assert(
            result.recentDeployments.size() <= 10,
            'Should return at most 10 deployment records, got ' + result.recentDeployments.size()
        );
    }

    @IsTest
    static void getSettings_deploymentsOrderedByCreatedDateDesc() {
        Deployment_Request__c older = new Deployment_Request__c(
            Target_Object__c = 'OlderObject',
            Status__c        = 'Completed'
        );
        insert older;
        // Force a deterministic CreatedDate gap — two sequential inserts can
        // land in the same millisecond, making ORDER BY CreatedDate DESC
        // non-deterministic. Test.setCreatedDate rewrites the timestamp.
        Test.setCreatedDate(older.Id, Datetime.now().addDays(-1));

        Deployment_Request__c newer = new Deployment_Request__c(
            Target_Object__c  = 'NewerObject',
            Status__c         = 'Failed',
            Error_Message__c  = 'Something went wrong'
        );
        insert newer;

        PulseAdminConfigController.SettingsView result =
            PulseAdminConfigController.getSettings();
        System.assert(result.recentDeployments.size() >= 2, 'Should have at least 2 deployments');
        System.assertEquals('NewerObject', result.recentDeployments[0].targetObject);
        System.assertEquals('Failed', result.recentDeployments[0].status);
        System.assertEquals('Something went wrong', result.recentDeployments[0].errorMessage);
    }

    @IsTest
    static void getSettings_permissionSetAssignmentReflectsCurrentUser() {
        PulseAdminConfigController.SettingsView result =
            PulseAdminConfigController.getSettings();
        for (PulseAdminConfigController.PermissionSetView psv : result.pulsePermissionSets) {
            System.assertNotEquals(null, psv.assignedToCurrentUser, 'assignedToCurrentUser should be set');
            System.assertNotEquals(null, psv.label, 'label should be set');
        }
    }

    @IsTest
    static void mapDeployments_mapsFieldsCorrectly() {
        Deployment_Request__c dr = new Deployment_Request__c(
            Target_Object__c = 'Account',
            Status__c        = 'Completed',
            Error_Message__c = null
        );
        insert dr;

        List<Deployment_Request__c> records = [
            SELECT Id, Target_Object__c, Status__c, Completed_Date__c, Error_Message__c
            FROM Deployment_Request__c
            WHERE Id = :dr.Id
        ];

        List<PulseAdminConfigController.DeploymentHistoryView> result =
            PulseAdminConfigController.mapDeployments(records);
        System.assertEquals(1, result.size());
        System.assertEquals(dr.Id, result[0].deploymentRequestId);
        System.assertEquals('Account', result[0].targetObject);
        System.assertEquals('Completed', result[0].status);
    }
}
