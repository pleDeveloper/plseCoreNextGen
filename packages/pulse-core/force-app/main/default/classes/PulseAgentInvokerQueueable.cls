public with sharing class PulseAgentInvokerQueueable implements Queueable, Database.AllowsCallouts {

    private Id instanceId;

    public PulseAgentInvokerQueueable(Id instanceId) {
        this.instanceId = instanceId;
    }

    public void execute(QueueableContext ctx) {
        try {
            PulseAgentRunner.RunResult result = PulseAgentRunner.run(instanceId);

            insert new Workflow_Event__c(
                Workflow_Instance__c = instanceId,
                Event_Type__c = result.success ? 'AGENT_COMPLETED' : 'AGENT_FAILED',
                Actor_Type__c = 'System',
                Detail_JSON__c = JSON.serialize(new Map<String, Object>{
                    'source' => 'PulseAgentInvokerQueueable',
                    'success' => result.success,
                    'errorMessage' => result.errorMessage,
                    'pendingApprovals' => result.pendingApprovals.size()
                })
            );
        } catch (Exception e) {
            insert new Workflow_Event__c(
                Workflow_Instance__c = instanceId,
                Event_Type__c = 'AGENT_FAILED',
                Actor_Type__c = 'System',
                Detail_JSON__c = JSON.serialize(new Map<String, Object>{
                    'source' => 'PulseAgentInvokerQueueable',
                    'exception' => e.getMessage(),
                    'stackTrace' => e.getStackTraceString()
                })
            );
        }
    }
}
