/**
 * Aura-enabled controller for end-user runtime surfaces.
 * Bridges the record-page LWCs (pulseRecordStepper, pulseActionHub) to
 * WorkflowRuntime and HitlService.
 */
global with sharing class PulseRuntimeController {

    // ─── View DTOs ──────────────────────────────────────────────

    global class InstanceView {
        @AuraEnabled public Id       instanceId;
        @AuraEnabled public String   workflowKey;
        @AuraEnabled public String   workflowName;
        @AuraEnabled public String   currentStateKey;
        @AuraEnabled public String   currentStateLabel;
        @AuraEnabled public String   currentStateType;
        @AuraEnabled public String   status;
        @AuraEnabled public List<SignalView> availableSignals;
        @AuraEnabled public List<StepView>   history;
        @AuraEnabled public Integer  pendingActionCount;
        // ── Phase/actions model (new) ──────────────────────────────
        @AuraEnabled public List<PhaseActionView> phaseActions;
        @AuraEnabled public String   phaseAdvancement;   // 'auto' | 'manual_decision'
        @AuraEnabled public Boolean  phaseComplete;
    }

    global class PhaseActionView {
        @AuraEnabled public Id       actionId;
        @AuraEnabled public String   actionKey;
        @AuraEnabled public String   phaseKey;
        @AuraEnabled public String   label;
        @AuraEnabled public String   actionType;       // AI_Tool_Call | Approval | Task
        @AuraEnabled public String   toolKey;
        @AuraEnabled public String   hitlPolicy;
        @AuraEnabled public String   requestJson;
        @AuraEnabled public String   status;           // Pending | Executed | Rejected | Failed | Cancelled
        @AuraEnabled public Boolean  required;
        @AuraEnabled public Boolean  blocked;          // deps not yet complete
        @AuraEnabled public List<String> dependsOn;
        @AuraEnabled public Integer  sequence;
        @AuraEnabled public Datetime requestedDate;
        @AuraEnabled public String   requestedByName;
        @AuraEnabled public Datetime resolvedDate;
    }

    global class SignalView {
        @AuraEnabled public String signal;
        @AuraEnabled public String targetStateKey;
        @AuraEnabled public String targetStateLabel;
    }

    global class StepView {
        @AuraEnabled public Id       stepResultId;
        @AuraEnabled public String   stateKey;
        @AuraEnabled public String   stateLabel;
        @AuraEnabled public String   signal;
        @AuraEnabled public String   outcome;
        @AuraEnabled public String   actorType;
        @AuraEnabled public Id       actorUserId;
        @AuraEnabled public Datetime startedAt;
        @AuraEnabled public Datetime completedAt;
    }

    global class AdvanceView {
        @AuraEnabled public Boolean      success;
        @AuraEnabled public Boolean      idempotent;
        @AuraEnabled public String       error;
        @AuraEnabled public String       fromStateKey;
        @AuraEnabled public String       toStateKey;
        @AuraEnabled public InstanceView refreshed;
    }

    global class ActionView {
        @AuraEnabled public Id       actionId;
        @AuraEnabled public String   toolKey;
        @AuraEnabled public String   hitlPolicy;
        @AuraEnabled public String   requestJson;
        @AuraEnabled public Datetime requestedDate;
        @AuraEnabled public String   requestedByName;
    }

    global class ActionResolveResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String  resultStatus;
        @AuraEnabled public String  message;
    }

    // ─── getInstanceForRecord ───────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static InstanceView getInstanceForRecord(Id recordId) {
        if (recordId == null) {
            return null;
        }

        List<Workflow_Instance__c> instances = [
            SELECT Id, Current_State__c, Status__c, Pinned_Version__c,
                   Workflow_Definition__c,
                   Workflow_Definition__r.Name,
                   Workflow_Definition__r.Workflow_Key__c,
                   Workflow_Definition__r.Definition_JSON__c
            FROM Workflow_Instance__c
            WHERE Parent_Record_Id__c = :recordId
              AND Status__c = 'Active'
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];

        if (instances.isEmpty()) {
            return null;
        }

        Workflow_Instance__c inst = instances[0];
        return buildInstanceView(inst);
    }

    // ─── advanceInstance ────────────────────────────────────────

    @AuraEnabled
    public static AdvanceView advanceInstance(
        Id instanceId, String signal, String payloadJson, String idempotencyKey
    ) {
        AdvanceView view = new AdvanceView();

        if (instanceId == null || String.isBlank(signal)) {
            view.success = false;
            view.error = 'instanceId and signal are required';
            return view;
        }

        WorkflowAdvanceRequest req = new WorkflowAdvanceRequest(instanceId, signal);
        req.payloadJson = payloadJson;
        req.idempotencyKey = idempotencyKey;
        req.actorType = 'Human';
        req.actorUserId = UserInfo.getUserId();

        List<WorkflowRuntime.AdvanceResult> results = WorkflowRuntime.advance(
            new List<WorkflowAdvanceRequest>{ req }
        );

        WorkflowRuntime.AdvanceResult result = results[0];
        view.success = result.success;
        view.idempotent = result.idempotent;
        view.error = result.error;
        view.fromStateKey = result.fromState;
        view.toStateKey = result.toState;

        if (result.success) {
            // Re-fetch the instance to build a refreshed view
            List<Workflow_Instance__c> refreshed = [
                SELECT Id, Current_State__c, Status__c, Pinned_Version__c,
                       Workflow_Definition__c,
                       Workflow_Definition__r.Name,
                       Workflow_Definition__r.Workflow_Key__c,
                       Workflow_Definition__r.Definition_JSON__c
                FROM Workflow_Instance__c
                WHERE Id = :instanceId
                LIMIT 1
            ];
            if (!refreshed.isEmpty()) {
                view.refreshed = buildInstanceView(refreshed[0]);
            }
        }

        return view;
    }

    // ─── getPendingActions ──────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static List<ActionView> getPendingActions(Id instanceId) {
        List<ActionView> views = new List<ActionView>();
        if (instanceId == null) {
            return views;
        }

        for (Workflow_Action__c a : [
            SELECT Id, Tool_Key__c, HITL_Policy__c, Request_JSON__c,
                   CreatedDate, CreatedBy.Name
            FROM Workflow_Action__c
            WHERE Workflow_Instance__c = :instanceId
              AND Status__c = 'Pending'
            ORDER BY CreatedDate ASC
        ]) {
            ActionView av = new ActionView();
            av.actionId = a.Id;
            av.toolKey = a.Tool_Key__c;
            av.hitlPolicy = a.HITL_Policy__c;
            av.requestJson = a.Request_JSON__c;
            av.requestedDate = a.CreatedDate;
            av.requestedByName = a.CreatedBy.Name;
            views.add(av);
        }
        return views;
    }

    // ─── resolveAction ──────────────────────────────────────────

    /**
     * Resolve a pending HITL action. When decision = 'Approve' and
     * `refinedPayloadJson` is non-blank, the action's Request_JSON__c
     * is replaced with the refined value before execution — the
     * "manager edited the draft" flow. Pass null to approve/reject as-is.
     */
    @AuraEnabled
    public static ActionResolveResult resolveAction(
        Id actionId, String decision, String notes, String refinedPayloadJson
    ) {
        ActionResolveResult result = new ActionResolveResult();

        if (actionId == null || String.isBlank(decision)) {
            result.success = false;
            result.message = 'actionId and decision are required';
            return result;
        }

        Boolean approved = decision == 'Approve';
        if (!approved && decision != 'Reject') {
            result.success = false;
            result.message = 'decision must be Approve or Reject';
            return result;
        }

        try {
            PulseToolModels.Result toolResult = HitlService.resolveApproval(
                actionId, approved, UserInfo.getUserId(), refinedPayloadJson
            );
            result.success = toolResult.success;
            if (toolResult.success) {
                result.resultStatus = approved ? 'Executed' : 'Rejected';
                result.message = approved ? 'Action approved and executed' : 'Action rejected';
            } else {
                result.resultStatus = 'Failed';
                result.message = toolResult.errorMessage;
            }
        } catch (Exception e) {
            result.success = false;
            result.resultStatus = 'Failed';
            result.message = e.getMessage();
        }

        return result;
    }

    // ─── Private helpers ────────────────────────────────────────

    private static InstanceView buildInstanceView(Workflow_Instance__c inst) {
        InstanceView view = new InstanceView();
        view.instanceId = inst.Id;
        view.status = inst.Status__c;
        view.currentStateKey = inst.Current_State__c;

        // Parse definition contract
        WorkflowContract.Workflow wf = null;
        if (inst.Workflow_Definition__r != null &&
            String.isNotBlank(inst.Workflow_Definition__r.Definition_JSON__c)) {
            try {
                wf = WorkflowContract.parse(inst.Workflow_Definition__r.Definition_JSON__c);
            } catch (Exception e) {
                // Gracefully degrade — show instance without contract details
            }
        }

        if (wf != null) {
            view.workflowKey = wf.workflowKey;
            view.workflowName = inst.Workflow_Definition__r.Name;

            WorkflowContract.State currentState = wf.getState(inst.Current_State__c);
            if (currentState != null) {
                view.currentStateLabel = currentState.label;
                view.currentStateType = currentState.stateType;

                // Available signals from transitions
                view.availableSignals = new List<SignalView>();
                if (currentState.transitions != null) {
                    for (WorkflowContract.Transition t : currentState.transitions) {
                        SignalView sv = new SignalView();
                        sv.signal = t.signal;
                        sv.targetStateKey = t.target;
                        WorkflowContract.State targetState = wf.getState(t.target);
                        sv.targetStateLabel = (targetState != null) ? targetState.label : t.target;
                        view.availableSignals.add(sv);
                    }
                }
            }
        } else {
            view.workflowName = inst.Workflow_Definition__r != null
                ? inst.Workflow_Definition__r.Name : 'Unknown';
            view.availableSignals = new List<SignalView>();
        }

        // Step history
        view.history = new List<StepView>();
        for (Workflow_Step_Result__c sr : [
            SELECT Id, State_Key__c, Signal__c, Outcome__c, Actor_Type__c,
                   Actor_User__c, Started_Date__c, Completed_Date__c
            FROM Workflow_Step_Result__c
            WHERE Workflow_Instance__c = :inst.Id
            ORDER BY Completed_Date__c ASC
        ]) {
            StepView sv = new StepView();
            sv.stepResultId = sr.Id;
            sv.stateKey = sr.State_Key__c;
            sv.signal = sr.Signal__c;
            sv.outcome = sr.Outcome__c;
            sv.actorType = sr.Actor_Type__c;
            sv.actorUserId = sr.Actor_User__c;
            sv.startedAt = sr.Started_Date__c;
            sv.completedAt = sr.Completed_Date__c;

            // Resolve label from contract
            if (wf != null) {
                WorkflowContract.State stepState = wf.getState(sr.State_Key__c);
                sv.stateLabel = (stepState != null) ? stepState.label : sr.State_Key__c;
            } else {
                sv.stateLabel = sr.State_Key__c;
            }
            view.history.add(sv);
        }

        // Pending action count
        view.pendingActionCount = [
            SELECT COUNT()
            FROM Workflow_Action__c
            WHERE Workflow_Instance__c = :inst.Id
              AND Status__c = 'Pending'
        ];

        // Phase + actions for the current state
        view.phaseActions = buildPhaseActions(inst, wf);
        WorkflowContract.State curStateForAdv = wf != null ? wf.getState(inst.Current_State__c) : null;
        view.phaseAdvancement = curStateForAdv != null ? curStateForAdv.effectiveAdvancement() : null;
        view.phaseComplete    = PulseActionInstantiationService.phaseComplete(inst.Id);

        return view;
    }

    private static List<PhaseActionView> buildPhaseActions(
        Workflow_Instance__c inst,
        WorkflowContract.Workflow wf
    ) {
        List<PhaseActionView> out = new List<PhaseActionView>();
        if (inst == null || String.isBlank(inst.Current_State__c)) return out;

        WorkflowContract.State phase = wf != null ? wf.getState(inst.Current_State__c) : null;
        if (phase == null || phase.actions == null || phase.actions.isEmpty()) return out;

        // Load all action rows for this phase (any status) so the UI can
        // show completed + pending + rejected side by side.
        Map<String, Workflow_Action__c> rowByKey = new Map<String, Workflow_Action__c>();
        for (Workflow_Action__c a : [
            SELECT Id, Action_Key__c, Phase_Key__c, Label__c, Action_Type__c,
                   Tool_Key__c, HITL_Policy__c, Request_JSON__c, Status__c,
                   Required_For_Phase__c, Sequence__c, Depends_On_Actions__c,
                   CreatedDate, Resolved_Date__c, CreatedBy.Name
            FROM Workflow_Action__c
            WHERE Workflow_Instance__c = :inst.Id
              AND Phase_Key__c = :inst.Current_State__c
              AND Action_Key__c != null
        ]) {
            rowByKey.put(a.Action_Key__c, a);
        }

        // Build view in contract-defined order so deterministic UI.
        Set<String> terminalSuccess = new Set<String>{ 'Executed' };
        for (WorkflowContract.ActionDef def : phase.actions) {
            PhaseActionView v = new PhaseActionView();
            v.actionKey  = def.key;
            v.phaseKey   = phase.key;
            v.label      = def.label != null ? def.label : def.key;
            v.required   = def.required != false;
            v.dependsOn  = def.dependsOn != null ? def.dependsOn : new List<String>();
            v.sequence   = def.sequence;

            Workflow_Action__c row = rowByKey.get(def.key);
            if (row != null) {
                v.actionId       = row.Id;
                v.actionType     = row.Action_Type__c;
                v.toolKey        = row.Tool_Key__c;
                v.hitlPolicy     = row.HITL_Policy__c;
                v.requestJson    = row.Request_JSON__c;
                v.status         = row.Status__c;
                v.requestedDate  = row.CreatedDate;
                v.requestedByName= row.CreatedBy != null ? row.CreatedBy.Name : null;
                v.resolvedDate   = row.Resolved_Date__c;
                v.blocked        = false;
            } else {
                // Row doesn't exist yet: determine whether it's blocked
                // on dependencies, or simply hasn't been instantiated.
                v.status      = 'Blocked';
                v.actionType  = actionTypeFromContractType(def.actionType);
                v.blocked     = true;
                // If deps ARE satisfied but row is missing, that means
                // instantiation should have happened — flag as "Ready"
                // so the UI shows it meaningfully.
                Boolean allDepsMet = true;
                if (def.dependsOn != null) {
                    for (String depKey : def.dependsOn) {
                        Workflow_Action__c depRow = rowByKey.get(depKey);
                        if (depRow == null || !terminalSuccess.contains(depRow.Status__c)) {
                            allDepsMet = false;
                            break;
                        }
                    }
                }
                if (allDepsMet) {
                    v.status  = 'Ready';
                    v.blocked = false;
                }
            }
            out.add(v);
        }
        return out;
    }

    private static String actionTypeFromContractType(String contractType) {
        if (contractType == 'ai_tool')  return 'AI_Tool_Call';
        if (contractType == 'approval') return 'Approval';
        return 'Task';
    }
}
