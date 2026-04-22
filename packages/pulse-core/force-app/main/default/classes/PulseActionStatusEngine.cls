/**
 * PulseActionStatusEngine
 *
 * Re-evaluates Workflow_Action__c.Status_Key__c for every action on an
 * instance using PulseActionStatusEvaluator + the workflow contract's
 * declared state machines. Cascades when a transition unblocks siblings.
 *
 * Responsibilities:
 *   - Bulk-load all actions for the instance (one SOQL).
 *   - Parse the instance's Workflow_Definition__c once.
 *   - Resolve the parent record once (one SOQL per distinct SObject type).
 *   - Iterate actions; call the evaluator with the current sibling-status
 *     map; detect transitions (new key ≠ current key).
 *   - Apply transitions: update Status_Key__c + Status_Category__c, append
 *     an entry to the Status_History_JSON__c ring buffer (cap 20), and
 *     fire a `Workflow_Event__c` with Event_Type__c = ACTION_STATUS_CHANGED.
 *   - Cascade: after applying a batch of transitions, re-iterate up to
 *     MAX_ITERATIONS times. Throws EvaluationException if the ceiling is
 *     exceeded (protects against oscillating machines).
 *
 * Bulk safety:
 *   - SOQL count: 1 instance + 1 definition + 1 actions + 1 parent = 4
 *     (independent of action count).
 *   - DML: one update for changed actions, one insert for events, both
 *     performed once at the end of each cascade iteration.
 */
