/**
 * Publishes Pulse_Workflow_Update__e for meaningful Workflow_Action__c
 * lifecycle events so subscribed LWCs refresh without polling.
 *
 * Filter discipline (see docs/proposed-upstream-reactivity-and-ux-patterns.md
 * section 1):
 *
 *   - On insert: only Pending rows are user-visible; agent scan/decide passes
 *     can produce Skipped / Observe / Error rows that must NOT drive UI
 *     refreshes (would cause an agent-retry-loop -> UI-refresh-loop).
 *   - On update: only fire when Status__c actually transitions.
 *
 * Events are published per parent Workflow_Instance__c via the shared
 * PulseWorkflowEventPublisher helper.
 */
trigger PulseWorkflowActionPushTrigger on Workflow_Action__c (after insert, after update) {
    Set<Id> instanceIds = new Set<Id>();
    for (Workflow_Action__c a : Trigger.new) {
        if (a.Workflow_Instance__c == null) continue;
        Boolean meaningful = false;
        if (Trigger.isInsert) {
            meaningful = (a.Status__c == 'Pending');
        } else {
            Workflow_Action__c o = Trigger.oldMap.get(a.Id);
            if (o != null && o.Status__c != a.Status__c) {
                meaningful = true;
            }
        }
        if (meaningful) {
            instanceIds.add(a.Workflow_Instance__c);
        }
    }
    PulseWorkflowEventPublisher.publishFor(instanceIds);
}
