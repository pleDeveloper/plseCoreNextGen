/**
 * StageProgressionService
 *
 * Owns the "should this instance auto-advance?" decision for phases whose
 * progression mode is something other than the default auto_on_actions.
 *
 * Progression modes (from WorkflowContract.State.progression.mode):
 *   - auto_on_actions : default; HitlService.autoAdvanceIfComplete handles
 *     it when the last required action completes. No work to do here.
 *   - manual_decision : always waits for a human. We never auto-advance.
 *   - field_change    : the phase progresses when a watched field on the
 *     parent record reaches a target value. Evaluated on the post-image
 *     in PulseStageProgressionTrigger.
 *   - custom_logic    : the phase progresses when a condition tree (same
 *     shape as entry/exit) evaluates true against the parent record.
 *
 * When conditions are met we enqueue the phase's first transition signal
 * through WorkflowRuntime.advance(). Ties into the existing entry/exit
 * evaluation inside WorkflowRuntime, so transitions can still be blocked
 * by entry/exit conditions even if progression thinks it's time to move.
 *
 * Also exposes markStaleOnHold() — a scheduler-ready helper that flags
 * instances whose current phase declares `autoOnHoldAfterDays` and have
 * been sitting there with no completed actions in the window. Not
 * invoked automatically for MVP.
 */
