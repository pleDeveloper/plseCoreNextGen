@IsTest
private class PulseRuntimeControllerTest {

    // ─── getInstanceForRecord: happy path ───────────────────────

    @IsTest
    static void getInstanceForRecordReturnsView() {
        Workflow_Definition__c def = insertDefinition();
        Account acc = insertAccount();
        Workflow_Instance__c inst = insertInstance(def.Id, 'intake', acc.Id);
        // Insert a step result so history is populated
        insertStepResult(inst.Id, 'initial', 'start', 'Completed');

        Test.startTest();
        PulseRuntimeController.InstanceView view =
            PulseRuntimeController.getInstanceForRecord(acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, view, 'Should find active instance');
        System.assertEquals(inst.Id, view.instanceId);
        System.assertEquals('test_workflow', view.workflowKey);
        System.assertEquals('intake', view.currentStateKey);
        System.assertEquals('Intake', view.currentStateLabel);
        System.assertEquals('form', view.currentStateType);
        System.assertEquals('Active', view.status);
        System.assertEquals(2, view.availableSignals.size(), 'intake has submit + cancel');
        System.assertEquals('submit', view.availableSignals[0].signal);
        System.assertEquals(1, view.history.size());
        System.assertEquals('initial', view.history[0].stateKey);
    }

    // ─── getInstanceForRecord: Stage_Status__c round-trips ──────

    @IsTest
    static void getInstanceForRecordSurfacesStageStatus() {
        Workflow_Definition__c def = insertDefinition();
        Account acc = insertAccount();
        Workflow_Instance__c inst = insertInstance(def.Id, 'intake', acc.Id);
        inst.Stage_Status__c = 'On_Hold';
        update inst;

        Test.startTest();
        PulseRuntimeController.InstanceView view =
            PulseRuntimeController.getInstanceForRecord(acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, view, 'Should find active instance');
        System.assertEquals('On_Hold', view.stageStatus,
            'stageStatus should surface from Stage_Status__c on the DTO');
    }

    @IsTest
    static void getInstanceForRecordStageStatusNullWhenUnset() {
        Workflow_Definition__c def = insertDefinition();
        Account acc = insertAccount();
        insertInstance(def.Id, 'intake', acc.Id);

        Test.startTest();
        PulseRuntimeController.InstanceView view =
            PulseRuntimeController.getInstanceForRecord(acc.Id);
        Test.stopTest();

        // Picklist default is 'Active' per field-meta; view should reflect
        // whatever Salesforce stored (null when default didn't fire in test
        // context, or 'Active' when it did). Either way the runtime UI
        // treats both as quiet.
        System.assert(
            view.stageStatus == null || view.stageStatus == 'Active',
            'Unset Stage_Status__c should be null or the Active default, got: '
                + view.stageStatus
        );
    }

    // ─── getInstanceForRecord: no instance ──────────────────────

    @IsTest
    static void getInstanceForRecordReturnsNullWhenNone() {
        Account acc = insertAccount();

        Test.startTest();
        PulseRuntimeController.InstanceView view =
            PulseRuntimeController.getInstanceForRecord(acc.Id);
        Test.stopTest();

        System.assertEquals(null, view, 'No instance should return null');
    }

    // ─── getInstanceForRecord: null recordId ────────────────────

    @IsTest
    static void getInstanceForRecordNullId() {
        Test.startTest();
        PulseRuntimeController.InstanceView view =
            PulseRuntimeController.getInstanceForRecord(null);
        Test.stopTest();

        System.assertEquals(null, view);
    }

    // ─── advanceInstance: happy path ────────────────────────────

