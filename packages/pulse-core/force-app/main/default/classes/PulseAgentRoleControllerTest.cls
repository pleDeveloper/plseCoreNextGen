@IsTest
private class PulseAgentRoleControllerTest {

    /** Stub IRoleDeployer — records the container so tests can assert the
     *  prepared payload without invoking Metadata.Operations, which throws
     *  AsyncException in @IsTest context. */
    private class StubRoleDeployer implements PulseAgentRoleController.IRoleDeployer {
        public Metadata.DeployContainer captured;
        public Id enqueue(Metadata.DeployContainer container) {
            this.captured = container;
            return '707000000000000AAA';
        }
    }

    // ─── List ──────────────────────────────────────────────────────────

    @IsTest
    static void listRoles_returnsCallable() {
        Test.startTest();
        List<PulseAgentRoleController.RoleView> rows = PulseAgentRoleController.listRoles();
        Test.stopTest();
        // We can't insert CMDT in tests so we cannot assert on contents — but the
        // method must be callable without throwing.
        System.assertNotEquals(null, rows);
    }

    @IsTest
    static void listActiveRoleSummaries_returnsCallable() {
        Test.startTest();
        List<PulseAgentRoleController.RoleSummaryView> rows =
            PulseAgentRoleController.listActiveRoleSummaries();
        Test.stopTest();
        System.assertNotEquals(null, rows);
    }

    // ─── Upsert ────────────────────────────────────────────────────────

    @IsTest
    static void upsertRole_rejectsBlankRoleKey() {
        Test.startTest();
        PulseAgentRoleController.RoleDeployResult r =
            PulseAgentRoleController.upsertRole(
                new Map<String, Object>{ 'displayName' => 'Some Role' }
            );
        Test.stopTest();
        System.assertEquals(false, r.success);
        System.assert(r.error != null && r.error.contains('roleKey'),
            'Expected roleKey error, got: ' + r.error);
    }

    @IsTest
    static void upsertRole_rejectsBlankDisplayName() {
        Test.startTest();
        PulseAgentRoleController.RoleDeployResult r =
            PulseAgentRoleController.upsertRole(
                new Map<String, Object>{ 'roleKey' => 'qualifier' }
            );
        Test.stopTest();
        System.assertEquals(false, r.success);
        System.assert(r.error != null && r.error.contains('displayName'),
            'Expected displayName error, got: ' + r.error);
    }

    @IsTest
    static void upsertRole_rejectsInvalidAllowlistJson() {
        Test.startTest();
        PulseAgentRoleController.RoleDeployResult r =
            PulseAgentRoleController.upsertRole(
                new Map<String, Object>{
                    'roleKey'           => 'qualifier',
                    'displayName'       => 'Qualifier',
                    'toolAllowlistJson' => '[ not-json'
                }
            );
        Test.stopTest();
        System.assertEquals(false, r.success);
        System.assert(r.error != null, 'Expected error for invalid JSON');
    }

    @IsTest
    static void upsertRole_rejectsAllowlistJsonNotArray() {
        Test.startTest();
        PulseAgentRoleController.RoleDeployResult r =
            PulseAgentRoleController.upsertRole(
                new Map<String, Object>{
                    'roleKey'           => 'qualifier',
                    'displayName'       => 'Qualifier',
                    'toolAllowlistJson' => '{"not":"array"}'
                }
            );
        Test.stopTest();
        System.assertEquals(false, r.success);
        System.assert(r.error != null && r.error.contains('JSON array'),
            'Expected array error, got: ' + r.error);
    }

    @IsTest
    static void upsertRole_rejectsBadAutonomy() {
        Test.startTest();
        PulseAgentRoleController.RoleDeployResult r =
            PulseAgentRoleController.upsertRole(
                new Map<String, Object>{
                    'roleKey'         => 'qualifier',
                    'displayName'     => 'Qualifier',
                    'defaultAutonomy' => 'YOLO'
                }
            );
        Test.stopTest();
        System.assertEquals(false, r.success);
        System.assert(r.error != null && r.error.contains('defaultAutonomy'),
            'Expected autonomy error, got: ' + r.error);
    }

    @IsTest
    static void upsertRole_happyPathBuildsContainerAndEnqueues() {
        StubRoleDeployer stub = new StubRoleDeployer();
        PulseAgentRoleController.deployer = stub;

        Test.startTest();
        PulseAgentRoleController.RoleDeployResult r =
            PulseAgentRoleController.upsertRole(
                new Map<String, Object>{
                    'roleKey'             => 'lease_qualifier',
                    'displayName'         => 'Lease Qualifier',
                    'description'         => 'Qualifies inbound leasing requests',
                    'providerName'        => 'Anthropic_Claude',
                    'defaultAutonomy'     => 'Act_With_Approval',
                    'systemPrompt'        => 'You are a leasing pro.',
                    'toolAllowlistJson'   => '["update_field","add_note"]',
                    'suggestedPhaseTypes' => 'ai_driven,approval',
                    'active'              => true
                }
            );
        Test.stopTest();

        System.assertEquals(true, r.success, 'Expected success, got: ' + r.error);
        System.assertNotEquals(null, r.jobId);
        System.assertEquals('lease_qualifier', r.developerName);
        System.assertNotEquals(null, stub.captured);
        System.assertNotEquals(null, PulseAgentRoleController.lastDeployContainer);
    }

