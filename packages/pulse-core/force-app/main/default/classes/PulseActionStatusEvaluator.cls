/**
 * PulseActionStatusEvaluator
 *
 * Resolves the canonical status key for a Workflow_Action__c against its
 * declared state machine (ActionDef.statuses). Iterates declared statuses
 * in order and returns the key of the first whose entryConditions match.
 *
 * Semantics:
 *   - statuses[] is expected in declared order (caller already sorts).
 *   - A status whose entryConditions is null or {} is ALWAYS considered a
 *     match — use ordering to control precedence.
 *   - When no status matches, returns the action's current Status_Key__c.
 *     If Status_Key__c is blank, derives a fallback from Status__c (legacy).
 *
 * Bulk safety: performs no SOQL and no DML. The caller must pass the
 * pre-loaded `allActionStatusesByKey` (sibling action -> current Status_Key)
 * and the parent SObject record.
 */
public with sharing class PulseActionStatusEvaluator {

    /**
     * Returns the first status (in declared order) whose entryConditions
     * pass. If none pass, returns the action's current Status_Key__c
     * (no-op). Empty entryConditions ({}) = always true.
     */
    public static String resolveStatusFor(
        Workflow_Action__c action,
        Map<String, String> allActionStatusesByKey,
        WorkflowContract.ActionDef def,
        SObject parentRecord
    ) {
        if (def == null) return fallbackKey(action);
        if (def.statuses == null || def.statuses.isEmpty()) {
            return fallbackKey(action);
        }
        Map<String, String> statusMap = allActionStatusesByKey == null
            ? new Map<String, String>() : allActionStatusesByKey;

        for (WorkflowContract.StatusDef sd : def.statuses) {
            if (sd == null || String.isBlank(sd.key)) continue;
            String conditionJson = conditionsJsonOf(sd.entryConditions);
            Boolean matched;
            try {
                matched = PulseWorkflowTriggerEvaluator.matches(
                    parentRecord, null, statusMap, conditionJson
                );
            } catch (Exception e) {
                // Malformed entryConditions on this status should not break
                // the whole evaluation — skip and try the next status.
                System.debug(LoggingLevel.WARN,
                    'PulseActionStatusEvaluator: entryConditions error for status ' +
                    sd.key + ' on action ' + (action == null ? 'null' : action.Id) +
                    ': ' + e.getMessage());
                continue;
            }
            if (matched) {
                return sd.key;
            }
        }
        return fallbackKey(action);
    }

    /**
     * Look up the StatusDef for a key on an ActionDef, for callers that
     * need the category after resolving a key. Returns null when not found.
     */
    public static WorkflowContract.StatusDef statusDefFor(
        WorkflowContract.ActionDef def, String statusKey
    ) {
        if (def == null || def.statuses == null || String.isBlank(statusKey)) {
            return null;
        }
        for (WorkflowContract.StatusDef sd : def.statuses) {
            if (sd != null && sd.key == statusKey) return sd;
        }
        return null;
    }

    // ── Helpers ───────────────────────────────────────────────────────

    private static String conditionsJsonOf(Map<String, Object> entryConditions) {
        if (entryConditions == null || entryConditions.isEmpty()) {
            return '{}'; // evaluator treats {} as "always true"
        }
        try {
            return JSON.serialize(entryConditions);
        } catch (Exception e) {
            return '{}';
        }
    }

    private static String fallbackKey(Workflow_Action__c action) {
        if (action == null) return null;
        if (String.isNotBlank(action.Status_Key__c)) return action.Status_Key__c;
        // Map legacy Status__c enum to a plausible key for dev-org actions
        // seeded before Status_Key__c existed. This is a read-only fallback
        // — the engine will decide whether to actually write Status_Key__c.
        if (String.isNotBlank(action.Status__c)) {
            String s = action.Status__c.toLowerCase();
            if (s == 'executed')  return 'completed';
            if (s == 'rejected')  return 'rejected';
            if (s == 'failed')    return 'failed';
            if (s == 'cancelled') return 'cancelled';
            if (s == 'pending')   return 'pending';
            return action.Status__c;
        }
        return null;
    }
}
