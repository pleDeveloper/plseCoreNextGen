/**
 * PulseActionInstantiationService
 *
 * Owns the materialisation of Workflow_Action__c rows from the declarative
 * `actions[]` array on a phase in WorkflowContract.
 *
 * Lifecycle:
 *   - When a workflow instance enters a phase, instantiateForPhase() is
 *     called. It creates Workflow_Action__c rows for every action whose
 *     dependencies are already satisfied (no deps, or all deps complete).
 *   - When an action reaches a terminal state, promoteDependents() is
 *     called. It finds actions whose dependencies have just become
 *     satisfied and instantiates them.
 *
 * Terminal states: Executed (success), Rejected, Failed, Cancelled.
 * "Complete for dep resolution" means: Status = Executed.
 * Rejected/Failed/Cancelled deps *block* their dependents — dependents are
 * never instantiated because the dependency never succeeded.
 *
 * Idempotent: will never create a duplicate Workflow_Action__c for the
 * same (instance, phase, action_key) triple.
 */
public with sharing class PulseActionInstantiationService {

    private static final Set<String> TERMINAL_SUCCESS = new Set<String>{
        'Executed'
    };
    private static final Set<String> TERMINAL_ANY = new Set<String>{
        'Executed', 'Rejected', 'Failed', 'Cancelled'
    };

    /**
     * Instantiate all actions that are ready to start for the instance's
     * current phase. Returns the newly created Workflow_Action__c records.
     */
    public static List<Workflow_Action__c> instantiateForPhase(Id instanceId) {
        if (instanceId == null) return new List<Workflow_Action__c>();

        Workflow_Instance__c inst = loadInstance(instanceId);
        if (inst == null || String.isBlank(inst.Current_State__c)) {
            return new List<Workflow_Action__c>();
        }
        WorkflowContract.Workflow wf = loadContract(inst.Workflow_Definition__c);
        if (wf == null) return new List<Workflow_Action__c>();

        WorkflowContract.State phase = wf.getState(inst.Current_State__c);
        if (phase == null || phase.actions == null || phase.actions.isEmpty()) {
            return new List<Workflow_Action__c>();
        }

        Map<String, Workflow_Action__c> existing = loadExistingActions(instanceId, inst.Current_State__c);
        Map<String, String> existingStatus = new Map<String, String>();
        for (String key : existing.keySet()) {
            existingStatus.put(key, existing.get(key).Status__c);
        }

        List<Workflow_Action__c> toInsert = new List<Workflow_Action__c>();
        for (WorkflowContract.ActionDef def : phase.actions) {
            if (existing.containsKey(def.key)) continue;
            if (!dependenciesSatisfied(def, existingStatus)) continue;
            Workflow_Action__c rec = buildRecord(inst, phase, def);
            toInsert.add(rec);
        }
        if (!toInsert.isEmpty()) {
            insert toInsert;
        }
        return toInsert;
    }

    /**
     * Called after a single action transitions. Promotes (instantiates)
     * any dependent actions whose dependencies are now satisfied.
     */
    public static List<Workflow_Action__c> promoteDependents(Id justCompletedActionId) {
        if (justCompletedActionId == null) return new List<Workflow_Action__c>();
        Workflow_Action__c completed = [
            SELECT Id, Workflow_Instance__c, Phase_Key__c, Action_Key__c, Status__c
            FROM Workflow_Action__c WHERE Id = :justCompletedActionId LIMIT 1
        ];
        if (completed.Workflow_Instance__c == null) return new List<Workflow_Action__c>();
        // Promotion is the same as re-running instantiateForPhase on the
        // same phase — it's idempotent and respects deps.
        return instantiateForPhase(completed.Workflow_Instance__c);
    }

    /**
     * Returns true when every required action defined for the phase has
     * reached a terminal-success state (Executed). This is the signal
     * that the workflow may advance out of the phase.
     *
     * "Required" is determined by the contract's required flag (defaults
     * true when unset).
     */
    public static Boolean phaseComplete(Id instanceId) {
        if (instanceId == null) return false;
        Workflow_Instance__c inst = loadInstance(instanceId);
        if (inst == null || String.isBlank(inst.Current_State__c)) return false;

        WorkflowContract.Workflow wf = loadContract(inst.Workflow_Definition__c);
        if (wf == null) return false;

        WorkflowContract.State phase = wf.getState(inst.Current_State__c);
        if (phase == null) return false;
        if (phase.actions == null || phase.actions.isEmpty()) {
            // No declarative actions in this phase — treat as complete so
            // legacy phases with only transitions still work.
            return true;
        }

        Map<String, Workflow_Action__c> existing = loadExistingActions(instanceId, inst.Current_State__c);
        for (WorkflowContract.ActionDef def : phase.actions) {
            Boolean required = def.required != false; // default true
            if (!required) continue;
            Workflow_Action__c row = existing.get(def.key);
            if (row == null) return false;
            if (!TERMINAL_SUCCESS.contains(row.Status__c)) return false;
        }
        return true;
    }

    // ── Helpers ───────────────────────────────────────────────────────

    private static Workflow_Instance__c loadInstance(Id id) {
        List<Workflow_Instance__c> rows = [
            SELECT Id, Current_State__c, Workflow_Definition__c, Pinned_Version__c,
                   Parent_Object_Type__c, Parent_Record_Id__c, CreatedById
            FROM Workflow_Instance__c WHERE Id = :id LIMIT 1
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

    private static Map<String, Workflow_Action__c> loadExistingActions(Id instanceId, String phaseKey) {
        Map<String, Workflow_Action__c> byKey = new Map<String, Workflow_Action__c>();
        for (Workflow_Action__c wa : [
            SELECT Id, Action_Key__c, Status__c, Phase_Key__c
            FROM Workflow_Action__c
            WHERE Workflow_Instance__c = :instanceId
              AND Phase_Key__c = :phaseKey
              AND Action_Key__c != null
        ]) {
            byKey.put(wa.Action_Key__c, wa);
        }
        return byKey;
    }

    private static Boolean dependenciesSatisfied(
        WorkflowContract.ActionDef def,
        Map<String, String> existingStatusByKey
    ) {
        if (def.dependsOn == null || def.dependsOn.isEmpty()) return true;
        for (String depKey : def.dependsOn) {
            String status = existingStatusByKey.get(depKey);
            if (status == null) return false;
            if (!TERMINAL_SUCCESS.contains(status)) return false;
        }
        return true;
    }

    private static Workflow_Action__c buildRecord(
        Workflow_Instance__c inst,
        WorkflowContract.State phase,
        WorkflowContract.ActionDef def
    ) {
        String toolKey = null;
        String hitlPolicy = 'Approval_Required';
        String requestJson = null;

        if (def.config != null) {
            Object tk = def.config.get('toolKey');
            if (tk instanceof String) toolKey = (String) tk;
            Object hp = def.config.get('hitlPolicy');
            if (hp instanceof String) hitlPolicy = (String) hp;
            Object req = def.config.get('requestTemplate');
            if (req instanceof Map<String, Object>) {
                requestJson = JSON.serialize(req);
            } else if (req instanceof String) {
                requestJson = (String) req;
            }
        }

        Workflow_Action__c rec = new Workflow_Action__c(
            Workflow_Instance__c   = inst.Id,
            Action_Key__c          = def.key,
            Phase_Key__c           = phase.key,
            Label__c               = def.label != null ? def.label : def.key,
            Action_Type__c         = actionTypeForStorage(def.actionType),
            Tool_Key__c            = toolKey,
            HITL_Policy__c         = hitlPolicy,
            Status__c              = 'Pending',
            Required_For_Phase__c  = def.required != false,
            Sequence__c            = def.sequence,
            Depends_On_Actions__c  = (def.dependsOn == null || def.dependsOn.isEmpty())
                                        ? null
                                        : JSON.serialize(def.dependsOn),
            Request_JSON__c        = requestJson
        );

        // When the contract declares a status machine, seed the canonical
        // Status_Key__c + Status_Category__c from resolveInitialStatus().
        // Legacy Status__c stays 'Pending' for back-compat with the picklist.
        if (def.statuses != null && !def.statuses.isEmpty()) {
            WorkflowContract.StatusDef initial = def.resolveInitialStatus();
            if (initial != null) {
                if (String.isNotBlank(initial.key)) {
                    rec.Status_Key__c = initial.key;
                }
                if (String.isNotBlank(initial.category)) {
                    rec.Status_Category__c = initial.category;
                }
            }
        }

        // ── Resolve the assignmentRule ─────────────────────────────
        // Default: 'workflow_owner' — route to the user who created the
        // instance (fallback to the running user). Other types opt in via
        // the contract's action.assignmentRule block.
        applyAssignment(rec, inst, def);

        return rec;
    }

    /**
     * Populate Assigned_User__c or Assigned_To_Group__c based on the
     * action's declarative assignmentRule. Safe against missing config.
     */
    @TestVisible
    private static void applyAssignment(
        Workflow_Action__c rec,
        Workflow_Instance__c inst,
        WorkflowContract.ActionDef def
    ) {
        Map<String, Object> rule = def.assignmentRule;
        String ruleType = 'workflow_owner';
        if (rule != null && rule.get('type') instanceof String) {
            ruleType = (String) rule.get('type');
        }

        if (ruleType == 'workflow_owner') {
            rec.Assigned_User__c = inst.CreatedById != null
                ? inst.CreatedById
                : UserInfo.getUserId();
            return;
        }
        if (ruleType == 'user') {
            if (rule != null && rule.get('userId') instanceof String) {
                String uid = (String) rule.get('userId');
                if (String.isNotBlank(uid)) {
                    try { rec.Assigned_User__c = (Id) uid; } catch (Exception e) {}
                }
            }
            return;
        }
        if (ruleType == 'parent_owner') {
            Id ownerId = resolveParentOwnerId(inst);
            if (ownerId != null) {
                // Parent OwnerId may be a User or a Group (queue); route
                // to the matching lookup field.
                String prefix = String.valueOf(ownerId).substring(0, 3);
                if (prefix == '005') {
                    rec.Assigned_User__c = ownerId;
                } else if (prefix == '00G') {
                    rec.Assigned_To_Group__c = ownerId;
                }
            }
            return;
        }
        if (ruleType == 'group') {
            if (rule == null) return;
            Id gid = null;
            if (rule.get('groupId') instanceof String) {
                try { gid = (Id) (String) rule.get('groupId'); } catch (Exception e) {}
            }
            if (gid == null && rule.get('groupName') instanceof String) {
                String gname = (String) rule.get('groupName');
                if (String.isNotBlank(gname)) {
                    List<Group> gs = [
                        SELECT Id FROM Group
                        WHERE DeveloperName = :gname OR Name = :gname
                        LIMIT 1
                    ];
                    if (!gs.isEmpty()) gid = gs[0].Id;
                }
            }
            if (gid != null) rec.Assigned_To_Group__c = gid;
            return;
        }
    }

    /**
     * Look up OwnerId on the parent record when the parent SObject
     * supports OwnerId. Returns null if the object lacks OwnerId, the
     * record id is blank, or the record isn't accessible.
     */
    private static Id resolveParentOwnerId(Workflow_Instance__c inst) {
        if (inst == null) return null;
        String parentType = inst.Parent_Object_Type__c;
        String parentRecId = inst.Parent_Record_Id__c;
        if (String.isBlank(parentType) || String.isBlank(parentRecId)) return null;

        Schema.SObjectType sot = Schema.getGlobalDescribe().get(parentType);
        if (sot == null) return null;

        Schema.DescribeSObjectResult dsr = sot.getDescribe();
        if (!dsr.fields.getMap().containsKey('OwnerId')) return null;

        String soql = 'SELECT Id, OwnerId FROM ' + String.escapeSingleQuotes(parentType) +
                      ' WHERE Id = :parentRecId LIMIT 1';
        try {
            List<SObject> rows = Database.query(soql);
            if (rows.isEmpty()) return null;
            return (Id) rows[0].get('OwnerId');
        } catch (Exception e) {
            return null;
        }
    }

    private static String actionTypeForStorage(String contractActionType) {
        // Map contract types to the existing Action_Type__c picklist values.
        // Picklist today: Approval | Task | AI_Tool_Call. Form/auto/wait
        // map to Task for now; we'll expand the picklist if those types
        // need distinct runtime behavior later.
        if (contractActionType == 'ai_tool')  return 'AI_Tool_Call';
        if (contractActionType == 'approval') return 'Approval';
        return 'Task';
    }
}