    @IsTest
    static void advanceInstanceSucceeds() {
        Workflow_Definition__c def = insertDefinition();
        Account acc = insertAccount();
        Workflow_Instance__c inst = insertInstance(def.Id, 'intake', acc.Id);

        Test.startTest();
        PulseRuntimeController.AdvanceView view =
            PulseRuntimeController.advanceInstance(inst.Id, 'submit', '{"key":"val"}', 'idem-1');
        Test.stopTest();

        System.assertEquals(true, view.success, 'advance error: ' + view.error);
        System.assertEquals('intake', view.fromStateKey);
        System.assertEquals('review', view.toStateKey);
        System.assertNotEquals(null, view.refreshed, 'Should include refreshed view');
        System.assertEquals('review', view.refreshed.currentStateKey);
    }

    // ─── advanceInstance: bad signal ────────────────────────────

    @IsTest
    static void advanceInstanceBadSignal() {
        Workflow_Definition__c def = insertDefinition();
        Account acc = insertAccount();
        Workflow_Instance__c inst = insertInstance(def.Id, 'intake', acc.Id);

        Test.startTest();
        PulseRuntimeController.AdvanceView view =
            PulseRuntimeController.advanceInstance(inst.Id, 'nonexistent', null, null);
        Test.stopTest();

        System.assertEquals(false, view.success);
        System.assert(view.error.contains('not valid'), view.error);
    }

    // ─── advanceInstance: missing params ────────────────────────

    @IsTest
    static void advanceInstanceMissingParams() {
        Test.startTest();
        PulseRuntimeController.AdvanceView view =
            PulseRuntimeController.advanceInstance(null, '', null, null);
        Test.stopTest();

        System.assertEquals(false, view.success);
        System.assert(view.error.contains('required'), view.error);
    }

    // ─── getPendingActions: returns actions ──────────────────────

    @IsTest
    static void getPendingActionsReturnsList() {
        Workflow_Definition__c def = insertDefinition();
        Account acc = insertAccount();
        Workflow_Instance__c inst = insertInstance(def.Id, 'intake', acc.Id);
        insertAction(inst.Id, 'send_email', 'Pending');
        insertAction(inst.Id, 'update_record', 'Pending');
        insertAction(inst.Id, 'send_sms', 'Executed'); // should not appear

        Test.startTest();
        List<PulseRuntimeController.ActionView> actions =
            PulseRuntimeController.getPendingActions(inst.Id);
        Test.stopTest();

        System.assertEquals(2, actions.size(), 'Only pending actions returned');
        System.assertEquals('send_email', actions[0].toolKey);
        System.assertEquals('update_record', actions[1].toolKey);
    }

    // ─── getPendingActions: empty ───────────────────────────────

    @IsTest
    static void getPendingActionsEmptyForNullId() {
        Test.startTest();
        List<PulseRuntimeController.ActionView> actions =
            PulseRuntimeController.getPendingActions(null);
        Test.stopTest();

        System.assertEquals(0, actions.size());
    }

    // ─── resolveAction: reject ──────────────────────────────────

    @IsTest
    static void resolveActionReject() {
        Workflow_Definition__c def = insertDefinition();
        Account acc = insertAccount();
        Workflow_Instance__c inst = insertInstance(def.Id, 'intake', acc.Id);
        Workflow_Action__c action = insertAction(inst.Id, 'send_email', 'Pending');

        Test.startTest();
        PulseRuntimeController.ActionResolveResult result =
            PulseRuntimeController.resolveAction(action.Id, 'Reject', 'Not needed', null);
        Test.stopTest();

        System.assertEquals(true, result.success, result.message);
        System.assertEquals('Rejected', result.resultStatus);

        Workflow_Action__c reloaded = [
            SELECT Status__c FROM Workflow_Action__c WHERE Id = :action.Id
        ];
        System.assertEquals('Rejected', reloaded.Status__c);
    }

    // ─── resolveAction: already resolved ────────────────────────

    @IsTest
    static void resolveActionAlreadyResolved() {
        Workflow_Definition__c def = insertDefinition();
        Account acc = insertAccount();
        Workflow_Instance__c inst = insertInstance(def.Id, 'intake', acc.Id);
        Workflow_Action__c action = insertAction(inst.Id, 'send_email', 'Executed');

        Test.startTest();
        PulseRuntimeController.ActionResolveResult result =
            PulseRuntimeController.resolveAction(action.Id, 'Approve', null, null);
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assert(result.message.contains('not Pending'), result.message);
    }

