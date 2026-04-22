/**
 * Fires when a new Workflow_Instance__c is created (e.g. by PulseWorkflowStarter
 * from a record-triggered workflow, or by data load / seed scripts). Instantiates
 * Workflow_Action__c rows for the initial phase's actions.
 *
 * Follow-up transitions go through WorkflowRuntime.advance(), which has its
 * own PhaseActionHook. This trigger handles only the first phase entry.
 */
trigger WorkflowInstanceActionTrigger on Workflow_Instance__c (after insert) {
    for (Workflow_Instance__c inst : Trigger.new) {
        if (inst.Status__c != 'Active') continue;
        if (String.isBlank(inst.Current_State__c)) continue;
        try {
            PulseActionInstantiationService.instantiateForPhase(inst.Id);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'WorkflowInstanceActionTrigger: instantiation failed for ' + inst.Id +
                ': ' + e.getMessage());
        }
        // Run the status engine so actions whose entryConditions already
        // pass land on the correct status_key on first creation, not only
        // after a follow-up transition. Additive to initial-key seeding.
        try {
            PulseActionStatusEngine.reevaluate(inst.Id);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'WorkflowInstanceActionTrigger: status reevaluate failed for ' + inst.Id +
                ': ' + e.getMessage());
        }
    }
}
