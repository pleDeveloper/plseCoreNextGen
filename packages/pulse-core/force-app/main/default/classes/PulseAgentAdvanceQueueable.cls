/**
 * PulseAgentAdvanceQueueable
 *
 * Wraps PulseAgentOrchestrator.advance in a Queueable so callers that
 * have already done DML in their transaction (approveDecision,
 * rejectDecision, answerQuestion — they all touch Agent_Decision__c /
 * Workflow_Action__c / Workflow_Instance__c before re-kicking the agent)
 * can re-kick the AI loop without hitting the "You have uncommitted work
 * pending" callout-after-DML rule. The Queueable runs in its own
 * transaction.
 */
public with sharing class PulseAgentAdvanceQueueable implements Queueable, Database.AllowsCallouts {

    private final Id instanceId;

    public PulseAgentAdvanceQueueable(Id instanceId) {
        this.instanceId = instanceId;
    }

    public void execute(QueueableContext ctx) {
        if (instanceId == null) return;
        PulseAgentOrchestrator.advance(instanceId);
    }
}