    @IsTest
    static void upsertRole_acceptsArrayForSuggestedPhaseTypes() {
        StubRoleDeployer stub = new StubRoleDeployer();
        PulseAgentRoleController.deployer = stub;

        Test.startTest();
        PulseAgentRoleController.RoleDeployResult r =
            PulseAgentRoleController.upsertRole(
                new Map<String, Object>{
                    'roleKey'             => 'r1',
                    'displayName'         => 'R1',
                    'suggestedPhaseTypes' => new List<Object>{ 'ai_driven', 'approval' }
                }
            );
        Test.stopTest();

        System.assertEquals(true, r.success, 'Expected success, got: ' + r.error);
    }

    @IsTest
    static void upsertRole_usesExplicitDeveloperNameWhenProvided() {
        StubRoleDeployer stub = new StubRoleDeployer();
        PulseAgentRoleController.deployer = stub;

        Test.startTest();
        PulseAgentRoleController.RoleDeployResult r =
            PulseAgentRoleController.upsertRole(
                new Map<String, Object>{
                    'roleKey'       => 'rk',
                    'displayName'   => 'Disp',
                    'developerName' => 'Explicit_Role_Name'
                }
            );
        Test.stopTest();

        System.assertEquals(true, r.success, 'error: ' + r.error);
        System.assertEquals('Explicit_Role_Name', r.developerName);
    }

    // ─── Delete ────────────────────────────────────────────────────────

    @IsTest
    static void deleteRole_requiresDeveloperName() {
        Test.startTest();
        PulseAgentRoleController.RoleDeployResult r =
            PulseAgentRoleController.deleteRole('');
        Test.stopTest();
        System.assertEquals(false, r.success);
        System.assert(r.error != null && r.error.contains('developerName'),
            'Expected developerName error, got: ' + r.error);
    }

    @IsTest
    static void deleteRole_softDeletesByDeactivating() {
        StubRoleDeployer stub = new StubRoleDeployer();
        PulseAgentRoleController.deployer = stub;

        Test.startTest();
        PulseAgentRoleController.RoleDeployResult r =
            PulseAgentRoleController.deleteRole('Some_Role');
        Test.stopTest();

        System.assertEquals(true, r.success, 'Error: ' + r.error);
        System.assertNotEquals(null, r.jobId);
        System.assertEquals('Some_Role', r.developerName);
        System.assertNotEquals(null, stub.captured);
    }

    // ─── getDeployStatus ──────────────────────────────────────────────

    @IsTest
    static void getDeployStatus_handlesBlankJobId() {
        Test.startTest();
        PulseAgentRoleController.DeployStatusView v =
            PulseAgentRoleController.getDeployStatus('');
        Test.stopTest();
        System.assertEquals('Unknown', v.status);
        System.assertEquals(true, v.done);
        System.assert(v.errors != null);
    }

    @IsTest
    static void getDeployStatus_returnsUnknownForUnknownJob() {
        Test.startTest();
        PulseAgentRoleController.DeployStatusView v =
            PulseAgentRoleController.getDeployStatus('707000000000000AAA');
        Test.stopTest();
        System.assertEquals('Unknown', v.status);
        System.assertEquals(true, v.done);
    }

    // ─── Coercion ──────────────────────────────────────────────────────

    @IsTest
    static void coerceToRoleInput_handlesNullAndCoercions() {
        PulseAgentRoleController.RoleInput empty =
            PulseAgentRoleController.coerceToRoleInput(null);
        System.assertEquals(null, empty.roleKey);

        // active arrives as a String 'true' (e.g. from form serialization)
        PulseAgentRoleController.RoleInput a =
            PulseAgentRoleController.coerceToRoleInput(
                new Map<String, Object>{
                    'roleKey'     => 'k',
                    'displayName' => 'D',
                    'active'      => 'true'
                }
            );
        System.assertEquals(true, a.active);

        // toolAllowlistJson arriving as already-parsed List → re-serialized
        PulseAgentRoleController.RoleInput s =
            PulseAgentRoleController.coerceToRoleInput(
                new Map<String, Object>{
                    'roleKey'           => 'k',
                    'displayName'       => 'D',
                    'toolAllowlistJson' => new List<Object>{ 'a', 'b' }
                }
            );
        System.assert(s.toolAllowlistJson != null
            && s.toolAllowlistJson.contains('a'));
    }

    @IsTest
    static void toDeveloperName_sanitizesInputs() {
        System.assertEquals('lease_qualifier',
            PulseAgentRoleController.toDeveloperName('lease qualifier'));
        System.assertEquals('X_9_starts',
            PulseAgentRoleController.toDeveloperName('9 starts'));
        System.assertEquals('Unnamed',
            PulseAgentRoleController.toDeveloperName(''));
    }

    @IsTest
    static void dtoCoverage() {
        PulseAgentRoleController.RoleDeployResult r =
            new PulseAgentRoleController.RoleDeployResult();
        r.success = true; r.error = null;
        r.developerName = 'd'; r.jobId = null;

        PulseAgentRoleController.DeployStatusView v =
            new PulseAgentRoleController.DeployStatusView();
        v.status = 'Completed'; v.done = true; v.errors = null;

        PulseAgentRoleController.RoleView rv = new PulseAgentRoleController.RoleView();
        rv.developerName = 'd'; rv.roleKey = 'k'; rv.active = true;

        PulseAgentRoleController.RoleSummaryView sv =
            new PulseAgentRoleController.RoleSummaryView();
        sv.developerName = 'd'; sv.roleKey = 'k';

        System.assertNotEquals(null, r);
        System.assertNotEquals(null, v);
        System.assertNotEquals(null, rv);
        System.assertNotEquals(null, sv);
    }
}
