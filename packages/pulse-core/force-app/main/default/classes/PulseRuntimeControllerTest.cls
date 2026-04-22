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
            PulseRuntimeController.resolveAction(action.Id, 'Reject', 'Not needed');
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
            PulseRuntimeController.resolveAction(action.Id, 'Approve', null);
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
            PulseRuntimeController.resolveAction(action.Id, 'Maybe', null);
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assert(result.message.contains('Approve or Reject'), result.message);
    }

    // ─── resolveAction: missing params ──────────────────────────

    @IsTest
    static void resolveActionMissingParams() {
        Test.startTest();
        PulseRuntimeController.ActionResolveResult result =
            PulseRuntimeController.resolveAction(null, null, null);
        Test.stopTest();

        System.assertEquals(false, result.success);
        System.assert(result.message.contains('required'), result.message);
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
