@IsTest
private class WorkflowRuntimeTest {

    // ─── Valid transition ────────────────────────────────────────

    @IsTest
    static void validTransitionAdvancesState() {
        Workflow_Definition__c def = insertDefinition();
        Workflow_Instance__c inst = insertInstance(def.Id, 'intake');

        WorkflowAdvanceRequest req = new WorkflowAdvanceRequest(inst.Id, 'submit');
        req.payloadJson = '{"patient_name":"Dr. Smith"}';

        Test.startTest();
        List<WorkflowRuntime.AdvanceResult> results = WorkflowRuntime.advance(
            new List<WorkflowAdvanceRequest>{ req }
        );
        Test.stopTest();

        System.assertEquals(1, results.size());
        WorkflowRuntime.AdvanceResult r = results[0];
        System.assertEquals(true, r.success, 'validTransition: error=' + r.error);
        System.assertEquals(false, r.idempotent);
        System.assertEquals('intake', r.fromState);
        System.assertEquals('review', r.toState);

        // Verify persisted instance state
        Workflow_Instance__c updated = [
            SELECT Current_State__c, Status__c FROM Workflow_Instance__c WHERE Id = :inst.Id
        ];
        System.assertEquals('review', updated.Current_State__c);
        System.assertEquals('Active', updated.Status__c);

        // Verify step result
        List<Workflow_Step_Result__c> steps = [
            SELECT State_Key__c, Signal__c, Outcome__c, Values_JSON__c
            FROM Workflow_Step_Result__c
            WHERE Workflow_Instance__c = :inst.Id
        ];
        System.assertEquals(1, steps.size());
        System.assertEquals('intake', steps[0].State_Key__c);
        System.assertEquals('submit', steps[0].Signal__c);
        System.assertEquals('Completed', steps[0].Outcome__c);
        System.assertEquals('{"patient_name":"Dr. Smith"}', steps[0].Values_JSON__c);

        // Verify audit event
        List<Workflow_Event__c> events = [
            SELECT Event_Type__c, Source_State__c, Target_State__c
            FROM Workflow_Event__c
            WHERE Workflow_Instance__c = :inst.Id
        ];
        System.assertEquals(1, events.size());
        System.assertEquals('Transition', events[0].Event_Type__c);
        System.assertEquals('intake', events[0].Source_State__c);
        System.assertEquals('review', events[0].Target_State__c);
    }

    // ─── Invalid signal ──────────────────────────────────────────

    @IsTest
    static void invalidSignalReturnsError() {
        Workflow_Definition__c def = insertDefinition();
        Workflow_Instance__c inst = insertInstance(def.Id, 'intake');

        WorkflowAdvanceRequest req = new WorkflowAdvanceRequest(inst.Id, 'approve');

        Test.startTest();
        List<WorkflowRuntime.AdvanceResult> results = WorkflowRuntime.advance(
            new List<WorkflowAdvanceRequest>{ req }
        );
        Test.stopTest();

        System.assertEquals(1, results.size());
        WorkflowRuntime.AdvanceResult r = results[0];
        System.assertEquals(false, r.success);
        System.assert(r.error.contains('not valid'), r.error);

        // No step results or events created
        System.assertEquals(0, [SELECT COUNT() FROM Workflow_Step_Result__c WHERE Workflow_Instance__c = :inst.Id]);
        System.assertEquals(0, [SELECT COUNT() FROM Workflow_Event__c WHERE Workflow_Instance__c = :inst.Id]);

        // Instance state unchanged
        Workflow_Instance__c unchanged = [
            SELECT Current_State__c FROM Workflow_Instance__c WHERE Id = :inst.Id
        ];
        System.assertEquals('intake', unchanged.Current_State__c);
    }

    // ─── Mixed batch ─────────────────────────────────────────────

