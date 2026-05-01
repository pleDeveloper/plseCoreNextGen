/**
 * Publishes Pulse_Workflow_Update__e for meaningful Agent_Decision__c
 * lifecycle events so subscribed LWCs (decision queue) refresh without
 * polling.
 *
 * Filter discipline (see docs/proposed-upstream-reactivity-and-ux-patterns.md
 * section 1):
 *
 *   - On insert: only Pending_User / Auto_Executed / Answered rows are
 *     user-visible. Internal Observe / Skipped / Error rows produced by the
 *     agent scan loop must NOT drive UI refreshes.
 *   - On update: only fire when a row leaves Pending_User (the user just
 *     resolved it, or the policy auto-resolved it).
 *
 * Events are published per parent Workflow_Instance__c via the shared
 * PulseWorkflowEventPublisher helper.
 */
trigger PulseAgentDecisionPushTrigger on Agent_Decision__c (after insert, after update) {
    Set<Id> instanceIds = new Set<Id>();
    for (Agent_Decision__c d : Trigger.new) {
        if (d.Workflow_Instance__c == null) continue;
        Boolean meaningful = false;
        if (Trigger.isInsert) {
            meaningful = (d.Status__c == 'Pending_User'
                       || d.Status__c == 'Auto_Executed'
                       || d.Status__c == 'Answered');
        } else {
            Agent_Decision__c old = Trigger.oldMap.get(d.Id);
            meaningful = old != null
                && old.Status__c == 'Pending_User'
                && d.Status__c != 'Pending_User';
        }
        if (meaningful) {
            instanceIds.add(d.Workflow_Instance__c);
        }
    }
    PulseWorkflowEventPublisher.publishFor(instanceIds);
}
