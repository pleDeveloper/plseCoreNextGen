/**
 * Helper that builds and publishes Pulse_Workflow_Update__e platform events
 * for a set of Workflow_Instance__c Ids.
 *
 * Used by triggers on Workflow_Action__c and Agent_Decision__c so the publish
 * loop is not duplicated. The Workflow_Instance__c trigger publishes inline
 * because it already has the Workflow_Instance__c records in Trigger.new and
 * does not need an Id-only path.
 *
 * Filtering for "meaningful change" is the responsibility of the caller; this
 * helper publishes one event per supplied Id with no extra logic.
 *
 * See docs/proposed-upstream-reactivity-and-ux-patterns.md section 1.
 */
public with sharing class PulseWorkflowEventPublisher {

    /**
     * Test-visible counter of how many Pulse_Workflow_Update__e events have
     * been emitted by this helper in the current transaction. Allows trigger
     * tests to assert exact publish counts without depending on
     * Test.getEventBus() delivery semantics.
     */
    @TestVisible
    private static Integer publishedCount = 0;

    /**
     * Test-visible Ids that were published in the current transaction.
     */
    @TestVisible
    private static List<String> publishedInstanceIds = new List<String>();

    /**
     * Publish one Pulse_Workflow_Update__e per supplied instance Id.
     * Null / empty input is a no-op.
     */
    public static void publishFor(Set<Id> instanceIds) {
        if (instanceIds == null || instanceIds.isEmpty()) return;

        List<Pulse_Workflow_Update__e> events = new List<Pulse_Workflow_Update__e>();
        for (Id instanceId : instanceIds) {
            if (instanceId == null) continue;
            String idStr = String.valueOf(instanceId);
            events.add(new Pulse_Workflow_Update__e(
                Instance_Id__c = idStr
            ));
            if (Test.isRunningTest()) {
                publishedInstanceIds.add(idStr);
            }
        }
        if (!events.isEmpty()) {
            EventBus.publish(events);
            if (Test.isRunningTest()) {
                publishedCount += events.size();
            }
        }
    }
}
