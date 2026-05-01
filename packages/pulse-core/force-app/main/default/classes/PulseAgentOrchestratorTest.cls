/**
 * PulseAgentOrchestratorTest
 *
 * Covers the Agent Mode turn engine end-to-end without hitting a real AI
 * provider. The orchestrator exposes `setResponseForTest(...)` so each
 * scenario short-circuits the provider call with a crafted
 * PulseAiModels.Response and then asserts on the resulting
 * Agent_Decision__c / Workflow_Action__c state.
 */
@IsTest
private class PulseAgentOrchestratorTest {

    // A workflow contract with workflow-level agent enabled so
    // agentConfigForPhase resolves to a non-null, enabled config.
    private static final String CONTRACT_JSON =
        '{"schema":"pulse.workflow.v1","workflowKey":"agent_orch_test","version":1,' +
        '"subjectKinds":["Opportunity"],' +
        '"agent":{"enabled":true,"persona":"Claude","autonomy":"Act_With_Approval",' +
          '"systemPrompt":"Test persona."},' +
        '"states":[' +
          '{"key":"intake","label":"Intake","type":"form",' +
            '"fields":[{"key":"headcount","label":"Headcount","type":"Number","required":true}],' +
            '"transitions":[{"signal":"qualify","to":"qualified"},{"signal":"decline","to":"declined"}]},' +
          '{"key":"qualified","label":"Qualified","type":"terminal","transitions":[]},' +
          '{"key":"declined","label":"Declined","type":"terminal","transitions":[]}' +
        ']}';

    // ─── Fixture helpers ────────────────────────────────────────

