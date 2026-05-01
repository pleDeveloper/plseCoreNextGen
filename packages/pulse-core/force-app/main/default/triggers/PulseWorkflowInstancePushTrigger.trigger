/**
 * Publishes Pulse_Workflow_Update__e for meaningful Workflow_Instance__c
 * changes so subscribed LWCs (stepper, status rail) refresh without polling.
 *
 * Filter discipline (see docs/proposed-upstream-reactivity-and-ux-patterns.md
 * section 1): only changes to user-visible fields produce events. The agent
 * runTurn loop legitimately mutates Context_JSON__c and similar internal
 * state during scan-and-decide passes; if those fired events, every LWC
 * subscriber would refresh on every retry, driving a refresh loop in the UI.
 *
 *   - All inserts are meaningful (initial state appears).
 *   - On update, only Current_State__c | Status__c | Stage_Status__c deltas.
 *
 * Delegates the actual publish loop to PulseWorkflowEventPublisher so the
 * three push triggers share one publish path.
 */
trigger PulseWorkflowInstancePushTrigger on Workflow_Instance__c (after update, after insert) {
    Set<Id> instanceIds = new Set<Id>();
    for (Workflow_Instance__c n : Trigger.new) {
        Boolean meaningful = false;
        if (Trigger.isInsert) {
            meaningful = true;
        } else {
            Workflow_Instance__c o = Trigger.oldMap.get(n.Id);
            if (o == null) {
                meaningful = true;
            } else if (n.Current_State__c != o.Current_State__c) {
                meaningful = true;
            } else if (n.Status__c != o.Status__c) {
                meaningful = true;
            } else if (n.Stage_Status__c != o.Stage_Status__c) {
                meaningful = true;
            }
        }
        if (meaningful) {
            instanceIds.add(n.Id);
        }
    }
    PulseWorkflowEventPublisher.publishFor(instanceIds);
}
