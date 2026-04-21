@IsTest
private class PulseToolsTest {

    // ─── PulseEmailTool ───────────────────────────────────────────

    @IsTest
    static void testEmailToolSchema() {
        PulseEmailTool tool = new PulseEmailTool();
        System.assertEquals('send_email', tool.getToolKey());
        System.assertEquals('Approval_Required', tool.getDefaultHitlPolicy());
        System.assertNotEquals(null, tool.getInputSchema());
        System.assertNotEquals(null, tool.getDescription());
    }

    @IsTest
    static void testEmailToolMissingFields() {
        PulseEmailTool tool = new PulseEmailTool();
        PulseToolModels.Context ctx = new PulseToolModels.Context(null, new Map<String, Object>());
        PulseToolModels.Result result = tool.execute(ctx);
        System.assertEquals(false, result.success);
        System.assert(result.errorMessage.contains('Missing required'));
    }

    // ─── PulseRecordUpdateTool ────────────────────────────────────

    @IsTest
    static void testRecordUpdateSchema() {
        PulseRecordUpdateTool tool = new PulseRecordUpdateTool();
        System.assertEquals('update_record', tool.getToolKey());
        System.assertEquals('Approval_Required', tool.getDefaultHitlPolicy());
    }

    @IsTest
    static void testRecordUpdateMissingFields() {
        PulseRecordUpdateTool tool = new PulseRecordUpdateTool();
        PulseToolModels.Context ctx = new PulseToolModels.Context(null, new Map<String, Object>());
        PulseToolModels.Result result = tool.execute(ctx);
        System.assertEquals(false, result.success);
    }

    @IsTest
    static void testRecordUpdateUnknownObject() {
        PulseRecordUpdateTool tool = new PulseRecordUpdateTool();
        PulseToolModels.Context ctx = new PulseToolModels.Context(null, new Map<String, Object>{
            'recordId' => '001000000000001',
            'objectType' => 'NonExistentObject__c',
            'fields' => new Map<String, Object>{ 'Name' => 'Test' }
        });
        PulseToolModels.Result result = tool.execute(ctx);
        System.assertEquals(false, result.success);
        System.assert(result.errorMessage.contains('Unknown object'));
    }

    @IsTest
    static void testRecordUpdateAllowlistBlock() {
        PulseRecordUpdateTool.setFieldAllowlist('Account', new Set<String>{ 'name' });
        PulseRecordUpdateTool tool = new PulseRecordUpdateTool();

        Account a = new Account(Name = 'Test');
        insert a;

        PulseToolModels.Context ctx = new PulseToolModels.Context(null, new Map<String, Object>{
            'recordId' => a.Id,
            'objectType' => 'Account',
            'fields' => new Map<String, Object>{ 'Website' => 'https://test.com' }
        });
        PulseToolModels.Result result = tool.execute(ctx);
        System.assertEquals(false, result.success);
        System.assert(result.errorMessage.contains('not in allowlist'));
    }

    @IsTest
    static void testRecordUpdateSuccess() {
        PulseRecordUpdateTool tool = new PulseRecordUpdateTool();
        Account a = new Account(Name = 'Original');
        insert a;

        PulseToolModels.Context ctx = new PulseToolModels.Context(null, new Map<String, Object>{
            'recordId' => a.Id,
            'objectType' => 'Account',
            'fields' => new Map<String, Object>{ 'Name' => 'Updated' }
        });
        PulseToolModels.Result result = tool.execute(ctx);
        System.assertEquals(true, result.success);

        Account updated = [SELECT Name FROM Account WHERE Id = :a.Id];
        System.assertEquals('Updated', updated.Name);
    }

    @IsTest
    static void testRecordUpdateAllowlistPass() {
        PulseRecordUpdateTool.setFieldAllowlist('Account', new Set<String>{ 'name' });
        PulseRecordUpdateTool tool = new PulseRecordUpdateTool();

        Account a = new Account(Name = 'Original');
        insert a;

        PulseToolModels.Context ctx = new PulseToolModels.Context(null, new Map<String, Object>{
            'recordId' => a.Id,
            'objectType' => 'Account',
            'fields' => new Map<String, Object>{ 'Name' => 'Allowed' }
        });
        PulseToolModels.Result result = tool.execute(ctx);
        System.assertEquals(true, result.success);
    }