    @IsTest
    static void mixedBatchProcessesIndependently() {
        Workflow_Definition__c def = insertDefinition();
        Workflow_Instance__c good = insertInstance(def.Id, 'intake');
        Workflow_Instance__c bad = insertInstance(def.Id, 'intake');

        List<WorkflowAdvanceRequest> requests = new List<WorkflowAdvanceRequest>{
            new WorkflowAdvanceRequest(good.Id, 'submit'),
            new WorkflowAdvanceRequest(bad.Id, 'approve')  // invalid for intake
        };

        Test.startTest();
        List<WorkflowRuntime.AdvanceResult> results = WorkflowRuntime.advance(requests);
        Test.stopTest();

        System.assertEquals(2, results.size());
        System.assertEquals(true, results[0].success, 'mixedBatch: error=' + results[0].error);
        System.assertEquals(false, results[1].success);
        System.assert(results[1].error.contains('not valid'), results[1].error);

        // Good instance advanced
        Workflow_Instance__c goodUpdated = [
            SELECT Current_State__c FROM Workflow_Instance__c WHERE Id = :good.Id
        ];
        System.assertEquals('review', goodUpdated.Current_State__c);

        // Bad instance unchanged
        Workflow_Instance__c badUnchanged = [
            SELECT Current_State__c FROM Workflow_Instance__c WHERE Id = :bad.Id
        ];
        System.assertEquals('intake', badUnchanged.Current_State__c);

        // Only one step result and one event created (for the good request)
        System.assertEquals(1, [SELECT COUNT() FROM Workflow_Step_Result__c WHERE Workflow_Instance__c = :good.Id]);
        System.assertEquals(0, [SELECT COUNT() FROM Workflow_Step_Result__c WHERE Workflow_Instance__c = :bad.Id]);
    }

    // ─── Idempotent retry guard ──────────────────────────────────

    @IsTest
    static void idempotentRetryReturnsSuccessWithoutDuplicates() {
        Workflow_Definition__c def = insertDefinition();
        Workflow_Instance__c inst = insertInstance(def.Id, 'intake');

        // First advance: intake -> review
        WorkflowAdvanceRequest req1 = new WorkflowAdvanceRequest(inst.Id, 'submit');
        List<WorkflowRuntime.AdvanceResult> first = WorkflowRuntime.advance(
            new List<WorkflowAdvanceRequest>{ req1 }
        );
        System.assertEquals(true, first[0].success, 'First advance failed: ' + first[0].error);
        System.assertEquals(false, first[0].idempotent);

        // Retry same signal — instance is now at "review", so "submit" is not valid
        // there. Runtime should detect the prior completed step result and return
        // idempotent success instead of an error.
        WorkflowAdvanceRequest req2 = new WorkflowAdvanceRequest(inst.Id, 'submit');

        Test.startTest();
        List<WorkflowRuntime.AdvanceResult> retry = WorkflowRuntime.advance(
            new List<WorkflowAdvanceRequest>{ req2 }
        );
        Test.stopTest();

        System.assertEquals(1, retry.size());
        WorkflowRuntime.AdvanceResult r = retry[0];
        System.assertEquals(true, r.success, 'Retry should succeed: ' + r.error);
        System.assertEquals(true, r.idempotent, 'Retry should be flagged idempotent');
        System.assertEquals('intake', r.fromState);
        System.assertEquals('review', r.toState);

        // Only one step result exists (no duplicate)
        System.assertEquals(1, [
            SELECT COUNT() FROM Workflow_Step_Result__c WHERE Workflow_Instance__c = :inst.Id
        ]);

        // Instance remains at review
        Workflow_Instance__c current = [
            SELECT Current_State__c FROM Workflow_Instance__c WHERE Id = :inst.Id
        ];
        System.assertEquals('review', current.Current_State__c);
    }

    // ─── Terminal state marks instance completed ─────────────────

    @IsTest
    static void terminalStateCompletesInstance() {
        Workflow_Definition__c def = insertDefinition();
        Workflow_Instance__c inst = insertInstance(def.Id, 'review');

        WorkflowAdvanceRequest req = new WorkflowAdvanceRequest(inst.Id, 'approve');

        Test.startTest();
        List<WorkflowRuntime.AdvanceResult> results = WorkflowRuntime.advance(
            new List<WorkflowAdvanceRequest>{ req }
        );
        Test.stopTest();

        System.assertEquals(true, results[0].success, 'terminalState: error=' + results[0].error);
        System.assertEquals('complete', results[0].toState);

        Workflow_Instance__c updated = [
            SELECT Status__c, Completed_Date__c FROM Workflow_Instance__c WHERE Id = :inst.Id
        ];
        System.assertEquals('Completed', updated.Status__c);
        System.assertNotEquals(null, updated.Completed_Date__c);
    }

