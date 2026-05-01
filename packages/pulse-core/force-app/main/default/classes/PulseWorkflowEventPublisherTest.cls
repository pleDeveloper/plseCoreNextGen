/**
 * Tests for PulseWorkflowEventPublisher.publishFor.
 *
 * Verifies the helper publishes one Pulse_Workflow_Update__e per supplied
 * instance Id and treats null / empty input as a no-op.
 *
 * Counts are read from the helper's @TestVisible static counter, which
 * sidesteps the asynchronous delivery semantics of platform events in
 * Apex tests.
 */
@IsTest
private class PulseWorkflowEventPublisherTest {

    @IsTest
    static void publishFor_singleInstance_publishesOneEvent() {
        Workflow_Definition__c def = new Workflow_Definition__c(
            Workflow_Key__c = 'pwep_single',
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

        PulseWorkflowEventPublisher.publishedCount = 0;
        PulseWorkflowEventPublisher.publishedInstanceIds = new List<String>();

        Test.startTest();
        PulseWorkflowEventPublisher.publishFor(new Set<Id>{ inst.Id });
        Test.stopTest();

        System.assertEquals(1, PulseWorkflowEventPublisher.publishedCount,
            'Should publish exactly one event for a single instance');
        System.assertEquals(1, PulseWorkflowEventPublisher.publishedInstanceIds.size(),
            'Tracker should record one Id');
        System.assertEquals(String.valueOf(inst.Id),
            PulseWorkflowEventPublisher.publishedInstanceIds[0],
            'Tracker should record the supplied instance Id');
    }

    @IsTest
    static void publishFor_multipleInstances_publishesOnePerId() {
        Workflow_Definition__c def = new Workflow_Definition__c(
            Workflow_Key__c = 'pwep_multi',
            Version__c = 1,
            Status__c = 'Published',
            Definition_JSON__c = '{"schema":"pulse.workflow.v1"}',
            Subject_Kinds__c = 'Account'
        );
        insert def;

        List<Workflow_Instance__c> instances = new List<Workflow_Instance__c>();
        for (Integer i = 0; i < 5; i++) {
            instances.add(new Workflow_Instance__c(
                Workflow_Definition__c = def.Id,
                Current_State__c = 'step_one',
                Status__c = 'Active',
                Parent_Object_Type__c = 'Account'
            ));
        }
        insert instances;

        Set<Id> ids = new Set<Id>();
        for (Workflow_Instance__c i : instances) ids.add(i.Id);

        PulseWorkflowEventPublisher.publishedCount = 0;
        PulseWorkflowEventPublisher.publishedInstanceIds = new List<String>();

        Test.startTest();
        PulseWorkflowEventPublisher.publishFor(ids);
        Test.stopTest();

        System.assertEquals(5, PulseWorkflowEventPublisher.publishedCount,
            'Should publish exactly one event per instance Id');
    }

    @IsTest
    static void publishFor_emptySet_isNoOp() {
        PulseWorkflowEventPublisher.publishedCount = 0;
        PulseWorkflowEventPublisher.publishedInstanceIds = new List<String>();

        Test.startTest();
        PulseWorkflowEventPublisher.publishFor(new Set<Id>());
        Test.stopTest();

        System.assertEquals(0, PulseWorkflowEventPublisher.publishedCount,
            'Empty set should publish nothing');
    }

    @IsTest
    static void publishFor_nullSet_isNoOp() {
        PulseWorkflowEventPublisher.publishedCount = 0;
        PulseWorkflowEventPublisher.publishedInstanceIds = new List<String>();

        Test.startTest();
        PulseWorkflowEventPublisher.publishFor(null);
        Test.stopTest();

        System.assertEquals(0, PulseWorkflowEventPublisher.publishedCount,
            'Null set should publish nothing');
    }
}
