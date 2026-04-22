/**
 * PhaseActionHook
 *
 * WorkflowRuntime hook that instantiates Workflow_Action__c rows when an
 * instance enters a new phase (state). Runs after every successful
 * transition.
 *
 * Parallel in pattern to StageDwellHook.
 */
public with sharing class PhaseActionHook implements WorkflowRuntime.TransitionHook {

    private static Boolean registered = false;

    public static void register() {
        if (!registered) {
            WorkflowRuntime.registerHook(new PhaseActionHook());
            registered = true;
        }
    }

    @TestVisible
    private static void resetForTest() {
        registered = false;
    }

    public void afterTransitions(List<WorkflowRuntime.TransitionContext> contexts) {
        if (contexts == null || contexts.isEmpty()) return;
        for (WorkflowRuntime.TransitionContext ctx : contexts) {
            if (ctx.instanceId == null) continue;
            try {
                PulseActionInstantiationService.instantiateForPhase(ctx.instanceId);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR,
                    'PhaseActionHook: instantiation failed for ' + ctx.instanceId +
                    ': ' + e.getMessage());
            }
            // Agent Mode: if the entered phase has agent config, kick the
            // orchestrator so the agent proposes the first decision.
            try {
                kickAgentIfEnabled(ctx.instanceId);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR,
                    'PhaseActionHook: agent kick failed for ' + ctx.instanceId +
                    ': ' + e.getMessage());
            }
        }
    }

    private static void kickAgentIfEnabled(Id instanceId) {
        List<Workflow_Instance__c> rows = [
            SELECT Id, Current_State__c,
                   Workflow_Definition__r.Definition_JSON__c
            FROM Workflow_Instance__c
            WHERE Id = :instanceId LIMIT 1
        ];
        if (rows.isEmpty()) return;
        WorkflowContract.Workflow wf;
        try {
            wf = WorkflowContract.parse(rows[0].Workflow_Definition__r.Definition_JSON__c);
        } catch (Exception e) {
            return;
        }
        if (wf == null) return;
        Map<String, Object> cfg = wf.agentConfigForPhase(rows[0].Current_State__c);
        if (cfg == null) return;
        PulseAgentOrchestrator.advance(instanceId);
    }
}
