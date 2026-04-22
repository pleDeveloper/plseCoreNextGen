/**
 * PulseWorkflowStarter
 *
 * Entry point invoked by per-object Apex triggers to auto-start workflow
 * instances when configured conditions match.
 *
 * Per-object triggers are provisioned on demand by PulseTriggerProvisioningService.
 * Each generated trigger is a thin wrapper that delegates here:
 *
 *   trigger Opportunity_PulseWorkflowTrigger on Opportunity (after insert, after update) {
 *       plse.PulseWorkflowStarter.handle('Opportunity', Trigger.new, Trigger.oldMap,
 *           Trigger.isInsert);
 *   }
 *
 * Idempotency: if an Active Workflow_Instance__c already exists for this
 * (Workflow_Definition, Parent_Record_Id) pair, no new instance is created.
 */
global with sharing class PulseWorkflowStarter {

    @TestVisible private static Boolean suppressed = false;

    /**
     * Main entry point for provisioned Apex triggers.
     *
     * @param sObjectType  API name of the SObject being saved (e.g. 'Opportunity')
     * @param newList      Trigger.new
     * @param oldMap       Trigger.oldMap (null on insert)
     * @param isInsert     Trigger.isInsert
     */
    global static void handle(
        String sObjectType,
        List<SObject> newList,
        Map<Id, SObject> oldMap,
        Boolean isInsert
    ) {
        if (suppressed || newList == null || newList.isEmpty()) {
            return;
        }

        // 1. Load active triggers for this object
        List<Workflow_Trigger__c> triggers = [
            SELECT Id, Workflow_Definition__c, Target_Object__c, Event_Type__c,
                   Condition_JSON__c, Initial_State_Key__c, Active__c
            FROM   Workflow_Trigger__c
            WHERE  Active__c = true
              AND  Target_Object__c = :sObjectType
        ];
        if (triggers.isEmpty()) {
            return;
        }

        // 2. Build the set of (workflow_definition, record_id) pairs that would be
        //    created, and filter out those that already have an instance.
        Set<Id> candidateRecordIds   = new Set<Id>();
        Set<Id> candidateDefIds      = new Set<Id>();
        List<PendingStart> pending   = new List<PendingStart>();

        for (SObject rec : newList) {
            SObject oldRec = (oldMap != null) ? oldMap.get((Id) rec.get('Id')) : null;

            for (Workflow_Trigger__c t : triggers) {
                if (!eventTypeMatches(t.Event_Type__c, isInsert)) {
                    continue;
                }
                Boolean matches;
                try {
                    matches = PulseWorkflowTriggerEvaluator.matches(
                        rec, oldRec, t.Condition_JSON__c
                    );
                } catch (Exception e) {
                    System.debug(LoggingLevel.ERROR,
                        'PulseWorkflowStarter: evaluator error for trigger ' + t.Id +
                        ': ' + e.getMessage());
                    continue;
                }
                if (!matches) continue;

                PendingStart p = new PendingStart();
                p.trigger_x            = t;
                p.recordId             = (Id) rec.get('Id');
                p.workflowDefinitionId = t.Workflow_Definition__c;
                pending.add(p);

                candidateRecordIds.add(p.recordId);
                candidateDefIds.add(p.workflowDefinitionId);
            }
        }

        if (pending.isEmpty()) {
            return;
        }

        // 3. Skip any pair that already has an open instance.
        Set<String> existingPairs = new Set<String>();
        for (Workflow_Instance__c existing : [
            SELECT Workflow_Definition__c, Parent_Record_Id__c
            FROM   Workflow_Instance__c
            WHERE  Parent_Record_Id__c IN :candidateRecordIds
              AND  Workflow_Definition__c IN :candidateDefIds
        ]) {
            existingPairs.add(
                String.valueOf(existing.Workflow_Definition__c) + '|' +
                existing.Parent_Record_Id__c
            );
        }

        // 4. Resolve initial state (falls back to first state in the definition)
        Map<Id, String> initialStateByDef = resolveInitialStates(pending);

        // 5. Build instances to insert.
        List<Workflow_Instance__c> toInsert = new List<Workflow_Instance__c>();
        for (PendingStart p : pending) {
            String pairKey = String.valueOf(p.workflowDefinitionId) + '|' + p.recordId;
            if (existingPairs.contains(pairKey)) continue;
            existingPairs.add(pairKey); // dedupe within same batch

            String initial = String.isNotBlank(p.trigger_x.Initial_State_Key__c)
                ? p.trigger_x.Initial_State_Key__c
                : initialStateByDef.get(p.workflowDefinitionId);
            if (String.isBlank(initial)) {
                // Can't start without a state — skip and log
                System.debug(LoggingLevel.WARN,
                    'PulseWorkflowStarter: no initial state for definition ' +
                    p.workflowDefinitionId + ' — skipping record ' + p.recordId);
                continue;
            }

            toInsert.add(new Workflow_Instance__c(
                Workflow_Definition__c = p.workflowDefinitionId,
                Parent_Object_Type__c  = sObjectType,
                Parent_Record_Id__c    = p.recordId,
                Current_State__c       = initial,
                Status__c              = 'Active',
                Started_Date__c        = Datetime.now(),
                Pinned_Version__c      = 1
            ));
        }

        if (!toInsert.isEmpty()) {
            insert toInsert;
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────

    private static Boolean eventTypeMatches(String eventType, Boolean isInsert) {
        if (String.isBlank(eventType)) return true;
        String e = eventType.toUpperCase();
        if (e == 'CREATED')             return isInsert == true;
        if (e == 'UPDATED')             return isInsert == false;
        if (e == 'CREATED_OR_UPDATED')  return true;
        return true;
    }

    private static Map<Id, String> resolveInitialStates(List<PendingStart> pending) {
        Set<Id> defIds = new Set<Id>();
        for (PendingStart p : pending) defIds.add(p.workflowDefinitionId);
        Map<Id, String> out = new Map<Id, String>();
        if (defIds.isEmpty()) return out;

        for (Workflow_Definition__c wd : [
            SELECT Id, Definition_JSON__c
            FROM   Workflow_Definition__c
            WHERE  Id IN :defIds
        ]) {
            out.put(wd.Id, firstStateKey(wd.Definition_JSON__c));
        }
        return out;
    }

    private static String firstStateKey(String definitionJson) {
        if (String.isBlank(definitionJson)) return null;
        try {
            Object parsed = JSON.deserializeUntyped(definitionJson);
            if (!(parsed instanceof Map<String, Object>)) return null;
            Map<String, Object> root = (Map<String, Object>) parsed;
            List<Object> states = (List<Object>) root.get('states');
            if (states == null || states.isEmpty()) return null;
            Object first = states[0];
            if (!(first instanceof Map<String, Object>)) return null;
            return (String) ((Map<String, Object>) first).get('key');
        } catch (Exception e) {
            return null;
        }
    }

    // Inner row used while computing what to insert.
    // 'trigger' is reserved in Apex; use 'trigger_x'.
    private class PendingStart {
        public Workflow_Trigger__c trigger_x;
        public Id recordId;
        public Id workflowDefinitionId;
    }
}
