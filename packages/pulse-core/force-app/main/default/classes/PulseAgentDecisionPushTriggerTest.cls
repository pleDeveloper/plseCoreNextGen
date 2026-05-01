/**
 * Tests for PulseAgentDecisionPushTrigger.
 *
 * Asserts:
 *   - Pending_User / Auto_Executed / Answered inserts publish one event per
 *     parent instance.
 *   - Observe / Skipped inserts (the agent scan-loop case) publish nothing.
 *   - Updates that move a row OUT of Pending_User publish one event per
 *     parent instance.
 *   - Updates that don't leave Pending_User (or never started Pending_User)
 *     publish nothing.
 *
 * Counts are read from PulseWorkflowEventPublisher's @TestVisible counter.
 */
@IsTest
private class PulseAgentDecisionPushTriggerTest {

    @TestSetup
    static void setup() {
        Workflow_Definition__c def = new Workflow_Definition__c(
            Workflow_Key__c = 'decision_push_wf',
            Version__c = 1,
            Status__c = 'Published',
            Definition_JSON__c = '{"schema":"pulse.workflow.v1"}',
            Subject_Kinds__c = 'Account'
        );
        insert def;

        Workflow_Instance__c inst = new Workflow_Instance__c(
            Workflow_Definition__c = def.Id,
            Current_State__c = 'step_one',
            Status__c = 'Active',
            Parent_Object_Type__c = 'Account'
        );
        insert inst;

        Agent_Thread__c thread = new Agent_Thread__c(
            Workflow_Instance__c = inst.Id,
            Status__c = 'Idle',
            Autonomy_Level__c = 'Act_With_Approval'
        );
        insert thread;
    }

    private static Workflow_Instance__c getInstance() {
        return [SELECT Id FROM Workflow_Instance__c LIMIT 1];
    }

    private static Agent_Thread__c getThread() {
        return [SELECT Id FROM Agent_Thread__c LIMIT 1];
    }

    private static Agent_Decision__c makeDecision(Id instanceId, String decisionType, String status) {
        return new Agent_Decision__c(
            Agent_Thread__c = getThread().Id,
            Workflow_Instance__c = instanceId,
            Phase_Key__c = 'step_one',
            Decision_Type__c = decisionType,
            Status__c = status,
            Rationale__c = 'test'
        );
    }

    @IsTest
    static void insertPendingUser_publishesEvent() {
        Workflow_Instance__c inst = getInstance();

        PulseWorkflowEventPublisher.publishedCount = 0;
        PulseWorkflowEventPublisher.publishedInstanceIds = new List<String>();

        Test.startTest();
        insert makeDecision(inst.Id, 'Propose_Action', 'Pending_User');
        Test.stopTest();

        System.assertEquals(1, PulseWorkflowEventPublisher.publishedCount,
            'Pending_User insert should publish one event');
    }

    @IsTest
    static void insertAutoExecuted_publishesEvent() {
        Workflow_Instance__c inst = getInstance();

        PulseWorkflowEventPublisher.publishedCount = 0;
        PulseWorkflowEventPublisher.publishedInstanceIds = new List<String>();

        Test.startTest();
        insert makeDecision(inst.Id, 'Propose_Action', 'Auto_Executed');
        Test.stopTest();

        System.assertEquals(1, PulseWorkflowEventPublisher.publishedCount,
            'Auto_Executed insert should publish one event');
    }

    @IsTest
    static void insertAnswered_publishesEvent() {
        Workflow_Instance__c inst = getInstance();

        PulseWorkflowEventPublisher.publishedCount = 0;
        PulseWorkflowEventPublisher.publishedInstanceIds = new List<String>();

        Test.startTest();
        insert makeDecision(inst.Id, 'Ask_User', 'Answered');
        Test.stopTest();

        System.assertEquals(1, PulseWorkflowEventPublisher.publishedCount,
            'Answered insert should publish one event');
    }

    @IsTest
    static void insertObserve_publishesNothing() {
        // Observe / Skipped is the agent scan-loop case. The whole point of
        // the trigger filter is that those must not drive UI refreshes.
        Workflow_Instance__c inst = getInstance();

        PulseWorkflowEventPublisher.publishedCount = 0;
        PulseWorkflowEventPublisher.publishedInstanceIds = new List<String>();

        Test.startTest();
        insert makeDecision(inst.Id, 'Observe', 'Skipped');
        Test.stopTest();

        System.assertEquals(0, PulseWorkflowEventPublisher.publishedCount,
            'Observe / Skipped insert must not publish');
    }

    @IsTest
    static void updatePendingUserToApproved_publishesEvent() {
        Workflow_Instance__c inst = getInstance();
        Agent_Decision__c d = makeDecision(inst.Id, 'Propose_Action', 'Pending_User');
        insert d;

        PulseWorkflowEventPublisher.publishedCount = 0;
        PulseWorkflowEventPublisher.publishedInstanceIds = new List<String>();

        Test.startTest();
        d.Status__c = 'Approved';
        update d;
        Test.stopTest();

        System.assertEquals(1, PulseWorkflowEventPublisher.publishedCount,
            'Transition out of Pending_User should publish one event');
    }

    @IsTest
    static void updateNonPendingTransition_publishesNothing() {
        Workflow_Instance__c inst = getInstance();
        // Start in Auto_Executed; updates from there are not user-visible.
        Agent_Decision__c d = makeDecision(inst.Id, 'Propose_Action', 'Auto_Executed');
        insert d;

        PulseWorkflowEventPublisher.publishedCount = 0;
        PulseWorkflowEventPublisher.publishedInstanceIds = new List<String>();

        Test.startTest();
        d.Status__c = 'Skipped';
        update d;
        Test.stopTest();

        System.assertEquals(0, PulseWorkflowEventPublisher.publishedCount,
            'Update that does not leave Pending_User must not publish');
    }

    @IsTest
    static void updateNoStatusChange_publishesNothing() {
        Workflow_Instance__c inst = getInstance();
        Agent_Decision__c d = makeDecision(inst.Id, 'Propose_Action', 'Pending_User');
        insert d;

        PulseWorkflowEventPublisher.publishedCount = 0;
        PulseWorkflowEventPublisher.publishedInstanceIds = new List<String>();

        Test.startTest();
        d.Rationale__c = 'updated rationale only';
        update d;
        Test.stopTest();

        System.assertEquals(0, PulseWorkflowEventPublisher.publishedCount,
            'Update without status change must not publish');
    }
}
