/**
 * Tests for PulseWorkflowActionPushTrigger.
 *
 * Asserts:
 *   - Pending inserts publish one event per parent instance.
 *   - Status__c transitions on update publish one event per parent instance.
 *   - Non-Pending inserts (Skipped / Executed / Failed) publish nothing.
 *   - Updates that don't change Status__c publish nothing.
 *
 * Counts are read from PulseWorkflowEventPublisher's @TestVisible counter.
 */
@IsTest
private class PulseWorkflowActionPushTriggerTest {

    @TestSetup
    static void setup() {
        Workflow_Definition__c def = new Workflow_Definition__c(
            Workflow_Key__c = 'action_push_wf',
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
    }

    private static Workflow_Instance__c getInstance() {
        return [SELECT Id FROM Workflow_Instance__c LIMIT 1];
    }

    @IsTest
    static void insertPendingAction_publishesEvent() {
        Workflow_Instance__c inst = getInstance();

        PulseWorkflowEventPublisher.publishedCount = 0;
        PulseWorkflowEventPublisher.publishedInstanceIds = new List<String>();

        Test.startTest();
        Workflow_Action__c a = new Workflow_Action__c(
            Workflow_Instance__c = inst.Id,
            Tool_Key__c = 'send_email',
            Action_Type__c = 'AI_Tool_Call',
            HITL_Policy__c = 'Approval_Required',
            Request_JSON__c = '{}',
            Status__c = 'Pending'
        );
        insert a;
        Test.stopTest();

        System.assertEquals(1, PulseWorkflowEventPublisher.publishedCount,
            'Pending insert should publish one event');
        System.assertEquals(String.valueOf(inst.Id),
            PulseWorkflowEventPublisher.publishedInstanceIds[0]);
    }

    @IsTest
    static void insertNonPendingAction_publishesNothing() {
        Workflow_Instance__c inst = getInstance();

        PulseWorkflowEventPublisher.publishedCount = 0;
        PulseWorkflowEventPublisher.publishedInstanceIds = new List<String>();

        Test.startTest();
        // Pre-resolved Skipped / Executed inserts must not push to UI.
        Workflow_Action__c a = new Workflow_Action__c(
            Workflow_Instance__c = inst.Id,
            Tool_Key__c = 'send_email',
            Action_Type__c = 'AI_Tool_Call',
            HITL_Policy__c = 'Approval_Required',
            Request_JSON__c = '{}',
            Status__c = 'Cancelled'
        );
        insert a;
        Test.stopTest();

        System.assertEquals(0, PulseWorkflowEventPublisher.publishedCount,
            'Non-Pending insert must not publish');
    }

    @IsTest
    static void updateStatus_publishesEvent() {
        Workflow_Instance__c inst = getInstance();
        Workflow_Action__c a = new Workflow_Action__c(
            Workflow_Instance__c = inst.Id,
            Tool_Key__c = 'send_email',
            Action_Type__c = 'AI_Tool_Call',
            HITL_Policy__c = 'Approval_Required',
            Request_JSON__c = '{}',
            Status__c = 'Pending'
        );
        insert a;

        PulseWorkflowEventPublisher.publishedCount = 0;
        PulseWorkflowEventPublisher.publishedInstanceIds = new List<String>();

        Test.startTest();
        a.Status__c = 'Approved';
        update a;
        Test.stopTest();

        System.assertEquals(1, PulseWorkflowEventPublisher.publishedCount,
            'Status__c transition should publish one event');
    }

    @IsTest
    static void updateUnrelatedField_publishesNothing() {
        Workflow_Instance__c inst = getInstance();
        Workflow_Action__c a = new Workflow_Action__c(
            Workflow_Instance__c = inst.Id,
            Tool_Key__c = 'send_email',
            Action_Type__c = 'AI_Tool_Call',
            HITL_Policy__c = 'Approval_Required',
            Request_JSON__c = '{}',
            Status__c = 'Pending'
        );
        insert a;

        PulseWorkflowEventPublisher.publishedCount = 0;
        PulseWorkflowEventPublisher.publishedInstanceIds = new List<String>();

        Test.startTest();
        // Updating Request_JSON__c without changing Status__c is the agent
        // refine-loop case the filter exists to suppress.
        a.Request_JSON__c = '{"toAddress":"test@example.com"}';
        update a;
        Test.stopTest();

        System.assertEquals(0, PulseWorkflowEventPublisher.publishedCount,
            'Updates that do not change Status__c must not publish');
    }

    @IsTest
    static void rowsPendingInsert_dedupesPerInstance() {
        // Multiple Pending actions on the SAME instance should publish only
        // one event for that instance (Set<Id> dedupe).
        Workflow_Instance__c inst = getInstance();

        PulseWorkflowEventPublisher.publishedCount = 0;
        PulseWorkflowEventPublisher.publishedInstanceIds = new List<String>();

        List<Workflow_Action__c> rows = new List<Workflow_Action__c>();
        for (Integer i = 0; i < 5; i++) {
            rows.add(new Workflow_Action__c(
                Workflow_Instance__c = inst.Id,
                Tool_Key__c = 'send_email',
                Action_Type__c = 'AI_Tool_Call',
                HITL_Policy__c = 'Approval_Required',
                Request_JSON__c = '{}',
                Status__c = 'Pending'
            ));
        }

        Test.startTest();
        insert rows;
        Test.stopTest();

        System.assertEquals(1, PulseWorkflowEventPublisher.publishedCount,
            'Multiple Pending inserts on same instance should publish exactly one event');
    }
}