    // ─── Extension hook fires ────────────────────────────────────

    @IsTest
    static void extensionHookReceivesContext() {
        Workflow_Definition__c def = insertDefinition();
        Workflow_Instance__c inst = insertInstance(def.Id, 'intake');

        StubHook stub = new StubHook();
        WorkflowRuntime.registerHook(stub);

        Test.startTest();
        WorkflowRuntime.advance(
            new List<WorkflowAdvanceRequest>{ new WorkflowAdvanceRequest(inst.Id, 'submit') }
        );
        Test.stopTest();

        System.assertEquals(1, stub.contexts.size());
        System.assertEquals(inst.Id, stub.contexts[0].instanceId);
        System.assertEquals('intake', stub.contexts[0].fromStateKey);
        System.assertEquals('review', stub.contexts[0].toStateKey);

        WorkflowRuntime.clearHooks();
    }

    // ─── Entry / exit condition tests ────────────────────────────

    @IsTest
    static void entryConditionPassAllowsTransition() {
        Account acct = new Account(Name = 'Good Co', Industry = 'Biotechnology');
        insert acct;
        Workflow_Definition__c def = insertDefinitionWithConditions(
            // exit of intake must be "review_ready", entry of review requires Industry == Biotechnology
            '{"logic":"AND","rules":[{"field":"Industry","op":"EQUALS","value":"Biotechnology"}]}',
            null
        );
        Workflow_Instance__c inst = insertInstanceForParent(def.Id, 'intake', acct.Id);

        WorkflowAdvanceRequest req = new WorkflowAdvanceRequest(inst.Id, 'submit');

        Test.startTest();
        List<WorkflowRuntime.AdvanceResult> results = WorkflowRuntime.advance(
            new List<WorkflowAdvanceRequest>{ req }
        );
        Test.stopTest();

        System.assertEquals(true, results[0].success, 'entryPass: error=' + results[0].error);
        System.assertEquals('review', results[0].toState);
    }

    @IsTest
    static void entryConditionFailRejectsTransition() {
        Account acct = new Account(Name = 'Bad Co', Industry = 'Agriculture');
        insert acct;
        Workflow_Definition__c def = insertDefinitionWithConditions(
            '{"logic":"AND","rules":[{"field":"Industry","op":"EQUALS","value":"Biotechnology"}]}',
            null
        );
        Workflow_Instance__c inst = insertInstanceForParent(def.Id, 'intake', acct.Id);

        WorkflowAdvanceRequest req = new WorkflowAdvanceRequest(inst.Id, 'submit');

        Test.startTest();
        List<WorkflowRuntime.AdvanceResult> results = WorkflowRuntime.advance(
            new List<WorkflowAdvanceRequest>{ req }
        );
        Test.stopTest();

        System.assertEquals(false, results[0].success);
        System.assert(results[0].error.contains('Entry condition not met'),
            'expected entry failure, got: ' + results[0].error);
        // Instance stayed put
        Workflow_Instance__c after = [
            SELECT Current_State__c FROM Workflow_Instance__c WHERE Id = :inst.Id
        ];
        System.assertEquals('intake', after.Current_State__c);
    }

    @IsTest
    static void exitConditionFailBlocksTransition() {
        Account acct = new Account(Name = 'Exit Co', Industry = 'Agriculture');
        insert acct;
        // Attach exit condition to intake that requires Industry = 'Biotechnology'
        Workflow_Definition__c def = insertDefinitionWithConditions(
            null,
            '{"logic":"AND","rules":[{"field":"Industry","op":"EQUALS","value":"Biotechnology"}]}'
        );
        Workflow_Instance__c inst = insertInstanceForParent(def.Id, 'intake', acct.Id);

        WorkflowAdvanceRequest req = new WorkflowAdvanceRequest(inst.Id, 'submit');

        Test.startTest();
        List<WorkflowRuntime.AdvanceResult> results = WorkflowRuntime.advance(
            new List<WorkflowAdvanceRequest>{ req }
        );
        Test.stopTest();

        System.assertEquals(false, results[0].success);
        System.assert(results[0].error.contains('Exit condition not met'),
            'expected exit failure, got: ' + results[0].error);
    }

