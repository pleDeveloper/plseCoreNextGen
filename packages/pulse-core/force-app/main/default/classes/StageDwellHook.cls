/**
 * TransitionHook that captures per-state dwell times into Stage_Dwell__c.
 * On each transition: closes the FROM-state dwell row (sets Exited_At +
 * Duration_Seconds) and opens a new TO-state dwell row (Entered_At only).
 *
 * Bulk-safe: one SOQL to load instance metadata, one SOQL to load open
 * dwell rows, one upsert/insert DML batch at the end.
 */
public with sharing class StageDwellHook implements WorkflowRuntime.TransitionHook {

    // Testability seam: counts rows created in the current transaction
    @TestVisible
    private static Integer rowsCreated = 0;

    public static void register() {
        WorkflowRuntime.registerHook(new StageDwellHook());
    }

    public void afterTransitions(List<WorkflowRuntime.TransitionContext> contexts) {
        if (contexts == null || contexts.isEmpty()) {
            return;
        }

        // 1. Collect instance IDs
        Set<Id> instanceIds = new Set<Id>();
        for (WorkflowRuntime.TransitionContext ctx : contexts) {
            instanceIds.add(ctx.instanceId);
        }

        // 2. Bulk load instance metadata for workflow key + definition
        Map<Id, Workflow_Instance__c> instanceMap = new Map<Id, Workflow_Instance__c>([
            SELECT Id, Workflow_Definition__r.Definition_JSON__c
            FROM Workflow_Instance__c
            WHERE Id IN :instanceIds
        ]);

        // 3. Parse definitions once per unique definition JSON
        Map<Id, WorkflowContract.Workflow> parsedDefs = new Map<Id, WorkflowContract.Workflow>();
        for (Workflow_Instance__c inst : instanceMap.values()) {
            if (parsedDefs.containsKey(inst.Id)) {
                continue;
            }
            String json = inst.Workflow_Definition__r?.Definition_JSON__c;
            if (String.isNotBlank(json)) {
                try {
                    parsedDefs.put(inst.Id, WorkflowContract.parse(json));
                } catch (Exception e) {
                    // Silently skip — hook should not break transitions
                }
            }
        }

        // 4. Bulk load open dwell rows (Exited_At == null) for these instances
        Map<String, Stage_Dwell__c> openDwells = new Map<String, Stage_Dwell__c>();
        for (Stage_Dwell__c sd : [
            SELECT Id, Workflow_Instance__c, State_Key__c, Entered_At__c
            FROM Stage_Dwell__c
            WHERE Workflow_Instance__c IN :instanceIds
              AND Exited_At__c = NULL
        ]) {
            openDwells.put(compositeKey(sd.Workflow_Instance__c, sd.State_Key__c), sd);
        }

        // 5. Build DML lists
        List<Stage_Dwell__c> toUpdate = new List<Stage_Dwell__c>();
        List<Stage_Dwell__c> toInsert = new List<Stage_Dwell__c>();

        for (WorkflowRuntime.TransitionContext ctx : contexts) {
            WorkflowContract.Workflow wf = parsedDefs.get(ctx.instanceId);
            String workflowKey = wf != null ? wf.workflowKey : null;
            String subjectKind = (wf != null && wf.subjectKinds != null && !wf.subjectKinds.isEmpty())
                ? wf.subjectKinds[0] : null;

            Datetime transitionTime = ctx.stepResult?.Completed_Date__c != null
                ? ctx.stepResult.Completed_Date__c : Datetime.now();
            String actorType = ctx.stepResult?.Actor_Type__c;
            String signal = ctx.stepResult?.Signal__c;

            // Close the FROM-state dwell row if one exists
            String fromKey = compositeKey(ctx.instanceId, ctx.fromStateKey);
            Stage_Dwell__c fromDwell = openDwells.get(fromKey);
            if (fromDwell != null) {
                fromDwell.Exited_At__c = transitionTime;
                fromDwell.Duration_Seconds__c = computeDurationSeconds(
                    fromDwell.Entered_At__c, transitionTime
                );
                fromDwell.Next_State_Key__c = ctx.toStateKey;
                fromDwell.Signal__c = signal;
                fromDwell.Actor_Type__c = actorType;
                toUpdate.add(fromDwell);
            }

            // Create the TO-state dwell row
            WorkflowContract.State toState = wf != null ? wf.getState(ctx.toStateKey) : null;
            Stage_Dwell__c toDwell = new Stage_Dwell__c(
                Workflow_Instance__c = ctx.instanceId,
                Workflow_Key__c = workflowKey,
                Subject_Kind__c = subjectKind,
                State_Key__c = ctx.toStateKey,
                State_Label__c = toState != null ? toState.label : ctx.toStateKey,
                State_Type__c = toState != null ? toState.stateType : null,
                Entered_At__c = transitionTime,
                Exited_At__c = null
            );
            toInsert.add(toDwell);
        }

        // 6. DML
        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }
        if (!toInsert.isEmpty()) {
            insert toInsert;
            rowsCreated += toInsert.size();
        }
    }

    // ── Private helpers ──────────────────────────────────────────────

    private static String compositeKey(Id instanceId, String stateKey) {
        return String.valueOf(instanceId) + ':' + stateKey;
    }

    private static Integer computeDurationSeconds(Datetime enteredAt, Datetime exitedAt) {
        if (enteredAt == null || exitedAt == null) {
            return 0;
        }
        Long ms = exitedAt.getTime() - enteredAt.getTime();
        return (Integer) (ms / 1000);
    }
}