    private static Workflow_Instance__c seedInstance() {
        Workflow_Definition__c def = new Workflow_Definition__c(
            Workflow_Key__c = 'agent_orch_test',
            Version__c = 1,
            Status__c = 'Published',
            Definition_JSON__c = CONTRACT_JSON,
            Subject_Kinds__c = 'Opportunity'
        );
        insert def;

        Opportunity opp = new Opportunity(
            Name = 'Agent Orchestrator Test Opp',
            StageName = 'Qualification',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;

        Workflow_Instance__c inst = new Workflow_Instance__c(
            Workflow_Definition__c = def.Id,
            Current_State__c = 'intake',
            Status__c = 'Active',
            Parent_Object_Type__c = 'Opportunity',
            Parent_Record_Id__c = opp.Id,
            Context_JSON__c = '{"applicant_name":"Acme"}'
        );
        insert inst;
        return inst;
    }

    private static PulseAiModels.Response responseWith(String toolKey, Map<String, Object> args) {
        PulseAiModels.Response r = new PulseAiModels.Response();
        PulseAiModels.ToolCall tc = new PulseAiModels.ToolCall();
        tc.id = 'tc_1';
        tc.toolKey = toolKey;
        tc.inputJson = JSON.serialize(args);
        r.toolCalls = new List<PulseAiModels.ToolCall>{ tc };
        return r;
    }

    private static PulseAiModels.Response textOnly(String text) {
        PulseAiModels.Response r = new PulseAiModels.Response();
        r.text = text;
        r.toolCalls = new List<PulseAiModels.ToolCall>();
        return r;
    }

    // ─── propose_action: Act_With_Approval creates a pending action + decision ──

    @IsTest
    static void proposeAction_actWithApproval_createsPendingDecisionAndAction() {
        Workflow_Instance__c inst = seedInstance();

        PulseAgentOrchestrator.setResponseForTest(responseWith(
            PulseAgentOrchestrator.TOOL_PROPOSE,
            new Map<String, Object>{
                'toolKey' => 'send_email',
                'arguments' => new Map<String, Object>{
                    'toAddress' => 'x@y.com',
                    'subject' => 'Hi',
                    'body' => 'Test'
                },
                'rationale' => 'Draft follow-up'
            }
        ));

        Test.startTest();
        PulseAgentOrchestrator.RunResult r = PulseAgentOrchestrator.advance(inst.Id);
        Test.stopTest();
        PulseAgentOrchestrator.clearResponseForTest();

        System.assertEquals(true, r.success, 'advance failed: ' + r.error);
        System.assertEquals(1, r.decisionsCreated);

        Agent_Decision__c d = [
            SELECT Decision_Type__c, Status__c, Related_Action__c, Proposal_JSON__c
            FROM Agent_Decision__c WHERE Workflow_Instance__c = :inst.Id
        ];
        System.assertEquals('Propose_Action', d.Decision_Type__c);
        System.assertEquals('Pending_User', d.Status__c);
        System.assertNotEquals(null, d.Related_Action__c,
            'Act_With_Approval should create a pending Workflow_Action__c');

        Workflow_Action__c a = [
            SELECT Status__c, Tool_Key__c, HITL_Policy__c
            FROM Workflow_Action__c WHERE Id = :d.Related_Action__c
        ];
        System.assertEquals('Pending', a.Status__c);
        System.assertEquals('send_email', a.Tool_Key__c);
    }

    // ─── propose_action: Autonomous_Safe auto-executes safe tools ───

    @IsTest
    static void proposeAction_autonomousSafe_autoExecutesUpdateRecord() {
        Workflow_Instance__c inst = seedInstance();
        Agent_Thread__c t = PulseAgentOrchestrator.getOrCreateThread(inst.Id);
        t.Autonomy_Level__c = PulseAgentOrchestrator.AUT_AUTONOMOUS_SAFE;
        update t;

        // update_record is in AUTONOMOUS_SAFE_TOOLS.
        PulseAgentOrchestrator.setResponseForTest(responseWith(
            PulseAgentOrchestrator.TOOL_PROPOSE,
            new Map<String, Object>{
                'toolKey' => 'update_record',
                'arguments' => new Map<String, Object>{
                    'recordId' => inst.Parent_Record_Id__c,
                    'fields' => new Map<String, Object>{ 'StageName' => 'Qualification' }
                },
                'rationale' => 'Bump stage'
            }
        ));

        Test.startTest();
        PulseAgentOrchestrator.RunResult r = PulseAgentOrchestrator.advance(inst.Id);
        Test.stopTest();
        PulseAgentOrchestrator.clearResponseForTest();

        System.assertEquals(true, r.success, 'advance failed: ' + r.error);
        Agent_Decision__c d = [
            SELECT Status__c FROM Agent_Decision__c
            WHERE Workflow_Instance__c = :inst.Id
        ];
        System.assertEquals('Auto_Executed', d.Status__c,
            'Autonomous_Safe should auto-execute safe tools');
    }

    // ─── propose_action: Propose_Only never creates an action ──────

    @IsTest
    static void proposeAction_proposeOnly_noRelatedAction() {
        Workflow_Instance__c inst = seedInstance();
        Agent_Thread__c t = PulseAgentOrchestrator.getOrCreateThread(inst.Id);
        t.Autonomy_Level__c = PulseAgentOrchestrator.AUT_PROPOSE_ONLY;
        update t;

        PulseAgentOrchestrator.setResponseForTest(responseWith(
            PulseAgentOrchestrator.TOOL_PROPOSE,
            new Map<String, Object>{
                'toolKey' => 'send_email',
                'arguments' => new Map<String, Object>{ 'body' => 'hello' },
                'rationale' => 'propose only'
            }
        ));

        Test.startTest();
        PulseAgentOrchestrator.advance(inst.Id);
        Test.stopTest();
        PulseAgentOrchestrator.clearResponseForTest();

        Agent_Decision__c d = [
            SELECT Status__c, Related_Action__c FROM Agent_Decision__c
            WHERE Workflow_Instance__c = :inst.Id
        ];
        System.assertEquals('Pending_User', d.Status__c);
        System.assertEquals(null, d.Related_Action__c,
            'Propose_Only must not create a Workflow_Action__c');
    }

    // ─── ask_user: creates pending question decision ───────────────

    @IsTest
    static void askUser_createsPendingQuestion() {
        Workflow_Instance__c inst = seedInstance();

        PulseAgentOrchestrator.setResponseForTest(responseWith(
            PulseAgentOrchestrator.TOOL_ASK,
            new Map<String, Object>{
                'prompt' => 'What is the headcount?',
                'fieldKey' => 'headcount',
                'inputType' => 'number',
                'rationale' => 'Missing field'
            }
        ));

        Test.startTest();
        PulseAgentOrchestrator.advance(inst.Id);
        Test.stopTest();
        PulseAgentOrchestrator.clearResponseForTest();

        Agent_Decision__c d = [
            SELECT Decision_Type__c, Status__c, Question_JSON__c
            FROM Agent_Decision__c WHERE Workflow_Instance__c = :inst.Id
        ];
        System.assertEquals('Ask_User', d.Decision_Type__c);
        System.assertEquals('Pending_User', d.Status__c);
        System.assert(d.Question_JSON__c.contains('headcount'));
    }

    // ─── answerQuestion merges into context and re-kicks ───────────

    @IsTest
    static void answerQuestion_mergesIntoContextAndResolves() {
        Workflow_Instance__c inst = seedInstance();

        PulseAgentOrchestrator.setResponseForTest(responseWith(
            PulseAgentOrchestrator.TOOL_ASK,
            new Map<String, Object>{
                'prompt' => 'Headcount?',
                'fieldKey' => 'headcount',
                'rationale' => 'need data'
            }
        ));
        PulseAgentOrchestrator.advance(inst.Id);

        Agent_Decision__c pending = [
            SELECT Id FROM Agent_Decision__c
            WHERE Workflow_Instance__c = :inst.Id AND Status__c = 'Pending_User'
        ];

        // After answering, the orchestrator re-kicks — pre-seed the next
        // turn with an observe so the re-entrant advance stays hermetic.
        PulseAgentOrchestrator.setResponseForTest(responseWith(
            PulseAgentOrchestrator.TOOL_OBSERVE,
            new Map<String, Object>{ 'note' => 'got it' }
        ));

        Test.startTest();
        PulseAgentOrchestrator.RunResult r = PulseAgentOrchestrator.answerQuestion(
            pending.Id, JSON.serialize(new Map<String, Object>{ 'value' => 42 })
        );
        Test.stopTest();
        PulseAgentOrchestrator.clearResponseForTest();

        System.assertEquals(true, r.success, 'advance failed: ' + r.error);
        Agent_Decision__c resolved = [
            SELECT Status__c, User_Response_JSON__c FROM Agent_Decision__c
            WHERE Id = :pending.Id
        ];
        System.assertEquals('Answered', resolved.Status__c);

        Workflow_Instance__c refreshed = [
            SELECT Context_JSON__c FROM Workflow_Instance__c WHERE Id = :inst.Id
        ];
        Map<String, Object> ctx =
            (Map<String, Object>) JSON.deserializeUntyped(refreshed.Context_JSON__c);
        System.assertEquals(42, ctx.get('headcount'),
            'Context should merge the answered value');
    }

    // ─── advance_phase: autonomy > Propose_Only fires transition ───

    @IsTest
    static void advancePhase_actWithApproval_firesTransition() {
        Workflow_Instance__c inst = seedInstance();

        PulseAgentOrchestrator.setResponseForTest(responseWith(
            PulseAgentOrchestrator.TOOL_ADVANCE,
            new Map<String, Object>{
                'signal' => 'qualify',
                'rationale' => 'Applicant qualified'
            }
        ));

        Test.startTest();
        PulseAgentOrchestrator.advance(inst.Id);
        Test.stopTest();
        PulseAgentOrchestrator.clearResponseForTest();

        Workflow_Instance__c refreshed = [
            SELECT Current_State__c FROM Workflow_Instance__c WHERE Id = :inst.Id
        ];
        System.assertEquals('qualified', refreshed.Current_State__c,
            'Advance_Phase should transition the instance');
    }

    // ─── approveDecision with a refined payload marks Refined ──────

    @IsTest
    static void approveDecision_withRefinedPayload_marksRefined() {
        Workflow_Instance__c inst = seedInstance();

        PulseAgentOrchestrator.setResponseForTest(responseWith(
            PulseAgentOrchestrator.TOOL_PROPOSE,
            new Map<String, Object>{
                'toolKey' => 'send_email',
                'arguments' => new Map<String, Object>{ 'body' => 'orig' },
                'rationale' => 'draft'
            }
        ));
        PulseAgentOrchestrator.advance(inst.Id);

        Agent_Decision__c d = [
            SELECT Id, Related_Action__c FROM Agent_Decision__c
            WHERE Workflow_Instance__c = :inst.Id
        ];

        // Re-kick with observe so the post-approve advance stays hermetic.
        PulseAgentOrchestrator.setResponseForTest(responseWith(
            PulseAgentOrchestrator.TOOL_OBSERVE,
            new Map<String, Object>{ 'note' => 'done' }
        ));

        Test.startTest();
        PulseAgentOrchestrator.RunResult r = PulseAgentOrchestrator.approveDecision(
            d.Id, '{"toAddress":"x@y.com","subject":"edited","body":"refined"}'
        );
        Test.stopTest();
        PulseAgentOrchestrator.clearResponseForTest();

        System.assertEquals(true, r.success, 'advance failed: ' + r.error);
        Agent_Decision__c resolved = [
            SELECT Status__c FROM Agent_Decision__c WHERE Id = :d.Id
        ];
        System.assertEquals('Refined', resolved.Status__c,
            'Refined payload should flag Refined, not Approved');
    }

    // ─── rejectDecision resolves the action as rejected ────────────

    @IsTest
    static void rejectDecision_marksDecisionRejected() {
        Workflow_Instance__c inst = seedInstance();

        PulseAgentOrchestrator.setResponseForTest(responseWith(
            PulseAgentOrchestrator.TOOL_PROPOSE,
            new Map<String, Object>{
                'toolKey' => 'send_email',
                'arguments' => new Map<String, Object>{ 'body' => 'x' },
                'rationale' => 'draft'
            }
        ));
        PulseAgentOrchestrator.advance(inst.Id);

        Agent_Decision__c d = [
            SELECT Id FROM Agent_Decision__c WHERE Workflow_Instance__c = :inst.Id
        ];

        PulseAgentOrchestrator.setResponseForTest(responseWith(
            PulseAgentOrchestrator.TOOL_OBSERVE,
            new Map<String, Object>{ 'note' => 'done' }
        ));

        Test.startTest();
        PulseAgentOrchestrator.rejectDecision(d.Id, 'not right');
        Test.stopTest();
        PulseAgentOrchestrator.clearResponseForTest();

        Agent_Decision__c resolved = [
            SELECT Status__c, User_Response_JSON__c FROM Agent_Decision__c WHERE Id = :d.Id
        ];
        System.assertEquals('Rejected', resolved.Status__c);
        System.assert(resolved.User_Response_JSON__c.contains('not right'));
    }

    // ─── invalid tool call input is captured as Error/Skipped ─────

    @IsTest
    static void invalidToolInput_recordsErrorDecision() {
        Workflow_Instance__c inst = seedInstance();

        PulseAiModels.Response bad = new PulseAiModels.Response();
        PulseAiModels.ToolCall tc = new PulseAiModels.ToolCall();
        tc.toolKey = PulseAgentOrchestrator.TOOL_PROPOSE;
        tc.inputJson = '{not valid json';   // malformed on purpose
        bad.toolCalls = new List<PulseAiModels.ToolCall>{ tc };
        PulseAgentOrchestrator.setResponseForTest(bad);

        Test.startTest();
        PulseAgentOrchestrator.advance(inst.Id);
        Test.stopTest();
        PulseAgentOrchestrator.clearResponseForTest();

        Agent_Decision__c d = [
            SELECT Decision_Type__c, Status__c, Rationale__c FROM Agent_Decision__c
            WHERE Workflow_Instance__c = :inst.Id
        ];
        System.assertEquals('Error', d.Decision_Type__c);
        // applyAutonomy funnels unknown decision types into Pending_User so
        // the operator sees and dismisses the failed turn rather than
        // silently skipping it. Rationale still captures the parse error.
        System.assertEquals('Pending_User', d.Status__c);
        System.assert(d.Rationale__c.contains('invalid tool input'),
            'Error decision should capture the parse failure in rationale');
    }

    // ─── text-only response (no tool calls) becomes an Observe ─────

    @IsTest
    static void textOnlyResponse_becomesObserveDecision() {
        Workflow_Instance__c inst = seedInstance();

        PulseAgentOrchestrator.setResponseForTest(textOnly('Nothing to do right now.'));

        Test.startTest();
        PulseAgentOrchestrator.advance(inst.Id);
        Test.stopTest();
        PulseAgentOrchestrator.clearResponseForTest();

        Agent_Decision__c d = [
            SELECT Decision_Type__c, Status__c, Rationale__c FROM Agent_Decision__c
            WHERE Workflow_Instance__c = :inst.Id
        ];
        System.assertEquals('Observe', d.Decision_Type__c);
        System.assertEquals('Skipped', d.Status__c);
        System.assert(d.Rationale__c.contains('Nothing to do'));
    }

    // ─── compaction fires every N decisions ────────────────────────

    @IsTest
    static void compaction_updatesRollingSummaryEveryN() {
        Workflow_Instance__c inst = seedInstance();

        // Run COMPACT_EVERY_N_DECISIONS observe turns so the rolling summary
        // is refreshed on the Nth decision.
        PulseAgentOrchestrator.setResponseForTest(responseWith(
            PulseAgentOrchestrator.TOOL_OBSERVE,
            new Map<String, Object>{ 'note' => 'tick' }
        ));

        Test.startTest();
        for (Integer i = 0; i < PulseAgentOrchestrator.COMPACT_EVERY_N_DECISIONS; i++) {
            PulseAgentOrchestrator.advance(inst.Id);
        }
        Test.stopTest();
        PulseAgentOrchestrator.clearResponseForTest();

        Agent_Thread__c t = [
            SELECT Rolling_Summary__c FROM Agent_Thread__c
            WHERE Workflow_Instance__c = :inst.Id
        ];
        System.assertNotEquals(null, t.Rolling_Summary__c,
            'Summary should populate after COMPACT_EVERY_N_DECISIONS decisions');
        System.assert(t.Rolling_Summary__c.startsWith('Summary of'),
            'Rolling summary should be a human-readable bullet list');
    }

    // ─── advance() is a no-op on an inactive instance ──────────────

    @IsTest
    static void advance_inactiveInstance_isNoOp() {
        Workflow_Instance__c inst = seedInstance();
        inst.Status__c = 'Cancelled';
        update inst;

        Test.startTest();
        PulseAgentOrchestrator.RunResult r = PulseAgentOrchestrator.advance(inst.Id);
        Test.stopTest();

        System.assertEquals(true, r.success);
        System.assertEquals('Instance not active', r.status);
        System.assertEquals(0, [SELECT COUNT() FROM Agent_Decision__c
                                 WHERE Workflow_Instance__c = :inst.Id]);
    }

    // ─── null instanceId returns a clean error ─────────────────────

    @IsTest
    static void advance_nullInstanceId_returnsError() {
        Test.startTest();
        PulseAgentOrchestrator.RunResult r = PulseAgentOrchestrator.advance(null);
        Test.stopTest();
        System.assertEquals(false, r.success);
        System.assertNotEquals(null, r.error);
    }

    // ─── tool allowlist enforcement (proposal §1 step-1) ───────────

    @IsTest
    static void proposeAction_toolNotInAllowlist_isRejected() {
        // Contract whose agent restricts to update_record only.
        String json =
            '{"schema":"pulse.workflow.v1","workflowKey":"allowlist_test","version":1,' +
            '"subjectKinds":["Opportunity"],' +
            '"agent":{"enabled":true,"persona":"Restricted",' +
                     '"autonomy":"Act_With_Approval",' +
                     '"systemPrompt":"You can only update records.",' +
                     '"toolAllowlist":["update_record"]},' +
            '"states":[' +
              '{"key":"intake","label":"Intake","type":"form","transitions":[]}' +
            ']}';

        Workflow_Definition__c def = new Workflow_Definition__c(
            Workflow_Key__c = 'allowlist_test',
            Version__c = 1, Status__c = 'Published',
            Definition_JSON__c = json, Subject_Kinds__c = 'Opportunity'
        );
        insert def;
        Opportunity opp = new Opportunity(
            Name = 'Allowlist Test Opp', StageName = 'Qualification',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        Workflow_Instance__c inst = new Workflow_Instance__c(
            Workflow_Definition__c = def.Id, Current_State__c = 'intake',
            Status__c = 'Active', Parent_Object_Type__c = 'Opportunity',
            Parent_Record_Id__c = opp.Id
        );
        insert inst;

        // Agent proposes send_email — NOT in the allowlist.
        PulseAgentOrchestrator.setResponseForTest(responseWith(
            PulseAgentOrchestrator.TOOL_PROPOSE,
            new Map<String, Object>{
                'toolKey' => 'send_email',
                'arguments' => new Map<String, Object>{ 'toAddress' => 'x@y.com', 'subject' => 'x', 'body' => 'x' },
                'rationale' => 'Trying to email despite restriction'
            }
        ));

        Test.startTest();
        PulseAgentOrchestrator.RunResult r = PulseAgentOrchestrator.advance(inst.Id);
        Test.stopTest();
        PulseAgentOrchestrator.clearResponseForTest();

        System.assertEquals(true, r.success, 'turn itself succeeds; the proposal is what gets rejected');
        Agent_Decision__c d = [
            SELECT Decision_Type__c, Status__c, Rationale__c, Related_Action__c
            FROM Agent_Decision__c WHERE Workflow_Instance__c = :inst.Id
        ];
        System.assertEquals('Propose_Action', d.Decision_Type__c);
        System.assertEquals('Rejected', d.Status__c,
            'Allowlist violation should mark the decision Rejected');
        System.assert(d.Rationale__c.contains('Tool not allowed'),
            'Rationale should explain the rejection: ' + d.Rationale__c);
        System.assertEquals(null, d.Related_Action__c,
            'No Workflow_Action__c should be created for a disallowed tool');
    }

    @IsTest
    static void proposeAction_toolInAllowlist_executes() {
        // Allowlist includes send_email — should behave like the existing
        // Act_With_Approval path.
        String json =
            '{"schema":"pulse.workflow.v1","workflowKey":"allowlist_pass","version":1,' +
            '"subjectKinds":["Opportunity"],' +
            '"agent":{"enabled":true,"persona":"Permissive",' +
                     '"autonomy":"Act_With_Approval",' +
                     '"systemPrompt":"You can email.",' +
                     '"toolAllowlist":["send_email","update_record"]},' +
            '"states":[' +
              '{"key":"intake","label":"Intake","type":"form","transitions":[]}' +
            ']}';

        Workflow_Definition__c def = new Workflow_Definition__c(
            Workflow_Key__c = 'allowlist_pass',
            Version__c = 1, Status__c = 'Published',
            Definition_JSON__c = json, Subject_Kinds__c = 'Opportunity'
        );
        insert def;
        Opportunity opp = new Opportunity(
            Name = 'Allowlist Pass Opp', StageName = 'Qualification',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        Workflow_Instance__c inst = new Workflow_Instance__c(
            Workflow_Definition__c = def.Id, Current_State__c = 'intake',
            Status__c = 'Active', Parent_Object_Type__c = 'Opportunity',
            Parent_Record_Id__c = opp.Id
        );
        insert inst;

        PulseAgentOrchestrator.setResponseForTest(responseWith(
            PulseAgentOrchestrator.TOOL_PROPOSE,
            new Map<String, Object>{
                'toolKey' => 'send_email',
                'arguments' => new Map<String, Object>{ 'toAddress' => 'x@y.com', 'subject' => 'x', 'body' => 'x' },
                'rationale' => 'Allowed email'
            }
        ));

        Test.startTest();
        PulseAgentOrchestrator.RunResult r = PulseAgentOrchestrator.advance(inst.Id);
        Test.stopTest();
        PulseAgentOrchestrator.clearResponseForTest();

        Agent_Decision__c d = [
            SELECT Status__c, Related_Action__c
            FROM Agent_Decision__c WHERE Workflow_Instance__c = :inst.Id
        ];
        System.assertEquals('Pending_User', d.Status__c);
        System.assertNotEquals(null, d.Related_Action__c,
            'Allowed tool should create the pending Workflow_Action_c');
    }
}
