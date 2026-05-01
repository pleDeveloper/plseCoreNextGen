/**
 * Tests for PulseWorkflowInstancePushTrigger.
 *
 * Asserts that meaningful changes (insert; updates to Current_State__c |
 * Status__c | Stage_Status__c) publish exactly one Pulse_Workflow_Update__e
 * per affected instance, and that updates to other fields publish nothing.
 *
 * Counts are read from PulseWorkflowEventPublisher's @TestVisible counter.
 */
@IsTest
private class PulseWorkflowInstancePushTriggerTest {

    private static Workflow_Definition__c makeDef(String key) {
        Workflow_Definition__c def = new Workflow_Definition__c(
            Workflow_Key__c = key,
            Version__c = 1,
            Status__c = 'Published',
            Definition_JSON__c = '{"schema":"pulse.workflow.v1"}',
            Subject_Kinds__c = 'Account'
        );
        insert def;
        return def;
    }

    private static Workflow_Instance__c makeInstance(Id defId) {
        Workflow_Instance__c inst = new Workflow_Instance__c(
            Workflow_Definition__c = defId,
            Current_State__c = 'step_one',
            Status__c = 'Active',
            Parent_Object_Type__c = 'Account'
        );
        insert inst;
        return inst;
    }

    @IsTest
    static void insert_publishesEvent() {
        Workflow_Definition__c def = makeDef('inst_push_insert');

        PulseWorkflowEventPublisher.publishedCount = 0;
        PulseWorkflowEventPublisher.publishedInstanceIds = new List<String>();

        Test.startTest();
        Workflow_Instance__c inst = makeInstance(def.Id);
        Test.stopTest();

        System.assertEquals(1, PulseWorkflowEventPublisher.publishedCount,
            'Insert should publish exactly one event');
        System.assertEquals(String.valueOf(inst.Id),
            PulseWorkflowEventPublisher.publishedInstanceIds[0]);
    }

    @IsTest
    static void updateCurrentState_publishesEvent() {
        Workflow_Definition__c def = makeDef('inst_push_state');
        Workflow_Instance__c inst = makeInstance(def.Id);

        PulseWorkflowEventPublisher.publishedCount = 0;
        PulseWorkflowEventPublisher.publishedInstanceIds = new List<String>();

        Test.startTest();
        inst.Current_State__c = 'step_two';
        update inst;
        Test.stopTest();

        System.assertEquals(1, PulseWorkflowEventPublisher.publishedCount,
            'Current_State__c change should publish one event');
    }

    @IsTest
    static void updateStatus_publishesEvent() {
        Workflow_Definition__c def = makeDef('inst_push_status');
        Workflow_Instance__c inst = makeInstance(def.Id);

        PulseWorkflowEventPublisher.publishedCount = 0;
        PulseWorkflowEventPublisher.publishedInstanceIds = new List<String>();

        Test.startTest();
        inst.Status__c = 'Completed';
        update inst;
        Test.stopTest();

        System.assertEquals(1, PulseWorkflowEventPublisher.publishedCount,
            'Status__c change should publish one event');
    }

    @IsTest
    static void updateStageStatus_publishesEvent() {
        Workflow_Definition__c def = makeDef('inst_push_stage');
        Workflow_Instance__c inst = makeInstance(def.Id);

        PulseWorkflowEventPublisher.publishedCount = 0;
        PulseWorkflowEventPublisher.publishedInstanceIds = new List<String>();

        Test.startTest();
        inst.Stage_Status__c = 'On_Hold';
        update inst;
        Test.stopTest();

        System.assertEquals(1, PulseWorkflowEventPublisher.publishedCount,
            'Stage_Status__c change should publish one event');
    }

    @IsTest
    static void updateUnrelatedField_publishesNothing() {
        Workflow_Definition__c def = makeDef('inst_push_unrelated');
        Workflow_Instance__c inst = makeInstance(def.Id);

        PulseWorkflowEventPublisher.publishedCount = 0;
        PulseWorkflowEventPublisher.publishedInstanceIds = new List<String>();

        Test.startTest();
        // Mutating Context_JSON__c is exactly the agent-loop case the filter
        // exists to suppress — no event must fire.
        inst.Context_JSON__c = '{"k":"v"}';
        update inst;
        Test.stopTest();

        System.assertEquals(0, PulseWorkflowEventPublisher.publishedCount,
            'Updates to non-watched fields must not publish events');
    }

    @IsTest
    static void rowsInsert_publishesOneEventPerInstance() {
        Workflow_Definition__c def = makeDef('inst_push_rows');

        PulseWorkflowEventPublisher.publishedCount = 0;
        PulseWorkflowEventPublisher.publishedInstanceIds = new List<String>();

        List<Workflow_Instance__c> rows = new List<Workflow_Instance__c>();
        for (Integer i = 0; i < 10; i++) {
            rows.add(new Workflow_Instance__c(
                Workflow_Definition__c = def.Id,
                Current_State__c = 'step_one',
                Status__c = 'Active',
                Parent_Object_Type__c = 'Account'
            ));
        }

        Test.startTest();
        insert rows;
        Test.stopTest();

        System.assertEquals(10, PulseWorkflowEventPublisher.publishedCount,
            'Bulk insert should publish one event per instance');
    }
}