    // ─── Test data helpers ───────────────────────────────────────

    private static Workflow_Definition__c insertDefinition() {
        Workflow_Definition__c def = new Workflow_Definition__c(
            Name = 'Test Workflow',
            Workflow_Key__c = 'test_wf',
            Version__c = 1,
            Status__c = 'Published',
            Definition_JSON__c = buildContractJson()
        );
        insert def;
        return def;
    }

    private static Workflow_Instance__c insertInstance(Id defId, String currentState) {
        Workflow_Instance__c inst = new Workflow_Instance__c(
            Workflow_Definition__c = defId,
            Current_State__c = currentState,
            Status__c = 'Active',
            Pinned_Version__c = 1,
            Started_Date__c = Datetime.now()
        );
        insert inst;
        return inst;
    }

    private static Workflow_Definition__c insertDefinitionWithConditions(
        String reviewEntryJson, String intakeExitJson
    ) {
        String json = buildContractWithConditions(reviewEntryJson, intakeExitJson);
        Workflow_Definition__c def = new Workflow_Definition__c(
            Name = 'Test WF with Conditions',
            Workflow_Key__c = 'test_wf_cond',
            Version__c = 1,
            Status__c = 'Published',
            Definition_JSON__c = json
        );
        insert def;
        return def;
    }

    private static Workflow_Instance__c insertInstanceForParent(
        Id defId, String currentState, Id parentId
    ) {
        Workflow_Instance__c inst = new Workflow_Instance__c(
            Workflow_Definition__c = defId,
            Current_State__c = currentState,
            Status__c = 'Active',
            Pinned_Version__c = 1,
            Parent_Object_Type__c = 'Account',
            Parent_Record_Id__c = parentId,
            Started_Date__c = Datetime.now()
        );
        insert inst;
        return inst;
    }

    private static String buildContractWithConditions(
        String reviewEntryJson, String intakeExitJson
    ) {
        String intakeExit = String.isNotBlank(intakeExitJson)
            ? (',"exitConditions":' + intakeExitJson) : '';
        String reviewEntry = String.isNotBlank(reviewEntryJson)
            ? (',"entryConditions":' + reviewEntryJson) : '';
        return '{"schema":"pulse.workflow.v1","workflowKey":"test_wf_cond","version":1,' +
            '"subjectKinds":["Account"],"states":[' +
            '{"key":"intake","label":"Intake","type":"form","fields":[],"transitions":[' +
                '{"signal":"submit","to":"review"}]' + intakeExit + '},' +
            '{"key":"review","label":"Review","type":"approval","fields":[],"transitions":[' +
                '{"signal":"approve","to":"complete"}]' + reviewEntry + '},' +
            '{"key":"complete","label":"Complete","type":"terminal","fields":[],"transitions":[]}' +
            ']}';
    }

    private static String buildContractJson() {
        return '{"schema":"pulse.workflow.v1","workflowKey":"test_workflow","version":1,' +
            '"subjectKinds":["Account"],"states":[' +
            '{"key":"intake","label":"Intake","type":"form","fields":[' +
            '{"key":"patient_name","label":"Patient Name","type":"Text","required":true}' +
            '],"transitions":[' +
            '{"signal":"submit","to":"review"},' +
            '{"signal":"cancel","to":"cancelled"}' +
            ']},' +
            '{"key":"review","label":"Review","type":"approval","fields":[],"transitions":[' +
            '{"signal":"approve","to":"complete"},' +
            '{"signal":"reject","to":"intake"}' +
            ']},' +
            '{"key":"complete","label":"Complete","type":"terminal","fields":[],"transitions":[]},' +
            '{"key":"cancelled","label":"Cancelled","type":"terminal","fields":[],"transitions":[]}' +
            ']}';
    }

    // ─── Stub hook for extension point test ──────────────────────

    private class StubHook implements WorkflowRuntime.TransitionHook {
        public List<WorkflowRuntime.TransitionContext> contexts =
            new List<WorkflowRuntime.TransitionContext>();

        public void afterTransitions(List<WorkflowRuntime.TransitionContext> ctxs) {
            contexts.addAll(ctxs);
        }
    }
}