    // ─── PulseExternalApiTool ─────────────────────────────────────

    @IsTest
    static void testExternalApiSchema() {
        PulseExternalApiTool tool = new PulseExternalApiTool();
        System.assertEquals('call_external_api', tool.getToolKey());
        System.assertEquals('Approval_Required', tool.getDefaultHitlPolicy());
    }

    @IsTest
    static void testExternalApiMissingFields() {
        PulseExternalApiTool tool = new PulseExternalApiTool();
        PulseToolModels.Context ctx = new PulseToolModels.Context(null, new Map<String, Object>());
        PulseToolModels.Result result = tool.execute(ctx);
        System.assertEquals(false, result.success);
    }

    @IsTest
    static void testExternalApiInvalidMethod() {
        PulseExternalApiTool tool = new PulseExternalApiTool();
        PulseToolModels.Context ctx = new PulseToolModels.Context(null, new Map<String, Object>{
            'namedCredential' => 'TestCred',
            'path' => '/api/test',
            'method' => 'INVALID'
        });
        PulseToolModels.Result result = tool.execute(ctx);
        System.assertEquals(false, result.success);
        System.assert(result.errorMessage.contains('Invalid HTTP method'));
    }

    // ─── PulseToolRegistry ────────────────────────────────────────

    @IsTest
    static void testRegistryManualRegistration() {
        PulseToolRegistry.clearForTest();
        PulseEmailTool emailTool = new PulseEmailTool();
        PulseToolRegistry.registerToolForTest('send_email', emailTool);

        PulseTool retrieved = PulseToolRegistry.getTool('send_email');
        System.assertNotEquals(null, retrieved);
        System.assertEquals('send_email', retrieved.getToolKey());
    }

    @IsTest
    static void testRegistryUnknownTool() {
        PulseToolRegistry.clearForTest();
        PulseTool retrieved = PulseToolRegistry.getTool('nonexistent_tool');
        System.assertEquals(null, retrieved);
    }

    @IsTest
    static void testRegistryGetToolDefinitions() {
        PulseToolRegistry.clearForTest();
        PulseToolRegistry.registerToolForTest('send_email', new PulseEmailTool());
        PulseToolRegistry.registerToolForTest('update_record', new PulseRecordUpdateTool());

        List<PulseAiModels.ToolDefinition> defs = PulseToolRegistry.getToolDefinitions();
        System.assertEquals(2, defs.size());
    }

    @IsTest
    static void testRegistryEffectiveHitlPolicyFallback() {
        PulseToolRegistry.clearForTest();
        PulseToolRegistry.registerToolForTest('send_email', new PulseEmailTool());

        String policy = PulseToolRegistry.getEffectiveHitlPolicy('send_email');
        System.assertEquals('Approval_Required', policy);
    }

    @IsTest
    static void testRegistryEffectiveHitlPolicyUnknown() {
        PulseToolRegistry.clearForTest();
        String policy = PulseToolRegistry.getEffectiveHitlPolicy('no_such_tool');
        System.assertEquals('Approval_Required', policy, 'Should default to Approval_Required');
    }

    // ─── PulseToolModels.Result factories ───────────────────────────────

    @IsTest
    static void testToolResultFactories() {
        PulseToolModels.Result ok = PulseToolModels.ok('{"data":"value"}');
        System.assertEquals(true, ok.success);
        System.assertEquals('{"data":"value"}', ok.outputJson);

        PulseToolModels.Result err = PulseToolModels.fail('Something broke');
        System.assertEquals(false, err.success);
        System.assertEquals('Something broke', err.errorMessage);
    }

    // ─── PulseToolModels.Context defaults ───────────────────────────────

    @IsTest
    static void testToolContextNullInput() {
        PulseToolModels.Context ctx = new PulseToolModels.Context(null, null);
        System.assertNotEquals(null, ctx.input, 'Null input should be replaced with empty map');
        System.assertEquals(0, ctx.input.size());
    }
}
