@IsTest
private class PulseActionInstantiationServiceTest {

    private static final String PHASE_CONTRACT =
        '{"schema":"pulse.workflow.v1","workflowKey":"phase_test","version":1,' +
        '"subjectKinds":["Opportunity"],"states":[' +
          '{"key":"phase_a","label":"Phase A","type":"form",' +
            '"advancement":"auto",' +
            '"actions":[' +
              '{"key":"first_task","label":"First Task","type":"approval","required":true,"dependsOn":[]},' +
              '{"key":"second_task","label":"Second Task","type":"approval","required":true,"dependsOn":["first_task"]},' +
              '{"key":"optional_task","label":"Optional","type":"approval","required":false,"dependsOn":[]}' +
            '],' +
            '"transitions":[{"signal":"done","to":"phase_b"}]},' +
          '{"key":"phase_b","label":"Phase B","type":"terminal","transitions":[]}' +
        ']}';

    @TestSetup
    static void setup() {
        Workflow_Definition__c def = new Workflow_Definition__c(
            Name = 'phase_test',
            Workflow_Key__c = 'phase_test',
            Version__c = 1,
            Status__c = 'Published',
            Definition_JSON__c = PHASE_CONTRACT,
            Subject_Kinds__c = 'Opportunity'
        );
        insert def;

        Workflow_Instance__c inst = new Workflow_Instance__c(
            Workflow_Definition__c = def.Id,
            Current_State__c = 'phase_a',
            Status__c = 'Active',
            Parent_Object_Type__c = 'Opportunity'
        );
        insert inst;
    }

    private static Id getInstId() {
        return [SELECT Id FROM Workflow_Instance__c LIMIT 1].Id;
    }

    @IsTest
    static void instantiatesIndependentActionsOnPhaseEntry() {
        // The Workflow_Instance__c trigger already instantiates on insert.
        // Re-running is idempotent.
        List<Workflow_Action__c> before = [
            SELECT Id, Action_Key__c FROM Workflow_Action__c
            WHERE Workflow_Instance__c = :getInstId()
        ];
        // first_task (no deps) + optional_task (no deps) should have been
        // created. second_task (depends on first_task) should NOT yet exist.
        Set<String> keys = new Set<String>();
        for (Workflow_Action__c a : before) keys.add(a.Action_Key__c);
        System.assert(keys.contains('first_task'), 'first_task should be instantiated');
        System.assert(keys.contains('optional_task'), 'optional_task should be instantiated');
        System.assert(!keys.contains('second_task'), 'second_task should be blocked');

        // Second call should be a no-op (idempotent).
        List<Workflow_Action__c> second = PulseActionInstantiationService.instantiateForPhase(getInstId());
        System.assertEquals(0, second.size(), 'Idempotent re-run should create no new rows');
    }

    @IsTest
    static void promotesDependentWhenParentCompletes() {
        Id instId = getInstId();
        Workflow_Action__c first = [
            SELECT Id, Status__c FROM Workflow_Action__c
            WHERE Workflow_Instance__c = :instId AND Action_Key__c = 'first_task'
        ];
        first.Status__c = 'Executed';
        update first;

        Test.startTest();
        List<Workflow_Action__c> promoted = PulseActionInstantiationService.promoteDependents(first.Id);
        Test.stopTest();

        // Second task should now be instantiated.
        List<Workflow_Action__c> all = [
            SELECT Action_Key__c, Status__c FROM Workflow_Action__c
            WHERE Workflow_Instance__c = :instId
        ];
        Set<String> keys = new Set<String>();
        for (Workflow_Action__c a : all) keys.add(a.Action_Key__c);
        System.assert(keys.contains('second_task'), 'second_task should be promoted once first_task Executed');
    }

    @IsTest
    static void phaseCompleteIgnoresOptionalActions() {
        Id instId = getInstId();

        // Mark ONLY required actions as Executed (optional stays Pending).
        List<Workflow_Action__c> toUpdate = new List<Workflow_Action__c>();
        for (Workflow_Action__c a : [
            SELECT Id, Action_Key__c, Status__c FROM Workflow_Action__c
            WHERE Workflow_Instance__c = :instId
        ]) {
            if (a.Action_Key__c == 'first_task') {
                a.Status__c = 'Executed';
                toUpdate.add(a);
            }
        }
        update toUpdate;
        // Now promote to materialise second_task.
        PulseActionInstantiationService.promoteDependents(toUpdate[0].Id);
        Workflow_Action__c second = [
            SELECT Id FROM Workflow_Action__c
            WHERE Workflow_Instance__c = :instId AND Action_Key__c = 'second_task'
        ];
        second.Status__c = 'Executed';
        update second;

        Test.startTest();
        Boolean done = PulseActionInstantiationService.phaseComplete(instId);
        Test.stopTest();

        System.assertEquals(true, done, 'Phase should be complete once required actions are Executed');
    }

    @IsTest
    static void phaseNotCompleteWhenRequiredStillPending() {
        Id instId = getInstId();
        Boolean done = PulseActionInstantiationService.phaseComplete(instId);
        System.assertEquals(false, done, 'Phase should not be complete initially');
    }

    @IsTest
    static void phaseWithoutActionsReportsComplete() {
        // Phase with no declarative actions is treated as "complete" so
        // legacy workflows still advance through manual signals.
        String legacyContract =
            '{"schema":"pulse.workflow.v1","workflowKey":"legacy","version":1,' +
            '"subjectKinds":["Account"],"states":[' +
              '{"key":"only","label":"Only","type":"form","transitions":[]}' +
            ']}';
        Workflow_Definition__c def = new Workflow_Definition__c(
            Name = 'legacy', Workflow_Key__c = 'legacy', Version__c = 1,
            Status__c = 'Published', Definition_JSON__c = legacyContract,
            Subject_Kinds__c = 'Account'
        );
        insert def;
        Workflow_Instance__c inst = new Workflow_Instance__c(
            Workflow_Definition__c = def.Id,
            Current_State__c = 'only', Status__c = 'Active',
            Parent_Object_Type__c = 'Account'
        );
        insert inst;

        System.assertEquals(true, PulseActionInstantiationService.phaseComplete(inst.Id));
    }

    @IsTest
    static void instantiateForUnknownInstanceReturnsEmpty() {
        List<Workflow_Action__c> out =
            PulseActionInstantiationService.instantiateForPhase(null);
        System.assertEquals(0, out.size());
    }

    @IsTest
    static void promoteDependentsWithNullReturnsEmpty() {
        List<Workflow_Action__c> out =
            PulseActionInstantiationService.promoteDependents(null);
        System.assertEquals(0, out.size());
    }
}
