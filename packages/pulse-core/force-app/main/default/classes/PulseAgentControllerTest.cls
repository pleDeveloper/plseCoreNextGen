/**
 * PulseAgentControllerTest
 *
 * Covers the @AuraEnabled bridge that the agent LWCs depend on. Uses the
 * orchestrator's responseForTest hook so each scenario stays hermetic and
 * never touches the AI provider.
 */
@IsTest
private class PulseAgentControllerTest {

    private static final String CONTRACT_JSON =
        '{"schema":"pulse.workflow.v1","workflowKey":"agent_ctrl_test","version":1,' +
        '"subjectKinds":["Opportunity"],' +
        '"agent":{"enabled":true,"persona":"Claude","autonomy":"Act_With_Approval",' +
          '"systemPrompt":"Be helpful."},' +
        '"states":[' +
          '{"key":"intake","label":"Intake","type":"form",' +
            '"fields":[{"key":"headcount","label":"Headcount","type":"Number","required":true}],' +
            '"transitions":[{"signal":"qualify","to":"done"}]},' +
          '{"key":"done","label":"Done","type":"terminal","transitions":[]}' +
        ']}';

    private static Workflow_Instance__c seedInstance() {
        Workflow_Definition__c def = new Workflow_Definition__c(
            Workflow_Key__c = 'agent_ctrl_test',
            Version__c = 1,
            Status__c = 'Published',
            Definition_JSON__c = CONTRACT_JSON,
            Subject_Kinds__c = 'Opportunity'
        );
        insert def;

        Opportunity opp = new Opportunity(
            Name = 'Agent Controller Opp',
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
            Context_JSON__c = '{}'
        );
        insert inst;
        return inst;
    }

    private static PulseAiModels.Response observeResponse() {
        PulseAiModels.Response r = new PulseAiModels.Response();
        PulseAiModels.ToolCall tc = new PulseAiModels.ToolCall();
        tc.toolKey = PulseAgentOrchestrator.TOOL_OBSERVE;
        tc.inputJson = JSON.serialize(new Map<String, Object>{ 'note' => 'tick' });
        r.toolCalls = new List<PulseAiModels.ToolCall>{ tc };
        return r;
    }

    private static PulseAiModels.Response proposeResponse(String toolKey) {
        PulseAiModels.Response r = new PulseAiModels.Response();
        PulseAiModels.ToolCall tc = new PulseAiModels.ToolCall();
        tc.toolKey = PulseAgentOrchestrator.TOOL_PROPOSE;
        tc.inputJson = JSON.serialize(new Map<String, Object>{
            'toolKey' => toolKey,
            'arguments' => new Map<String, Object>{ 'body' => 'hi' },
            'rationale' => 'draft'
        });
        r.toolCalls = new List<PulseAiModels.ToolCall>{ tc };
        return r;
    }

    private static PulseAiModels.Response askResponse(String fieldKey) {
        PulseAiModels.Response r = new PulseAiModels.Response();
        PulseAiModels.ToolCall tc = new PulseAiModels.ToolCall();
        tc.toolKey = PulseAgentOrchestrator.TOOL_ASK;
        tc.inputJson = JSON.serialize(new Map<String, Object>{
            'prompt' => 'What is the headcount?',
            'fieldKey' => fieldKey,
            'rationale' => 'Missing field'
        });
        r.toolCalls = new List<PulseAiModels.ToolCall>{ tc };
        return r;
    }

    // ─── getAgentState ──────────────────────────────────────────

    @IsTest
    static void getAgentState_nullId_returnsDisabled() {
        PulseAgentController.AgentStateView v = PulseAgentController.getAgentState(null);
        System.assertEquals(false, v.enabled);
        System.assertNotEquals(null, v.autonomyOptions);
    }

    @IsTest
    static void getAgentState_enabledReturnsPersonaAndAutonomy() {
        Workflow_Instance__c inst = seedInstance();

        Test.startTest();
        PulseAgentController.AgentStateView v = PulseAgentController.getAgentState(inst.Id);
        Test.stopTest();

        System.assertEquals(true, v.enabled);
        System.assertEquals(inst.Id, v.instanceId);
        System.assertNotEquals(null, v.autonomyOptions);
        System.assert(v.autonomyOptions.size() >= 3);
    }

    // ─── setAutonomy persists on the thread ────────────────────

    @IsTest
    static void setAutonomy_updatesThread() {
        Workflow_Instance__c inst = seedInstance();

        Test.startTest();
        PulseAgentController.AgentStateView v = PulseAgentController.setAutonomy(
            inst.Id, 'Autonomous_Safe'
        );
        Test.stopTest();

        System.assertEquals('Autonomous_Safe', v.autonomy);
        Agent_Thread__c t = [SELECT Autonomy_Level__c FROM Agent_Thread__c
                              WHERE Workflow_Instance__c = :inst.Id];
        System.assertEquals('Autonomous_Safe', t.Autonomy_Level__c);
    }

    @IsTest
    static void setAutonomy_blankValue_isNoOp() {
        Workflow_Instance__c inst = seedInstance();
        PulseAgentController.AgentStateView v = PulseAgentController.setAutonomy(inst.Id, '');
        System.assertEquals(true, v.enabled);
    }

