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
        }
    }
}