    // ─── resolveAction: bad decision ────────────────────────────

    @IsTest
    static void resolveActionBadDecision() {
        Workflow_Definition__c def = insertDefinition();
        Account acc = insertAccount();
        Workflow_Instance__c inst = insertInstance(def.Id, 'intake', acc.Id);
        Workflow_Action__c action = insertAction(inst.Id, 'send_email', 'Pending');

        Test.startTest();
        PulseRuntimeController.ActionResolveResult result =
            PulseRuntimeController.resolveAction(action.Id, 'Maybe', null, null);
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assert(result.message.contains('Approve or Reject'), result.message);
    }

    // ─── resolveAction: missing params ──────────────────────────

    @IsTest
    static void resolveActionMissingParams() {
        Test.startTest();
        PulseRuntimeController.ActionResolveResult result =
            PulseRuntimeController.resolveAction(null, null, null, null);
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assert(result.message.contains('required'), result.message);
    }

    // ─── resolveAction: refine payload ──────────────────────────

    @IsTest
    static void resolveActionRefinePayload() {
        PulseToolRegistry.clearForTest();
        PulseToolRegistry.registerToolForTest('stub_refine_tool', new StubRefineTool());

        Workflow_Definition__c def = insertDefinition();
        Account acc = insertAccount();
        Workflow_Instance__c inst = insertInstance(def.Id, 'intake', acc.Id);
        Workflow_Action__c action = new Workflow_Action__c(
            Workflow_Instance__c = inst.Id,
            Tool_Key__c          = 'stub_refine_tool',
            Action_Type__c       = 'AI_Tool_Call',
            HITL_Policy__c       = 'Approval_Required',
            Request_JSON__c      = '{"body":"original draft"}',
            Status__c            = 'Pending'
        );
        insert action;

        String refined = '{"body":"edited by approver"}';

        Test.startTest();
        PulseRuntimeController.ActionResolveResult result =
            PulseRuntimeController.resolveAction(action.Id, 'Approve', null, refined);
        Test.stopTest();

        System.assertEquals(true, result.success, result.message);
        Workflow_Action__c reloaded = [
            SELECT Status__c, Request_JSON__c FROM Workflow_Action__c WHERE Id = :action.Id
        ];
        System.assertEquals('Executed', reloaded.Status__c);
        System.assertEquals(refined, reloaded.Request_JSON__c,
            'Refined payload should have replaced the original draft');

        // Audit event fired
        List<Workflow_Event__c> refinedEvents = [
            SELECT Event_Type__c FROM Workflow_Event__c
            WHERE Workflow_Instance__c = :inst.Id AND Event_Type__c = 'TOOL_REFINED'
        ];
        System.assertEquals(1, refinedEvents.size(), 'TOOL_REFINED event should have fired');
    }

    // ─── saveFieldValues: round-trip into Context_JSON__c ───────

    @IsTest
    static void saveFieldValuesMergesContext() {
        Workflow_Definition__c def = insertDefinition();
        Account acc = insertAccount();
        Workflow_Instance__c inst = insertInstance(def.Id, 'intake', acc.Id);

        Map<String, Object> values = new Map<String, Object>{
            'patient_name' => 'Alice',
            'note'         => 'seed'
        };

        Test.startTest();
        PulseRuntimeController.InstanceView view =
            PulseRuntimeController.saveFieldValues(inst.Id, values);
        Test.stopTest();

        System.assertNotEquals(null, view, 'Should return refreshed view');
        Workflow_Instance__c reloaded = [
            SELECT Context_JSON__c FROM Workflow_Instance__c WHERE Id = :inst.Id
        ];
        Map<String, Object> ctx =
            (Map<String, Object>) JSON.deserializeUntyped(reloaded.Context_JSON__c);
        System.assertEquals('Alice', ctx.get('patient_name'));
        System.assertEquals('seed',  ctx.get('note'));

        // Second call merges, doesn't clobber
        PulseRuntimeController.saveFieldValues(inst.Id,
            new Map<String, Object>{ 'patient_name' => 'Bob' });
        reloaded = [SELECT Context_JSON__c FROM Workflow_Instance__c WHERE Id = :inst.Id];
        ctx = (Map<String, Object>) JSON.deserializeUntyped(reloaded.Context_JSON__c);
        System.assertEquals('Bob', ctx.get('patient_name'), 'Should overwrite existing key');
        System.assertEquals('seed', ctx.get('note'), 'Should preserve unrelated key');
    }