    // ─── kickAgent ─────────────────────────────────────────────

    @IsTest
    static void kickAgent_returnsSuccessAndCreatesDecision() {
        Workflow_Instance__c inst = seedInstance();
        PulseAgentOrchestrator.setResponseForTest(observeResponse());

        Test.startTest();
        PulseAgentController.RunResultView r = PulseAgentController.kickAgent(inst.Id);
        Test.stopTest();
        PulseAgentOrchestrator.clearResponseForTest();

        System.assertEquals(true, r.success, 'run failed: ' + r.error);
        System.assertEquals(1, r.decisionsCreated);
    }

    @IsTest
    static void kickAgent_nullId_returnsError() {
        PulseAgentController.RunResultView r = PulseAgentController.kickAgent(null);
        System.assertEquals(false, r.success);
    }

    // ─── getPendingDecisions + getDecisionLog cover both filters ──

    @IsTest
    static void getPendingDecisions_andDecisionLog_filterByStatus() {
        Workflow_Instance__c inst = seedInstance();

        // Create a pending proposal first
        PulseAgentOrchestrator.setResponseForTest(proposeResponse('send_email'));
        PulseAgentOrchestrator.advance(inst.Id);
        PulseAgentOrchestrator.clearResponseForTest();

        List<PulseAgentController.DecisionView> pending =
            PulseAgentController.getPendingDecisions(inst.Id);
        System.assertEquals(1, pending.size());
        System.assertEquals('Pending_User', pending[0].status);
        // previewKind should classify a send_email proposal as 'email'
        System.assertEquals('email', pending[0].previewKind);

        // Log shows resolved-only — currently empty.
        List<PulseAgentController.DecisionView> log =
            PulseAgentController.getDecisionLog(inst.Id);
        System.assertEquals(0, log.size());

        // Resolve via reject; decision lands in the log.
        PulseAgentOrchestrator.setResponseForTest(observeResponse());
        PulseAgentController.RunResultView rr = PulseAgentController.rejectDecision(
            new Map<String, Object>{
                'decisionId' => pending[0].decisionId,
                'reason' => 'not now'
            }
        );
        PulseAgentOrchestrator.clearResponseForTest();
        System.assertEquals(true, rr.success, 'reject failed: ' + rr.error);

        List<PulseAgentController.DecisionView> log2 =
            PulseAgentController.getDecisionLog(inst.Id);
        System.assert(log2.size() >= 1, 'Rejected decision should appear in the log');
        Boolean foundRejected = false;
        for (PulseAgentController.DecisionView dv : log2) {
            if (dv.status == 'Rejected') foundRejected = true;
        }
        System.assert(foundRejected);
    }

    @IsTest
    static void getPendingDecisions_null_returnsEmpty() {
        List<PulseAgentController.DecisionView> out = PulseAgentController.getPendingDecisions(null);
        System.assertEquals(0, out.size());
    }

    @IsTest
    static void getDecisionLog_null_returnsEmpty() {
        List<PulseAgentController.DecisionView> out = PulseAgentController.getDecisionLog(null);
        System.assertEquals(0, out.size());
    }

    // ─── approveDecision / rejectDecision payload edge cases ──────

    @IsTest
    static void approveDecision_nullPayload_returnsError() {
        PulseAgentController.RunResultView r = PulseAgentController.approveDecision(null);
        System.assertEquals(false, r.success);
    }

    @IsTest
    static void rejectDecision_nullPayload_returnsError() {
        PulseAgentController.RunResultView r = PulseAgentController.rejectDecision(null);
        System.assertEquals(false, r.success);
    }

    @IsTest
    static void answerQuestion_nullPayload_returnsError() {
        PulseAgentController.RunResultView r = PulseAgentController.answerQuestion(null);
        System.assertEquals(false, r.success);
    }

    // ─── Aura deserialization edge case: Id passed as String ──────

    @IsTest
    static void approveDecision_stringIdInPayload_coercesToId() {
        Workflow_Instance__c inst = seedInstance();
        PulseAgentOrchestrator.setResponseForTest(proposeResponse('send_email'));
        PulseAgentOrchestrator.advance(inst.Id);
        PulseAgentOrchestrator.clearResponseForTest();

        Agent_Decision__c d = [SELECT Id FROM Agent_Decision__c
                                WHERE Workflow_Instance__c = :inst.Id];

        // Re-kick hermetically.
        PulseAgentOrchestrator.setResponseForTest(observeResponse());

        Test.startTest();
        // Pass the Id as a plain String — the controller coerces back to Id.
        PulseAgentController.RunResultView r = PulseAgentController.approveDecision(
            new Map<String, Object>{
                'decisionId' => String.valueOf(d.Id),
                'refinedPayloadJson' => null
            }
        );
        Test.stopTest();
        PulseAgentOrchestrator.clearResponseForTest();

        System.assertEquals(true, r.success, 'run failed: ' + r.error);
    }

    // ─── answerQuestion accepts responseJson as either string or map ──