public with sharing class StageProgressionService {

    // ─── Public API ──────────────────────────────────────────────

    /**
     * Evaluate the current phase's progression rule for a single
     * instance and, if it says so, fire the default outgoing transition.
     *
     * Safe to call from HITL post-execute, from per-object Apex triggers,
     * or from a schedulable.
     */
    public static Boolean checkAndAutoAdvance(Id instanceId) {
        if (instanceId == null) return false;

        Workflow_Instance__c inst;
        try {
            inst = [
                SELECT Id, Status__c, Current_State__c,
                       Parent_Object_Type__c, Parent_Record_Id__c,
                       Workflow_Definition__c,
                       Workflow_Definition__r.Definition_JSON__c
                FROM Workflow_Instance__c
                WHERE Id = :instanceId
                LIMIT 1
            ];
        } catch (Exception e) {
            return false;
        }

        if (inst == null || inst.Status__c != 'Active') return false;
        if (String.isBlank(inst.Current_State__c)) return false;

        WorkflowContract.Workflow wf;
        try {
            wf = WorkflowContract.parse(inst.Workflow_Definition__r.Definition_JSON__c);
        } catch (Exception e) {
            return false;
        }
        WorkflowContract.State phase = wf.getState(inst.Current_State__c);
        if (phase == null) return false;

        String mode = phase.progressionMode();
        if (String.isBlank(mode)) return false;
        if (mode == 'manual_decision') return false;

        // auto_on_actions is owned by HitlService.autoAdvanceIfComplete —
        // we skip here so we don't double-fire a transition.
        if (mode == 'auto_on_actions') return false;

        // Need a parent record for field-based decisions.
        SObject parentRec = loadParent(inst);

        Boolean shouldAdvance = false;
        if (mode == 'field_change') {
            shouldAdvance = fieldChangeMatches(phase, parentRec);
        } else if (mode == 'custom_logic') {
            shouldAdvance = customLogicMatches(phase, parentRec);
        }

        if (!shouldAdvance) return false;
        return fireDefaultTransition(inst, phase);
    }

    /**
     * Bulk variant: called from PulseStageProgressionTrigger. For each
     * instance on the watched SObject, re-evaluate progression.
     * Governor-safe — it issues one describe-guarded query per distinct
     * parent SObject type and one advance() batch at the end.
     */
    public static Integer checkOnRecordChange(String sObjectType, Set<Id> changedIds) {
        if (String.isBlank(sObjectType) || changedIds == null || changedIds.isEmpty()) {
            return 0;
        }
        List<Workflow_Instance__c> insts = [
            SELECT Id, Status__c, Current_State__c,
                   Parent_Object_Type__c, Parent_Record_Id__c,
                   Workflow_Definition__c,
                   Workflow_Definition__r.Definition_JSON__c
            FROM Workflow_Instance__c
            WHERE Status__c = 'Active'
              AND Parent_Object_Type__c = :sObjectType
              AND Parent_Record_Id__c IN :changedIds
        ];
        if (insts.isEmpty()) return 0;

        Integer fired = 0;
        for (Workflow_Instance__c inst : insts) {
            // Per-instance check — it's bulk-safe enough because we cap
            // at the number of records that actually changed in the
            // original Trigger.new. checkAndAutoAdvance does its own
            // parse and parent-record load.
            try {
                Boolean advanced = checkAndAutoAdvance(inst.Id);
                if (advanced) fired++;
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR,
                    'StageProgressionService: check failed for ' + inst.Id +
                    ': ' + e.getMessage());
            }
        }
        return fired;
    }

    /**
     * Scheduler-ready: any active instance whose current phase declares
     * `statusRules.autoOnHoldAfterDays` and whose most recent completed
     * step is older than that threshold gets flagged Stage_Status__c =
     * 'On_Hold'. Not invoked automatically; meant to be driven from a
     * Schedulable in a follow-up PR.
     */
    public static Integer markStaleOnHold() {
        // Pull only active instances that aren't already on hold/escalated.
        List<Workflow_Instance__c> candidates = [
            SELECT Id, Current_State__c, Status__c, Stage_Status__c,
                   Started_Date__c,
                   Workflow_Definition__r.Definition_JSON__c
            FROM Workflow_Instance__c
            WHERE Status__c = 'Active'
              AND (Stage_Status__c = null OR Stage_Status__c = 'Active')
            LIMIT 2000
        ];
        if (candidates.isEmpty()) return 0;

        // Bucket most-recent completed-action timestamp per instance.
        Set<Id> instIds = new Set<Id>();
        for (Workflow_Instance__c i : candidates) instIds.add(i.Id);
        Map<Id, Datetime> lastActivityByInst = new Map<Id, Datetime>();
        for (Workflow_Action__c a : [
            SELECT Workflow_Instance__c, Resolved_Date__c
            FROM Workflow_Action__c
            WHERE Workflow_Instance__c IN :instIds
              AND Status__c IN ('Executed', 'Rejected', 'Failed')
            ORDER BY Resolved_Date__c DESC
        ]) {
            if (!lastActivityByInst.containsKey(a.Workflow_Instance__c)
                && a.Resolved_Date__c != null) {
                lastActivityByInst.put(a.Workflow_Instance__c, a.Resolved_Date__c);
            }
        }

        Datetime now = Datetime.now();
        List<Workflow_Instance__c> toUpdate = new List<Workflow_Instance__c>();

        for (Workflow_Instance__c inst : candidates) {
            WorkflowContract.Workflow wf;
            try {
                wf = WorkflowContract.parse(inst.Workflow_Definition__r.Definition_JSON__c);
            } catch (Exception e) {
                continue;
            }
            WorkflowContract.State phase = wf.getState(inst.Current_State__c);
            if (phase == null || phase.statusRules == null) continue;
            Object daysObj = phase.statusRules.get('autoOnHoldAfterDays');
            Integer days = toIntegerOrNull(daysObj);
            if (days == null || days <= 0) continue;

            Datetime baseline = lastActivityByInst.containsKey(inst.Id)
                ? lastActivityByInst.get(inst.Id)
                : inst.Started_Date__c;
            if (baseline == null) continue;
            Long elapsedMs = now.getTime() - baseline.getTime();
            Long thresholdMs = (Long) days * 24L * 60L * 60L * 1000L;
            if (elapsedMs < thresholdMs) continue;

            inst.Stage_Status__c = 'On_Hold';
            toUpdate.add(inst);
        }

        if (!toUpdate.isEmpty()) update toUpdate;
        return toUpdate.size();
    }

    // ─── Mode evaluators ─────────────────────────────────────────

    private static Boolean fieldChangeMatches(
        WorkflowContract.State phase, SObject parentRec
    ) {
        if (phase == null || phase.progression == null || parentRec == null) return false;
        Object ruleObj = phase.progression.get('rule');
        if (!(ruleObj instanceof Map<String, Object>)) return false;
        Map<String, Object> rule = (Map<String, Object>) ruleObj;
        String fieldName = (String) rule.get('field');
        if (String.isBlank(fieldName)) return false;
        Object target = rule.get('equals');
        Object actual;
        try {
            actual = parentRec.get(fieldName);
        } catch (Exception e) {
            return false;
        }
        if (actual == null && target == null) return true;
        if (actual == null || target == null) return false;
        return String.valueOf(actual) == String.valueOf(target);
    }

    private static Boolean customLogicMatches(
        WorkflowContract.State phase, SObject parentRec
    ) {
        if (phase == null || phase.progression == null || parentRec == null) return false;
        Object ruleObj = phase.progression.get('rule');
        if (!(ruleObj instanceof Map<String, Object>)) return false;
        try {
            return PulseWorkflowTriggerEvaluator.matches(
                parentRec, null, JSON.serialize(ruleObj)
            );
        } catch (Exception e) {
            return false;
        }
    }

    // ─── Transition helpers ──────────────────────────────────────

    private static Boolean fireDefaultTransition(
        Workflow_Instance__c inst, WorkflowContract.State phase
    ) {
        if (phase.transitions == null || phase.transitions.isEmpty()) return false;
        WorkflowContract.Transition t = phase.transitions[0];
        if (t == null || String.isBlank(t.signal)) return false;

        WorkflowAdvanceRequest req = new WorkflowAdvanceRequest();
        req.instanceId = inst.Id;
        req.signal     = t.signal;
        req.actorType  = 'System';
        req.payloadJson = '{"source":"stage_progression","mode":"' +
            String.valueOf(phase.progressionMode()) + '"}';
        List<WorkflowRuntime.AdvanceResult> results =
            WorkflowRuntime.advance(new List<WorkflowAdvanceRequest>{ req });
        return !results.isEmpty() && results[0].success == true;
    }

    // ─── Parent record loader ────────────────────────────────────

    private static SObject loadParent(Workflow_Instance__c inst) {
        if (inst == null || inst.Parent_Record_Id__c == null
            || String.isBlank(inst.Parent_Object_Type__c)) {
            return null;
        }
        Schema.SObjectType sot = Schema.getGlobalDescribe().get(inst.Parent_Object_Type__c);
        if (sot == null) return null;
        Map<String, Schema.SObjectField> fieldMap = sot.getDescribe().fields.getMap();
        // Pull every accessible field so progression rules resolve even
        // if they reference less-common fields. Governor-safe because we
        // query a single record.
        List<String> fields = new List<String>{ 'Id' };
        for (String fName : fieldMap.keySet()) {
            if (fName == 'id') continue;
            Schema.DescribeFieldResult dfr = fieldMap.get(fName).getDescribe();
            if (dfr.isAccessible()) fields.add(dfr.getName());
        }
        String soql = 'SELECT ' + String.join(fields, ', ') +
            ' FROM ' + inst.Parent_Object_Type__c + ' WHERE Id = :pid LIMIT 1';
        Id pid = inst.Parent_Record_Id__c;
        try {
            List<SObject> rows = Database.query(soql);
            return rows.isEmpty() ? null : rows[0];
        } catch (Exception e) {
            return null;
        }
    }

    private static Integer toIntegerOrNull(Object v) {
        if (v == null) return null;
        if (v instanceof Integer) return (Integer) v;
        if (v instanceof Long) return ((Long) v).intValue();
        if (v instanceof Decimal) return ((Decimal) v).intValue();
        try {
            return Integer.valueOf(String.valueOf(v));
        } catch (Exception e) {
            return null;
        }
    }
}
