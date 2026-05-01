/**
 * Tests for the role-aware resolveAgent merge in WorkflowContract.
 * Covers:
 *  - 3-level inheritance (workflow → phase → action)
 *  - Agent_Role__mdt defaults filling unset fields
 *  - Per-level overrides winning over role defaults
 *  - promptAddendum appending to system prompt
 *  - Tool allowlist parsed from role JSON
 *  - Inactive / missing role handled gracefully
 *
 * Uses WorkflowContract.roleOverrideForTest to inject a fake role map so
 * the tests don't depend on Agent_Role__mdt records actually existing in
 * the org. Hermetic + fast.
 */
@IsTest
private class AgentRoleResolutionTest {

    // ─── Helpers ────────────────────────────────────────────────

    private static Agent_Role__mdt makeRole(
        String roleKey, String displayName, String autonomy,
        String provider, String systemPrompt, String allowlistJson
    ) {
        return new Agent_Role__mdt(
            DeveloperName = roleKey + '_dev',
            Role_Key__c = roleKey,
            Display_Name__c = displayName,
            Default_Autonomy__c = autonomy,
            Provider_Name__c = provider,
            System_Prompt__c = systemPrompt,
            Tool_Allowlist_JSON__c = allowlistJson,
            Active__c = true
        );
    }

    private static void seedRoles(Map<String, Agent_Role__mdt> rolesByKey) {
        WorkflowContract.roleOverrideForTest = rolesByKey;
    }

    // ─── 3-level inheritance ────────────────────────────────────

    @IsTest
    static void resolvesPhaseOverridesWorkflow() {
        Map<String, Object> wf = new Map<String, Object>{
            'enabled' => true, 'persona' => 'WorkflowAgent', 'autonomy' => 'Propose_Only'
        };
        Map<String, Object> st = new Map<String, Object>{
            'persona' => 'PhaseAgent'
        };

        Map<String, Object> resolved = WorkflowContract.resolveAgent(wf, st, null);

        System.assertEquals('PhaseAgent', resolved.get('persona'),
            'Phase persona should win over workflow');
        System.assertEquals('Propose_Only', resolved.get('autonomy'),
            'Workflow autonomy should be inherited');
    }

    @IsTest
    static void resolvesActionOverridesPhaseAndWorkflow() {
        Map<String, Object> wf = new Map<String, Object>{
            'enabled' => true, 'persona' => 'WorkflowAgent', 'autonomy' => 'Propose_Only'
        };
        Map<String, Object> st = new Map<String, Object>{
            'persona' => 'PhaseAgent', 'autonomy' => 'Act_With_Approval'
        };
        Map<String, Object> act = new Map<String, Object>{
            'persona' => 'ActionAgent'
        };

        Map<String, Object> resolved = WorkflowContract.resolveAgent(wf, st, act);

        System.assertEquals('ActionAgent', resolved.get('persona'));
        System.assertEquals('Act_With_Approval', resolved.get('autonomy'));
    }

    @IsTest
    static void emptyAllLevelsReturnsNull() {
        System.assertEquals(null,
            WorkflowContract.resolveAgent(null, null, null));
        System.assertEquals(null,
            WorkflowContract.resolveAgent(
                new Map<String, Object>(), new Map<String, Object>(), null));
    }

    @IsTest
    static void enabledFalseAtAnyLevelDisablesAgent() {
        Map<String, Object> wf = new Map<String, Object>{ 'enabled' => true, 'persona' => 'X' };
        Map<String, Object> st = new Map<String, Object>{ 'enabled' => false };

        // Most-specific scope wins: phase explicitly disables.
        System.assertEquals(null,
            WorkflowContract.resolveAgent(wf, st, null));
    }

    // ─── Role library defaults ──────────────────────────────────

    @IsTest
    static void roleProvidesDefaults() {
        seedRoles(new Map<String, Agent_Role__mdt>{
            'lease_coordinator' => makeRole(
                'lease_coordinator', 'Lease Coordinator',
                'Act_With_Approval', 'Anthropic',
                'You coordinate commercial lease applications.', null
            )
        });

        Map<String, Object> wf = new Map<String, Object>{
            'enabled' => true, 'roleKey' => 'lease_coordinator'
        };

        Map<String, Object> resolved = WorkflowContract.resolveAgent(wf, null, null);

        System.assertEquals('Lease Coordinator', resolved.get('persona'),
            'Role display name should fill empty persona');
        System.assertEquals('Act_With_Approval', resolved.get('autonomy'));
        System.assertEquals('Anthropic', resolved.get('provider'));
        System.assertEquals(
            'You coordinate commercial lease applications.',
            resolved.get('systemPrompt')
        );
    }