public with sharing class PulseActionStatusEngine {

    public class EvaluationException extends Exception {}

    private static final Integer MAX_ITERATIONS = 5;
    private static final Integer HISTORY_CAP    = 20;

    /**
     * Reevaluate every Workflow_Action__c on the given instance. Returns
     * the list of actions whose Status_Key__c actually changed.
     */
    public static List<Workflow_Action__c> reevaluate(Id instanceId) {
        if (instanceId == null) return new List<Workflow_Action__c>();

        Workflow_Instance__c inst = loadInstance(instanceId);
        if (inst == null) return new List<Workflow_Action__c>();

        WorkflowContract.Workflow wf = loadContract(inst.Workflow_Definition__c);
        if (wf == null) return new List<Workflow_Action__c>();

        // Index ActionDefs by (phaseKey, actionKey) so we can match rows
        // regardless of which phase they belong to.
        Map<String, WorkflowContract.ActionDef> defByKey =
            indexActionDefs(wf);

        // Bulk-load the instance's actions.
        List<Workflow_Action__c> actions = [
            SELECT Id, Action_Key__c, Phase_Key__c, Status__c,
                   Status_Key__c, Status_Category__c, Status_History_JSON__c,
                   Workflow_Instance__c
            FROM   Workflow_Action__c
            WHERE  Workflow_Instance__c = :instanceId
        ];
        if (actions.isEmpty()) return new List<Workflow_Action__c>();

        // Load the parent record (conditions may reference parent fields).
        SObject parentRecord = loadParentRecord(inst, wf);

        // Run the fixed-point loop.
        List<Workflow_Action__c> allChanged = new List<Workflow_Action__c>();
        List<Workflow_Event__c> allEvents   = new List<Workflow_Event__c>();
        Integer iter = 0;
        while (true) {
            iter++;
            if (iter > MAX_ITERATIONS) {
                throw new EvaluationException(
                    'PulseActionStatusEngine loop-protect exceeded ' +
                    MAX_ITERATIONS + ' iterations on instance ' + instanceId
                );
            }
            List<Transition> changes = computeChangesOnce(actions, defByKey, parentRecord);
            if (changes.isEmpty()) break;

            for (Transition ch : changes) {
                applyTransitionInMemory(ch);
                allChanged.add(ch.row);
                allEvents.add(buildEvent(ch, instanceId));
            }
        }

        if (!allChanged.isEmpty()) {
            // Dedupe: multiple iterations may have touched the same row; we
            // want the final state reflected in a single update call.
            Map<Id, Workflow_Action__c> dedup = new Map<Id, Workflow_Action__c>();
            for (Workflow_Action__c r : allChanged) dedup.put(r.Id, r);
            update dedup.values();
            if (!allEvents.isEmpty()) {
                insert allEvents;
            }
            return dedup.values();
        }
        return new List<Workflow_Action__c>();
    }

    /**
     * Convenience: reevaluate the instance that contains `actionId`.
     * Returns only the changes (same shape as reevaluate).
     */
    public static List<Workflow_Action__c> reevaluateForAction(Id actionId) {
        if (actionId == null) return new List<Workflow_Action__c>();
        List<Workflow_Action__c> rows = [
            SELECT Id, Workflow_Instance__c
            FROM   Workflow_Action__c
            WHERE  Id = :actionId LIMIT 1
        ];
        if (rows.isEmpty() || rows[0].Workflow_Instance__c == null) {
            return new List<Workflow_Action__c>();
        }
        return reevaluate(rows[0].Workflow_Instance__c);
    }

    // ── Internals ─────────────────────────────────────────────────────

    /**
     * One pass over `actions`: builds the current statusesByKey snapshot
     * and asks the evaluator for a new status per row. Returns the list
     * of transitions (new key != current). Does NOT mutate `actions`.
     */
    private static List<Transition> computeChangesOnce(
        List<Workflow_Action__c> actions,
        Map<String, WorkflowContract.ActionDef> defByKey,
        SObject parentRecord
    ) {
        Map<String, String> statusesByKey = new Map<String, String>();
        for (Workflow_Action__c r : actions) {
            if (String.isBlank(r.Action_Key__c)) continue;
            String currentKey = String.isNotBlank(r.Status_Key__c)
                ? r.Status_Key__c
                : deriveLegacyKey(r.Status__c);
            if (currentKey != null) {
                statusesByKey.put(r.Action_Key__c, currentKey);
            }
        }

        List<Transition> changes = new List<Transition>();
        for (Workflow_Action__c r : actions) {
            if (String.isBlank(r.Action_Key__c)) continue;
            WorkflowContract.ActionDef def = defByKey.get(defKey(r.Phase_Key__c, r.Action_Key__c));
            if (def == null) continue;
            if (def.statuses == null || def.statuses.isEmpty()) continue;

            String currentKey = String.isNotBlank(r.Status_Key__c)
                ? r.Status_Key__c
                : deriveLegacyKey(r.Status__c);
            String nextKey = PulseActionStatusEvaluator.resolveStatusFor(
                r, statusesByKey, def, parentRecord
            );
            if (String.isBlank(nextKey)) continue;
            if (nextKey == currentKey) continue;

            WorkflowContract.StatusDef sd =
                PulseActionStatusEvaluator.statusDefFor(def, nextKey);

            Transition ch = new Transition();
            ch.row          = r;
            ch.def          = def;
            ch.fromKey      = currentKey;
            ch.toKey        = nextKey;
            ch.toCategory   = sd == null ? null : sd.category;
            changes.add(ch);
        }
        return changes;
    }

    /**
     * Apply a single transition to the in-memory action row so the next
     * iteration can observe the new state. Also appends a history entry
     * bounded by HISTORY_CAP.
     */
    private static void applyTransitionInMemory(Transition ch) {
        Workflow_Action__c row = ch.row;
        row.Status_Key__c = ch.toKey;
        if (String.isNotBlank(ch.toCategory)) {
            row.Status_Category__c = ch.toCategory;
        }
        row.Status_History_JSON__c = appendHistory(
            row.Status_History_JSON__c, ch.fromKey, ch.toKey
        );
    }

    private static String appendHistory(String currentJson, String fromKey, String toKey) {
        List<Object> entries = new List<Object>();
        if (String.isNotBlank(currentJson)) {
            try {
                Object parsed = JSON.deserializeUntyped(currentJson);
                if (parsed instanceof List<Object>) {
                    entries = (List<Object>) parsed;
                }
            } catch (Exception e) {
                entries = new List<Object>();
            }
        }
        Map<String, Object> entry = new Map<String, Object>{
            'at'     => Datetime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\''),
            'from'   => fromKey,
            'to'     => toKey,
            'actor'  => UserInfo.getUserId(),
            'reason' => 'engine_evaluation'
        };
        entries.add(entry);
        // Cap the ring buffer by dropping oldest entries.
        while (entries.size() > HISTORY_CAP) {
            entries.remove(0);
        }
        return JSON.serialize(entries);
    }

    private static Workflow_Event__c buildEvent(Transition ch, Id instanceId) {
        Map<String, Object> detail = new Map<String, Object>{
            'actionKey'  => ch.row.Action_Key__c,
            'from'       => ch.fromKey,
            'to'         => ch.toKey,
            'instanceId' => String.valueOf(instanceId)
        };
        return new Workflow_Event__c(
            Workflow_Instance__c = instanceId,
            Event_Type__c        = 'ACTION_STATUS_CHANGED',
            Actor_Type__c        = 'System',
            Detail_JSON__c       = JSON.serialize(detail)
        );
    }

    // ── Loaders / indexers ────────────────────────────────────────────

    private static Workflow_Instance__c loadInstance(Id id) {
        List<Workflow_Instance__c> rows = [
            SELECT Id, Current_State__c, Workflow_Definition__c,
                   Parent_Object_Type__c, Parent_Record_Id__c
            FROM   Workflow_Instance__c
            WHERE  Id = :id LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    private static WorkflowContract.Workflow loadContract(Id defId) {
        if (defId == null) return null;
        List<Workflow_Definition__c> rows = [
            SELECT Definition_JSON__c FROM Workflow_Definition__c
            WHERE Id = :defId LIMIT 1
        ];
        if (rows.isEmpty() || String.isBlank(rows[0].Definition_JSON__c)) return null;
        try {
            return WorkflowContract.parse(rows[0].Definition_JSON__c);
        } catch (Exception e) {
            return null;
        }
    }

    private static Map<String, WorkflowContract.ActionDef> indexActionDefs(
        WorkflowContract.Workflow wf
    ) {
        Map<String, WorkflowContract.ActionDef> out =
            new Map<String, WorkflowContract.ActionDef>();
        if (wf == null || wf.states == null) return out;
        for (WorkflowContract.State s : wf.states) {
            if (s == null || s.actions == null) continue;
            for (WorkflowContract.ActionDef a : s.actions) {
                if (a == null || String.isBlank(a.key)) continue;
                out.put(defKey(s.key, a.key), a);
            }
        }
        return out;
    }

    private static String defKey(String phaseKey, String actionKey) {
        return (phaseKey == null ? '' : phaseKey) + '|' + (actionKey == null ? '' : actionKey);
    }

    private static String deriveLegacyKey(String status) {
        if (String.isBlank(status)) return null;
        String s = status.toLowerCase();
        if (s == 'executed')  return 'completed';
        if (s == 'rejected')  return 'rejected';
        if (s == 'failed')    return 'failed';
        if (s == 'cancelled') return 'cancelled';
        if (s == 'pending')   return 'pending';
        return status;
    }

    /**
     * Loads the parent record addressed by the instance. Uses a dynamic
     * SOQL because Parent_Object_Type__c is variable. Returns null when
     * the instance has no parent or the type/id is missing.
     *
     * We SELECT the full field list from the describe so entryConditions
     * can reference any field on the parent sObject. For very wide
     * objects this is still one SOQL — the evaluator itself does no
     * further queries.
     */
    private static SObject loadParentRecord(
        Workflow_Instance__c inst, WorkflowContract.Workflow wf
    ) {
        if (inst == null) return null;
        String parentType = inst.Parent_Object_Type__c;
        String parentId   = inst.Parent_Record_Id__c;
        if (String.isBlank(parentType) || String.isBlank(parentId)) return null;

        Schema.SObjectType sot = Schema.getGlobalDescribe().get(parentType);
        if (sot == null) return null;

        Map<String, Schema.SObjectField> fieldsMap = sot.getDescribe().fields.getMap();
        if (fieldsMap.isEmpty()) return null;
        List<String> fieldNames = new List<String>(fieldsMap.keySet());
        // Guard against governor limits by capping the field list: 1000
        // fields is SOQL-safe and covers the vast majority of objects.
        if (fieldNames.size() > 1000) {
            fieldNames = new List<String>();
            fieldNames.add('Id');
            // Add a small default set; entryConditions that need more will
            // fail gracefully via the evaluator.
            for (String candidate : new List<String>{
                'Name', 'OwnerId', 'CreatedById', 'StageName', 'Status', 'Type'
            }) {
                if (fieldsMap.containsKey(candidate.toLowerCase())) {
                    fieldNames.add(candidate);
                }
            }
        }

        String soql =
            'SELECT ' + String.join(fieldNames, ', ') +
            ' FROM '  + String.escapeSingleQuotes(parentType) +
            ' WHERE Id = :parentId LIMIT 1';
        try {
            List<SObject> rows = Database.query(soql);
            if (rows.isEmpty()) return null;
            return rows[0];
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'PulseActionStatusEngine: parent load failed (' + parentType +
                '/' + parentId + '): ' + e.getMessage());
            return null;
        }
    }

    // Internal transition descriptor.
    private class Transition {
        Workflow_Action__c row;
        WorkflowContract.ActionDef def;
        String fromKey;
        String toKey;
        String toCategory;
    }
}