    @IsTest
    static void answerQuestion_responseJsonAsMap_isSerialized() {
        Workflow_Instance__c inst = seedInstance();

        PulseAgentOrchestrator.setResponseForTest(askResponse('headcount'));
        PulseAgentOrchestrator.advance(inst.Id);
        PulseAgentOrchestrator.clearResponseForTest();

        Agent_Decision__c d = [SELECT Id FROM Agent_Decision__c
                                WHERE Workflow_Instance__c = :inst.Id];

        // Re-kick hermetically
        PulseAgentOrchestrator.setResponseForTest(observeResponse());

        Test.startTest();
        // responseJson is provided as a map here, not a String — controller
        // should JSON-serialize it before handing to the orchestrator.
        PulseAgentController.RunResultView r = PulseAgentController.answerQuestion(
            new Map<String, Object>{
                'decisionId' => d.Id,
                'responseJson' => new Map<String, Object>{ 'value' => 22 }
            }
        );
        Test.stopTest();
        PulseAgentOrchestrator.clearResponseForTest();

        System.assertEquals(true, r.success, 'run failed: ' + r.error);

        Workflow_Instance__c refreshed = [
            SELECT Context_JSON__c FROM Workflow_Instance__c WHERE Id = :inst.Id
        ];
        Map<String, Object> ctx =
            (Map<String, Object>) JSON.deserializeUntyped(refreshed.Context_JSON__c);
        System.assertEquals(22, ctx.get('headcount'));
    }

    // ─── getFieldQuestions + dismissFieldQuestion ──────────────

    @IsTest
    static void getFieldQuestions_returnsPendingAskWithFieldKey() {
        Workflow_Instance__c inst = seedInstance();

        // Create a pending Ask_User decision with a fieldKey
        PulseAgentOrchestrator.setResponseForTest(askResponse('headcount'));
        PulseAgentOrchestrator.advance(inst.Id);
        PulseAgentOrchestrator.clearResponseForTest();

        Test.startTest();
        List<PulseAgentController.FieldQuestionView> questions =
            PulseAgentController.getFieldQuestions(inst.Id);
        Test.stopTest();

        System.assertEquals(1, questions.size(), 'expected one field question');
        System.assertEquals('headcount', questions[0].fieldKey);
        System.assertEquals('What is the headcount?', questions[0].prompt);
        System.assertNotEquals(null, questions[0].decisionId);
    }

    @IsTest
    static void getFieldQuestions_excludesAskWithoutFieldKey() {
        Workflow_Instance__c inst = seedInstance();

        // Create a generic Ask (no fieldKey)
        PulseAiModels.Response resp = new PulseAiModels.Response();
        PulseAiModels.ToolCall tc = new PulseAiModels.ToolCall();
        tc.toolKey = PulseAgentOrchestrator.TOOL_ASK;
        tc.inputJson = JSON.serialize(new Map<String, Object>{
            'prompt' => 'Generic question',
            'rationale' => 'no fieldKey'
        });
        resp.toolCalls = new List<PulseAiModels.ToolCall>{ tc };
        PulseAgentOrchestrator.setResponseForTest(resp);
        PulseAgentOrchestrator.advance(inst.Id);
        PulseAgentOrchestrator.clearResponseForTest();

        List<PulseAgentController.FieldQuestionView> questions =
            PulseAgentController.getFieldQuestions(inst.Id);
        System.assertEquals(0, questions.size(),
            'Ask_User without fieldKey should not surface as a field question');
    }

    @IsTest
    static void getFieldQuestions_nullId_returnsEmpty() {
        List<PulseAgentController.FieldQuestionView> q =
            PulseAgentController.getFieldQuestions(null);
        System.assertEquals(0, q.size());
    }

    @IsTest
    static void dismissFieldQuestion_rejectsDecision() {
        Workflow_Instance__c inst = seedInstance();

        PulseAgentOrchestrator.setResponseForTest(askResponse('headcount'));
        PulseAgentOrchestrator.advance(inst.Id);
        PulseAgentOrchestrator.clearResponseForTest();

        Agent_Decision__c d = [
            SELECT Id FROM Agent_Decision__c
            WHERE Workflow_Instance__c = :inst.Id AND Decision_Type__c = 'Ask_User'
        ];

        // Re-kick hermetically so the orchestrator has a canned response
        // for the post-reject follow-up turn.
        PulseAgentOrchestrator.setResponseForTest(observeResponse());

        Test.startTest();
        PulseAgentController.RunResultView r = PulseAgentController.dismissFieldQuestion(
            new Map<String, Object>{ 'decisionId' => d.Id }
        );
        Test.stopTest();
        PulseAgentOrchestrator.clearResponseForTest();

        System.assertEquals(true, r.success, 'dismiss failed: ' + r.error);

        Agent_Decision__c refreshed = [
            SELECT Status__c FROM Agent_Decision__c WHERE Id = :d.Id
        ];
        System.assertEquals('Rejected', refreshed.Status__c);
    }

    @IsTest
    static void dismissFieldQuestion_nullPayload_returnsError() {
        PulseAgentController.RunResultView r =
            PulseAgentController.dismissFieldQuestion(null);
        System.assertEquals(false, r.success);
    }
}