    @IsTest
    static void explicitOverrideWinsOverRole() {
        seedRoles(new Map<String, Agent_Role__mdt>{
            'lease_coordinator' => makeRole(
                'lease_coordinator', 'Lease Coordinator',
                'Act_With_Approval', 'Anthropic',
                'Role prompt.', null
            )
        });

        Map<String, Object> wf = new Map<String, Object>{
            'enabled' => true, 'roleKey' => 'lease_coordinator',
            'persona' => 'Custom Persona',
            'autonomy' => 'Autonomous_Safe',
            'provider' => 'Agentforce'
        };

        Map<String, Object> resolved = WorkflowContract.resolveAgent(wf, null, null);

        System.assertEquals('Custom Persona', resolved.get('persona'));
        System.assertEquals('Autonomous_Safe', resolved.get('autonomy'));
        System.assertEquals('Agentforce', resolved.get('provider'));
        // systemPrompt wasn't overridden — role's prompt should apply.
        System.assertEquals('Role prompt.', resolved.get('systemPrompt'));
    }

    // ─── promptAddendum ──────────────────────────────────────────

    @IsTest
    static void promptAddendumAppendsToRolePrompt() {
        seedRoles(new Map<String, Agent_Role__mdt>{
            'sales_rep' => makeRole(
                'sales_rep', 'Sales Rep', 'Act_With_Approval', 'Anthropic',
                'Base sales rep prompt.', null
            )
        });

        Map<String, Object> wf = new Map<String, Object>{
            'enabled' => true, 'roleKey' => 'sales_rep'
        };
        Map<String, Object> st = new Map<String, Object>{
            'promptAddendum' => 'For renewals, also confirm the discount tier.'
        };

        Map<String, Object> resolved = WorkflowContract.resolveAgent(wf, st, null);

        String prompt = (String) resolved.get('systemPrompt');
        System.assert(prompt.contains('Base sales rep prompt.'));
        System.assert(prompt.contains('For renewals'));
        System.assert(!resolved.containsKey('promptAddendum'),
            'Addendum should be consumed after appending');
    }

    @IsTest
    static void promptAddendumWithNoRoleStillApplies() {
        Map<String, Object> wf = new Map<String, Object>{
            'enabled' => true, 'systemPrompt' => 'Explicit prompt.'
        };
        Map<String, Object> act = new Map<String, Object>{
            'promptAddendum' => 'Plus this rule.'
        };

        Map<String, Object> resolved = WorkflowContract.resolveAgent(wf, null, act);

        System.assertEquals('Explicit prompt.\n\nPlus this rule.',
            resolved.get('systemPrompt'));
    }

    // ─── Tool allowlist ──────────────────────────────────────────

    @IsTest
    static void toolAllowlistParsedFromRole() {
        seedRoles(new Map<String, Agent_Role__mdt>{
            'email_only' => makeRole(
                'email_only', 'Email Only Agent',
                'Act_With_Approval', null,
                'Sends emails only.', '["send_email"]'
            )
        });

        Map<String, Object> wf = new Map<String, Object>{
            'enabled' => true, 'roleKey' => 'email_only'
        };

        Map<String, Object> resolved = WorkflowContract.resolveAgent(wf, null, null);

        Object listObj = resolved.get('toolAllowlist');
        System.assert(listObj instanceof List<Object>);
        List<Object> allow = (List<Object>) listObj;
        System.assertEquals(1, allow.size());
        System.assertEquals('send_email', (String) allow[0]);
    }

    @IsTest
    static void explicitToolAllowlistWinsOverRole() {
        seedRoles(new Map<String, Agent_Role__mdt>{
            'email_only' => makeRole(
                'email_only', 'Email Only', 'Act_With_Approval', null,
                'x', '["send_email"]'
            )
        });

        Map<String, Object> wf = new Map<String, Object>{
            'enabled' => true, 'roleKey' => 'email_only',
            'toolAllowlist' => new List<Object>{ 'send_email', 'update_record' }
        };

        Map<String, Object> resolved = WorkflowContract.resolveAgent(wf, null, null);

        List<Object> allow = (List<Object>) resolved.get('toolAllowlist');
        System.assertEquals(2, allow.size(),
            'Explicit allowlist on the workflow should override the role default');
    }

    @IsTest
    static void malformedAllowlistJsonIsIgnored() {
        seedRoles(new Map<String, Agent_Role__mdt>{
            'broken' => makeRole(
                'broken', 'Broken', 'Act_With_Approval', null,
                'x', '{ this is not valid json'
            )
        });

        Map<String, Object> wf = new Map<String, Object>{
            'enabled' => true, 'roleKey' => 'broken'
        };

        Map<String, Object> resolved = WorkflowContract.resolveAgent(wf, null, null);

        System.assert(!resolved.containsKey('toolAllowlist'),
            'Malformed allowlist should not surface as a list — better to allow all than fail the turn');
    }

    // ─── Missing role ───────────────────────────────────────────

    @IsTest
    static void missingRoleResolvesWithBareDefaults() {
        seedRoles(new Map<String, Agent_Role__mdt>());

        Map<String, Object> wf = new Map<String, Object>{
            'enabled' => true, 'roleKey' => 'does_not_exist'
        };

        Map<String, Object> resolved = WorkflowContract.resolveAgent(wf, null, null);

        // Bare defaults — persona "Claude", autonomy Act_With_Approval.
        System.assertEquals('Claude', resolved.get('persona'));
        System.assertEquals('Act_With_Approval', resolved.get('autonomy'));
        System.assert(!resolved.containsKey('provider'),
            'No role found, no level set provider → unset, falls back to org default at facade');
    }
}