    // ─── phaseFields: view populated from context (no projection) ──

    @IsTest
    static void getInstancePhaseFieldsFromContext() {
        Workflow_Definition__c def = insertDefinition();
        Account acc = insertAccount();
        Workflow_Instance__c inst = insertInstance(def.Id, 'intake', acc.Id);
        inst.Context_JSON__c = JSON.serialize(
            new Map<String, Object>{ 'patient_name' => 'Charlie' }
        );
        update inst;

        Test.startTest();
        PulseRuntimeController.InstanceView view =
            PulseRuntimeController.getInstanceForRecord(acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, view.phaseFields, 'phaseFields should be populated');
        System.assertEquals(1, view.phaseFields.size(), 'intake phase has 1 field');
        PulseRuntimeController.PhaseFieldView f = view.phaseFields[0];
        System.assertEquals('patient_name', f.key);
        System.assertEquals('Patient Name', f.label);
        System.assertEquals('Text', f.fieldType);
        System.assertEquals(true, f.required);
        System.assertEquals('Charlie', f.currentValue,
            'Current value should read from Context_JSON__c');
        System.assertEquals(null, f.projectedFieldApiName,
            'No projection on intake fields in this fixture');
    }

    // ─── saveFieldValues: null / empty guards ───────────────────

    @IsTest
    static void saveFieldValuesNullGuards() {
        Test.startTest();
        System.assertEquals(null,
            PulseRuntimeController.saveFieldValues(null, new Map<String, Object>{ 'a' => 1 }));
        Test.stopTest();
    }

    // ─── allPhases: every state present, status per state ───────

    @IsTest
    static void allPhasesReturnsEveryStateWithStatus() {
        Workflow_Definition__c def = insertDefinition();
        Account acc = insertAccount();
        Workflow_Instance__c inst = insertInstance(def.Id, 'review', acc.Id);
        // History: intake completed → now on review (current). complete + cancelled upcoming.
        insertStepResult(inst.Id, 'intake', 'submit', 'Completed');

        Test.startTest();
        PulseRuntimeController.InstanceView view =
            PulseRuntimeController.getInstanceForRecord(acc.Id);
        Test.stopTest();

        System.assertNotEquals(null, view.allPhases, 'allPhases populated');
        System.assertEquals(4, view.allPhases.size(), 'Four states in fixture');

        // Order preserved from contract
        System.assertEquals('intake',    view.allPhases[0].key);
        System.assertEquals('review',    view.allPhases[1].key);
        System.assertEquals('complete',  view.allPhases[2].key);
        System.assertEquals('cancelled', view.allPhases[3].key);

        // 1-based sequence
        System.assertEquals(1, view.allPhases[0].sequence);
        System.assertEquals(4, view.allPhases[3].sequence);

        // Status derivation
        System.assertEquals('completed', view.allPhases[0].status,
            'intake has a Completed step-result');
        System.assertEquals('current',   view.allPhases[1].status,
            'review is the active phase');
        System.assertEquals('upcoming',  view.allPhases[2].status);
        System.assertEquals('upcoming',  view.allPhases[3].status);
    }

    // ─── allPhases: checkpoints + activeCheckpoint derivation ───

