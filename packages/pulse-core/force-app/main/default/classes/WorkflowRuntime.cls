/**
 * Bulk runtime transition engine for Pulse workflow instances.
 * Validates signals against the pinned contract definition, persists step results
 * and audit events, and fires registered extension hooks.
 *
 * Governor-safe for 200 records: all SOQL and DML are bulk-collected outside loops.
 * No callouts.
 */
public with sharing class WorkflowRuntime {

    // ─── Extension point for projection / AI hooks ───────────────
    //
    // Implement TransitionHook and call registerHook() to receive post-transition
    // callbacks. ProjectionWriteService and AI dispatch will plug in here.

    public interface TransitionHook {
        void afterTransitions(List<TransitionContext> contexts);
    }

    public class TransitionContext {
        public Id instanceId;
        public String fromStateKey;
        public String toStateKey;
        public Workflow_Step_Result__c stepResult;
        public String payloadJson;
    }

    @TestVisible
    private static List<TransitionHook> hooks = new List<TransitionHook>();

    // Auto-register StageDwellHook once per transaction so callers don't have to
    private static Boolean stageDwellRegistered = false;

    public static void registerHook(TransitionHook hook) {
        if (hook != null) {
            hooks.add(hook);
        }
    }

    public static void clearHooks() {
        hooks.clear();
    }

    // ─── Result DTO ──────────────────────────────────────────────

    public class AdvanceResult {
        public Id instanceId;
        public Boolean success;
        public Boolean idempotent;
        public String error;
        public String fromState;
        public String toState;

        public AdvanceResult(Id instanceId) {
            this.instanceId = instanceId;
            this.success = false;
            this.idempotent = false;
        }
    }

    // ─── Bulk entry point ────────────────────────────────────────

    public static List<AdvanceResult> advance(List<WorkflowAdvanceRequest> requests) {
        if (requests == null || requests.isEmpty()) {
            return new List<AdvanceResult>();
        }

        // Auto-register dwell-time hook + phase-action hook once per transaction
        if (!stageDwellRegistered) {
            StageDwellHook.register();
            PhaseActionHook.register();
            stageDwellRegistered = true;
        }

        // 1. Collect instance IDs
        Set<Id> instanceIds = new Set<Id>();
        for (WorkflowAdvanceRequest req : requests) {
            if (req.instanceId != null) {
                instanceIds.add(req.instanceId);
            }
        }

        // 2. Bulk load instances with pinned definitions
        Map<Id, Workflow_Instance__c> instanceMap = new Map<Id, Workflow_Instance__c>([
            SELECT Id, Current_State__c, Status__c, Pinned_Version__c, Context_JSON__c,
                   Parent_Object_Type__c, Parent_Record_Id__c,
                   Workflow_Definition__c,
                   Workflow_Definition__r.Definition_JSON__c,
                   Workflow_Definition__r.Status__c,
                   Workflow_Definition__r.Version__c
            FROM Workflow_Instance__c
            WHERE Id IN :instanceIds
        ]);

        // 3. Bulk load completed step results for idempotency guard
        Map<String, String> priorTransitions = buildPriorTransitions(instanceIds);

        // 4. Parse definitions once per unique definition Id
        Map<Id, WorkflowContract.Workflow> parsedDefs = new Map<Id, WorkflowContract.Workflow>();
        Map<Id, String> parseErrors = new Map<Id, String>();
        for (Workflow_Instance__c inst : instanceMap.values()) {
            Id defId = inst.Workflow_Definition__c;
            if (defId == null || parsedDefs.containsKey(defId) || parseErrors.containsKey(defId)) {
                continue;
            }
            try {
                WorkflowContract.Workflow wf = WorkflowContract.parse(
                    inst.Workflow_Definition__r.Definition_JSON__c
                );
                List<String> validationErrors = WorkflowContract.validate(wf);
                if (!validationErrors.isEmpty()) {
                    parseErrors.put(defId, 'Contract validation: ' + String.join(validationErrors, '; '));
                } else {
                    parsedDefs.put(defId, wf);
                }
            } catch (WorkflowContract.ContractParseException e) {
                parseErrors.put(defId, e.getMessage());
            }
        }

        // 5. Bulk-load parent records referenced by any instance so that
        //    entry/exit conditions can evaluate against the real record.
        Map<Id, SObject> parentRecordMap = loadParentRecords(
            instanceMap.values(), parsedDefs
        );

        // 6. Process each request — collect DML records
        List<AdvanceResult> results = new List<AdvanceResult>();
        List<Workflow_Step_Result__c> stepResultsToInsert = new List<Workflow_Step_Result__c>();
        List<Workflow_Event__c> eventsToInsert = new List<Workflow_Event__c>();
        Map<Id, Workflow_Instance__c> instancesToUpdate = new Map<Id, Workflow_Instance__c>();
        List<TransitionContext> hookContexts = new List<TransitionContext>();

        for (WorkflowAdvanceRequest req : requests) {
            AdvanceResult result = processRequest(
                req, instanceMap, parsedDefs, parseErrors, priorTransitions,
                parentRecordMap,
                stepResultsToInsert, eventsToInsert, instancesToUpdate, hookContexts
            );
            results.add(result);
        }

        // 7. Bulk DML
        if (!stepResultsToInsert.isEmpty()) {
            insert stepResultsToInsert;
        }
        if (!eventsToInsert.isEmpty()) {
            insert eventsToInsert;
        }
        if (!instancesToUpdate.isEmpty()) {
            update instancesToUpdate.values();
        }

        // 8. Fire extension hooks (projection writes, AI dispatch, etc.)
        if (!hooks.isEmpty() && !hookContexts.isEmpty()) {
            for (TransitionHook hook : hooks) {
                hook.afterTransitions(hookContexts);
            }
        }

        return results;
    }

    // ─── Per-request processing ──────────────────────────────────

    private static AdvanceResult processRequest(
        WorkflowAdvanceRequest req,
        Map<Id, Workflow_Instance__c> instanceMap,
        Map<Id, WorkflowContract.Workflow> parsedDefs,
        Map<Id, String> parseErrors,
        Map<String, String> priorTransitions,
        Map<Id, SObject> parentRecordMap,
        List<Workflow_Step_Result__c> stepResultsToInsert,
        List<Workflow_Event__c> eventsToInsert,
        Map<Id, Workflow_Instance__c> instancesToUpdate,
        List<TransitionContext> hookContexts
    ) {
        AdvanceResult result = new AdvanceResult(req.instanceId);

        if (req.instanceId == null || String.isBlank(req.signal)) {
            result.error = 'instanceId and signal are required';
            return result;
        }

        Workflow_Instance__c inst = instanceMap.get(req.instanceId);
        if (inst == null) {
            result.error = 'Instance not found';
            return result;
        }

        if (inst.Status__c != 'Active') {
            result.error = 'Instance is not active (status: ' + inst.Status__c + ')';
            return result;
        }

        Id defId = inst.Workflow_Definition__c;
        if (defId == null) {
            result.error = 'Instance has no linked definition';
            return result;
        }
        if (parseErrors.containsKey(defId)) {
            result.error = 'Definition error: ' + parseErrors.get(defId);
            return result;
        }
        WorkflowContract.Workflow wf = parsedDefs.get(defId);
        if (wf == null) {
            result.error = 'Definition could not be loaded';
            return result;
        }

        String currentStateKey = inst.Current_State__c;
        WorkflowContract.State currentState = wf.getState(currentStateKey);
        if (currentState == null) {
            result.error = 'Current state "' + currentStateKey + '" not found in contract';
            return result;
        }

        // Validate signal against current state transitions
        WorkflowContract.Transition transition = currentState.getTransition(req.signal);
        if (transition == null) {
            // Idempotency guard: was this signal already processed from a prior state?
            return checkIdempotencyOrFail(req, wf, currentStateKey, priorTransitions);
        }

        String targetStateKey = transition.target;
        WorkflowContract.State targetState = wf.getState(targetStateKey);
        if (targetState == null) {
            result.error = 'Target state "' + targetStateKey + '" not found in contract';
            return result;
        }

        // Evaluate exit (current phase) + entry (target phase) conditions
        // against the parent record. Blocks the transition if either fails.
        SObject parentRec = (parentRecordMap == null || inst.Parent_Record_Id__c == null)
            ? null
            : parentRecordMap.get(inst.Parent_Record_Id__c);
        String condErr = evaluatePhaseConditions(currentState, targetState, parentRec);
        if (condErr != null) {
            result.error = condErr;
            return result;
        }

        // Build step result
        Datetime now = Datetime.now();
        Workflow_Step_Result__c stepResult = new Workflow_Step_Result__c(
            Workflow_Instance__c = inst.Id,
            State_Key__c = currentStateKey,
            Signal__c = req.signal,
            Values_JSON__c = req.payloadJson,
            Actor_Type__c = String.isNotBlank(req.actorType) ? req.actorType : 'Human',
            Outcome__c = 'Completed',
            Started_Date__c = now,
            Completed_Date__c = now
        );
        if (req.actorUserId != null) {
            stepResult.Actor_User__c = req.actorUserId;
        }
        stepResultsToInsert.add(stepResult);

        // Build audit event
        Workflow_Event__c evt = new Workflow_Event__c(
            Workflow_Instance__c = inst.Id,
            Event_Type__c = 'Transition',
            Source_State__c = currentStateKey,
            Target_State__c = targetStateKey,
            Actor_Type__c = String.isNotBlank(req.actorType) ? req.actorType : 'Human',
            Detail_JSON__c = buildEventDetail(req)
        );
        if (req.actorUserId != null) {
            evt.Actor_User__c = req.actorUserId;
        }
        eventsToInsert.add(evt);

        // Update instance current state
        inst.Current_State__c = targetStateKey;
        if (targetState.stateType == 'terminal') {
            inst.Status__c = 'Completed';
            inst.Completed_Date__c = now;
        }
        instancesToUpdate.put(inst.Id, inst);

        // Build hook context for downstream consumers
        TransitionContext ctx = new TransitionContext();
        ctx.instanceId = inst.Id;
        ctx.fromStateKey = currentStateKey;
        ctx.toStateKey = targetStateKey;
        ctx.stepResult = stepResult;
        ctx.payloadJson = req.payloadJson;
        hookContexts.add(ctx);

        result.success = true;
        result.fromState = currentStateKey;
        result.toState = targetStateKey;
        return result;
    }

    // ─── Idempotency ─────────────────────────────────────────────

    private static Map<String, String> buildPriorTransitions(Set<Id> instanceIds) {
        Map<String, String> priorTransitions = new Map<String, String>();
        for (Workflow_Step_Result__c sr : [
            SELECT Workflow_Instance__c, State_Key__c, Signal__c
            FROM Workflow_Step_Result__c
            WHERE Workflow_Instance__c IN :instanceIds
              AND Outcome__c = 'Completed'
        ]) {
            // Key: instanceId:signal  Value: source state key
            priorTransitions.put(
                String.valueOf(sr.Workflow_Instance__c) + ':' + sr.Signal__c,
                sr.State_Key__c
            );
        }
        return priorTransitions;
    }

    private static AdvanceResult checkIdempotencyOrFail(
        WorkflowAdvanceRequest req,
        WorkflowContract.Workflow wf,
        String currentStateKey,
        Map<String, String> priorTransitions
    ) {
        AdvanceResult result = new AdvanceResult(req.instanceId);
        String priorKey = String.valueOf(req.instanceId) + ':' + req.signal;
        String priorStateKey = priorTransitions.get(priorKey);

        if (priorStateKey != null) {
            WorkflowContract.State priorState = wf.getState(priorStateKey);
            WorkflowContract.Transition priorTrans = (priorState != null)
                ? priorState.getTransition(req.signal) : null;
            result.success = true;
            result.idempotent = true;
            result.fromState = priorStateKey;
            result.toState = (priorTrans != null) ? priorTrans.target : currentStateKey;
            return result;
        }

        result.error = 'Signal "' + req.signal + '" is not valid for state "' + currentStateKey + '"';
        return result;
    }

    // ─── Private helpers ─────────────────────────────────────────

    private static String buildEventDetail(WorkflowAdvanceRequest req) {
        Map<String, Object> detail = new Map<String, Object>();
        detail.put('signal', req.signal);
        if (String.isNotBlank(req.idempotencyKey)) {
            detail.put('idempotencyKey', req.idempotencyKey);
        }
        return JSON.serialize(detail);
    }

    // ─── Entry / exit condition evaluation ───────────────────────

    /**
     * Evaluate the current phase's exitConditions and the target phase's
     * entryConditions against the parent record. Returns null when both
     * pass (or are unset); otherwise returns the error string to surface
     * in AdvanceResult.error.
     */
    @TestVisible
    private static String evaluatePhaseConditions(
        WorkflowContract.State currentState,
        WorkflowContract.State targetState,
        SObject parentRec
    ) {
        if (currentState != null && currentState.exitConditions != null
            && !currentState.exitConditions.isEmpty()) {
            if (parentRec == null) {
                return 'Exit condition not met: parent record unavailable for phase "'
                    + currentState.key + '"';
            }
            Boolean pass;
            try {
                pass = PulseWorkflowTriggerEvaluator.matches(
                    parentRec, null, JSON.serialize(currentState.exitConditions)
                );
            } catch (Exception e) {
                return 'Exit condition error: ' + e.getMessage();
            }
            if (!pass) {
                return 'Exit condition not met for phase "' + currentState.key + '"';
            }
        }
        if (targetState != null && targetState.entryConditions != null
            && !targetState.entryConditions.isEmpty()) {
            if (parentRec == null) {
                return 'Entry condition not met: parent record unavailable for phase "'
                    + targetState.key + '"';
            }
            Boolean pass;
            try {
                pass = PulseWorkflowTriggerEvaluator.matches(
                    parentRec, null, JSON.serialize(targetState.entryConditions)
                );
            } catch (Exception e) {
                return 'Entry condition error: ' + e.getMessage();
            }
            if (!pass) {
                return 'Entry condition not met for phase "' + targetState.key + '"';
            }
        }
        return null;
    }

    /**
     * Bulk-load parent records referenced by the instance list. For each
     * distinct Parent_Object_Type__c we pull every field declared in any
     * contract rule so the evaluator has what it needs. Failures are
     * swallowed — condition evaluation treats missing records as failure.
     */
    @TestVisible
    private static Map<Id, SObject> loadParentRecords(
        List<Workflow_Instance__c> instances,
        Map<Id, WorkflowContract.Workflow> parsedDefs
    ) {
        Map<Id, SObject> out = new Map<Id, SObject>();
        if (instances == null || instances.isEmpty()) return out;

        // Determine which instances need loading (have any conditions at
        // all on current/target states) and group IDs by sObject type.
        Map<String, Set<Id>> idsByType = new Map<String, Set<Id>>();
        Map<String, Set<String>> fieldsByType = new Map<String, Set<String>>();

        for (Workflow_Instance__c inst : instances) {
            if (inst.Parent_Record_Id__c == null || String.isBlank(inst.Parent_Object_Type__c)) {
                continue;
            }
            WorkflowContract.Workflow wf = parsedDefs.get(inst.Workflow_Definition__c);
            if (wf == null) continue;

            Boolean anyCondition = false;
            Set<String> fields = new Set<String>{ 'Id' };
            if (wf.states != null) {
                for (WorkflowContract.State s : wf.states) {
                    if (s.entryConditions != null && !s.entryConditions.isEmpty()) {
                        anyCondition = true;
                        collectConditionFields(s.entryConditions, fields);
                    }
                    if (s.exitConditions != null && !s.exitConditions.isEmpty()) {
                        anyCondition = true;
                        collectConditionFields(s.exitConditions, fields);
                    }
                }
            }
            if (!anyCondition) continue;

            String t = inst.Parent_Object_Type__c;
            if (!idsByType.containsKey(t)) {
                idsByType.put(t, new Set<Id>());
                fieldsByType.put(t, new Set<String>());
            }
            idsByType.get(t).add(inst.Parent_Record_Id__c);
            fieldsByType.get(t).addAll(fields);
        }

        if (idsByType.isEmpty()) return out;

        // Describe + query per type, defensively filtering invalid fields.
        Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
        for (String type : idsByType.keySet()) {
            Schema.SObjectType sot = globalDescribe.get(type);
            if (sot == null) continue;
            Map<String, Schema.SObjectField> fieldMap = sot.getDescribe().fields.getMap();
            List<String> valid = new List<String>();
            for (String f : fieldsByType.get(type)) {
                if (fieldMap.containsKey(f.toLowerCase())) valid.add(f);
            }
            if (valid.isEmpty()) valid.add('Id');

            String soql = 'SELECT ' + String.join(valid, ', ') +
                ' FROM ' + type + ' WHERE Id IN :ids';
            Set<Id> ids = idsByType.get(type);
            try {
                for (SObject rec : Database.query(soql)) {
                    out.put((Id) rec.get('Id'), rec);
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'WorkflowRuntime: parent record query failed for ' + type +
                    ': ' + e.getMessage());
            }
        }
        return out;
    }

    private static void collectConditionFields(
        Map<String, Object> node, Set<String> out
    ) {
        if (node == null || node.isEmpty()) return;
        if (node.containsKey('field')) {
            Object f = node.get('field');
            if (f != null) out.add(String.valueOf(f));
        }
        Object rulesObj = node.get('rules');
        if (rulesObj instanceof List<Object>) {
            for (Object r : (List<Object>) rulesObj) {
                if (r instanceof Map<String, Object>) {
                    collectConditionFields((Map<String, Object>) r, out);
                }
            }
        }
    }
}