    @IsTest
    static void allPhasesCheckpointsAndActiveCheckpoint() {
        Workflow_Definition__c def = insertDefinition();
        Account acc = insertAccount();
        Workflow_Instance__c inst = insertInstance(def.Id, 'intake', acc.Id);
        // No context values → active checkpoint should be the first field
        Test.startTest();
        PulseRuntimeController.InstanceView view =
            PulseRuntimeController.getInstanceForRecord(acc.Id);
        Test.stopTest();

        PulseRuntimeController.PhaseOverviewView intake = view.allPhases[0];
        System.assertEquals('intake', intake.key);
        System.assertEquals('current', intake.status);
        // Checkpoints = one per field + 'Complete'
        System.assertEquals(2, intake.checkpoints.size());
        System.assertEquals('Capture Patient Name', intake.checkpoints[0]);
        System.assertEquals('Complete', intake.checkpoints[1]);
        // Empty context → first field is the live checkpoint
        System.assertEquals('Capture Patient Name', intake.activeCheckpoint);

        // Review/complete/cancelled have no fields — checkpoints = just ['Complete']
        PulseRuntimeController.PhaseOverviewView review = view.allPhases[1];
        System.assertEquals(1, review.checkpoints.size());
        System.assertEquals('Complete', review.checkpoints[0]);
        // activeCheckpoint is null for non-current phases
        System.assertEquals(null, review.activeCheckpoint);
    }

    @IsTest
    static void allPhasesActiveCheckpointAdvancesAsFieldsFill() {
        Workflow_Definition__c def = insertDefinition();
        Account acc = insertAccount();
        Workflow_Instance__c inst = insertInstance(def.Id, 'intake', acc.Id);
        inst.Context_JSON__c = JSON.serialize(
            new Map<String, Object>{ 'patient_name' => 'Alice' }
        );
        update inst;

        Test.startTest();
        PulseRuntimeController.InstanceView view =
            PulseRuntimeController.getInstanceForRecord(acc.Id);
        Test.stopTest();

        PulseRuntimeController.PhaseOverviewView intake = view.allPhases[0];
        // Only one field, now filled → active should be 'Complete'
        System.assertEquals('Complete', intake.activeCheckpoint);
    }

    // ─── allPhases: completedAt pulled from last Completed step-result ──

    @IsTest
    static void allPhasesCompletedAtFromStepResult() {
        Workflow_Definition__c def = insertDefinition();
        Account acc = insertAccount();
        Workflow_Instance__c inst = insertInstance(def.Id, 'review', acc.Id);
        Workflow_Step_Result__c sr = insertStepResult(inst.Id, 'intake', 'submit', 'Completed');
        // Make completed_at deterministic
        Datetime stamp = Datetime.newInstance(2026, 1, 15, 10, 0, 0);
        sr.Completed_Date__c = stamp;
        update sr;

        Test.startTest();
        PulseRuntimeController.InstanceView view =
            PulseRuntimeController.getInstanceForRecord(acc.Id);
        Test.stopTest();

        PulseRuntimeController.PhaseOverviewView intake = view.allPhases[0];
        System.assertEquals('completed', intake.status);
        System.assertEquals(stamp, intake.completedAt,
            'completedAt should match latest Completed step-result timestamp');

        // Current/upcoming phases should not have completedAt
        System.assertEquals(null, view.allPhases[1].completedAt);
        System.assertEquals(null, view.allPhases[2].completedAt);
    }

    // ─── allPhases: terminal status when instance finishes ──────
    // Drives advance through the runtime so the instance reaches the
    // terminal 'complete' state and its Status__c flips to 'Completed'.
    // The refreshed view on the AdvanceResult is what the LWC actually
    // consumes after an advance, so it's the right surface to assert on.

    @IsTest
    static void allPhasesTerminalSuccessStatus() {
        Workflow_Definition__c def = insertDefinition();
        Account acc = insertAccount();
        Workflow_Instance__c inst = insertInstance(def.Id, 'intake', acc.Id);

        Test.startTest();
        // intake → review
        PulseRuntimeController.AdvanceView step1 =
            PulseRuntimeController.advanceInstance(inst.Id, 'submit', null, null);
        System.assertEquals(true, step1.success,
            'step1: ' + (step1.error == null ? '(no error)' : step1.error));
        // review → complete (terminal)
        PulseRuntimeController.AdvanceView view =
            PulseRuntimeController.advanceInstance(inst.Id, 'approve', null, null);
        Test.stopTest();

        System.assertEquals(true, view.success,
            'step2: ' + (view.error == null ? '(no error)' : view.error));
        System.assertNotEquals(null, view.refreshed);
        System.assertNotEquals(null, view.refreshed.allPhases);

        // Find the 'complete' phase in the journey
        PulseRuntimeController.PhaseOverviewView completePhase = null;
        for (PulseRuntimeController.PhaseOverviewView p : view.refreshed.allPhases) {
            if (p.key == 'complete') { completePhase = p; break; }
        }
        System.assertNotEquals(null, completePhase, 'complete phase present');
        System.assertEquals('terminal_success', completePhase.status,
            'Terminal + instance Completed → terminal_success');
    }

    // ─── Test data helpers ──────────────────────────────────────

    private static Account insertAccount() {
        Account acc = new Account(Name = 'Test Account');
        insert acc;
        return acc;
    }

    private static Workflow_Definition__c insertDefinition() {
        Workflow_Definition__c def = new Workflow_Definition__c(
            Name = 'Test Workflow',
            Workflow_Key__c = 'test_wf',
            Version__c = 1,
            Status__c = 'Published',
            Subject_Kinds__c = 'Account',
            Definition_JSON__c = buildContractJson()
        );
        insert def;
        return def;
    }

    private static Workflow_Instance__c insertInstance(Id defId, String currentState, Id parentRecordId) {
        Workflow_Instance__c inst = new Workflow_Instance__c(
            Workflow_Definition__c = defId,
            Current_State__c = currentState,
            Status__c = 'Active',
            Pinned_Version__c = 1,
            Started_Date__c = Datetime.now(),
            Parent_Record_Id__c = parentRecordId,
            Parent_Object_Type__c = 'Account'
        );
        insert inst;
        return inst;
    }

    private static Workflow_Step_Result__c insertStepResult(
        Id instanceId, String stateKey, String signal, String outcome
    ) {
        Workflow_Step_Result__c sr = new Workflow_Step_Result__c(
            Workflow_Instance__c = instanceId,
            State_Key__c = stateKey,
            Signal__c = signal,
            Outcome__c = outcome,
            Actor_Type__c = 'Human',
            Started_Date__c = Datetime.now(),
            Completed_Date__c = Datetime.now()
        );
        insert sr;
        return sr;
    }

    private static Workflow_Action__c insertAction(Id instanceId, String toolKey, String status) {
        Workflow_Action__c action = new Workflow_Action__c(
            Workflow_Instance__c = instanceId,
            Tool_Key__c = toolKey,
            Action_Type__c = 'AI_Tool_Call',
            HITL_Policy__c = 'Approval_Required',
            Request_JSON__c = '{"toAddress":"test@test.com"}',
            Status__c = status
        );
        insert action;
        return action;
    }

    // Stub tool used by resolveActionRefinePayload — succeeds and echoes input.
    private class StubRefineTool implements PulseTool {
        public String getToolKey() { return 'stub_refine_tool'; }
        public String getDescription() { return 'Stub refine tool'; }
        public Map<String, Object> getInputSchema() {
            return new Map<String, Object>{ 'type' => 'object' };
        }
        public String getDefaultHitlPolicy() { return 'Approval_Required'; }
        public PulseToolModels.Result execute(PulseToolModels.Context ctx) {
            return PulseToolModels.ok(JSON.serialize(ctx.input));
        }
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
}
