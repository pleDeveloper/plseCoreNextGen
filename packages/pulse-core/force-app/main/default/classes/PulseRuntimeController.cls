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
        // ── Per-phase field capture (new) ──────────────────────────
        @AuraEnabled public List<PhaseFieldView> phaseFields;
    }

    /**
     * Field definition for the current phase, combined with the current
     * value (from parent projection or Context_JSON__c) and any picklist
     * values if the projected target is a picklist. Returned alongside
     * InstanceView so the LWC can render an editable form.
     */
    global class PhaseFieldView {
        @AuraEnabled public String   key;
        @AuraEnabled public String   label;
        @AuraEnabled public String   fieldType;              // Text, Number, Date, DateTime, Picklist, Currency, Percent, LongTextArea, Checkbox
        @AuraEnabled public Boolean  required;
        @AuraEnabled public String   currentValue;           // serialized; null if not set
        @AuraEnabled public List<String> picklistValues;     // non-null only for Picklist
        @AuraEnabled public String   projectedFieldApiName;  // null if projection disabled or not mapped
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
                   Context_JSON__c, Parent_Record_Id__c, Parent_Object_Type__c,
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
                       Context_JSON__c, Parent_Record_Id__c, Parent_Object_Type__c,
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

    /**
     * Variant of advanceInstance that first saves phase field values into
     * the instance context + projected parent fields, then advances. Used
     * by the record-page form so the approver's captured values travel
     * with the phase transition.
     */
    @AuraEnabled
    public static AdvanceView advanceInstanceWithFields(
        Id instanceId, String signal, String payloadJson, String idempotencyKey,
        Map<String, Object> fieldValues
    ) {
        if (instanceId != null && fieldValues != null && !fieldValues.isEmpty()) {
            try {
                saveFieldValuesInternal(instanceId, fieldValues);
            } catch (Exception e) {
                AdvanceView err = new AdvanceView();
                err.success = false;
                err.error = 'Failed to save field values: ' + e.getMessage();
                return err;
            }
        }
        return advanceInstance(instanceId, signal, payloadJson, idempotencyKey);
    }

    // ─── saveFieldValues ────────────────────────────────────────

    /**
     * Save per-phase field values. Merges into Workflow_Instance__c.Context_JSON__c
     * and, for any field whose projection is enabled and mapped in
     * Workflow_Projection__mdt, writes to the parent record in a single
     * bulk DML via ProjectionWriteService. Returns the refreshed view.
     */
    @AuraEnabled
    public static InstanceView saveFieldValues(
        Id instanceId, Map<String, Object> values
    ) {
        if (instanceId == null) return null;
        saveFieldValuesInternal(instanceId, values);

        List<Workflow_Instance__c> refreshed = [
            SELECT Id, Current_State__c, Status__c, Pinned_Version__c,
                   Context_JSON__c, Parent_Record_Id__c, Parent_Object_Type__c,
                   Workflow_Definition__c,
                   Workflow_Definition__r.Name,
                   Workflow_Definition__r.Workflow_Key__c,
                   Workflow_Definition__r.Definition_JSON__c
            FROM Workflow_Instance__c
            WHERE Id = :instanceId
            LIMIT 1
        ];
        if (refreshed.isEmpty()) return null;
        return buildInstanceView(refreshed[0]);
    }

    private static void saveFieldValuesInternal(
        Id instanceId, Map<String, Object> values
    ) {
        if (instanceId == null || values == null || values.isEmpty()) return;

        List<Workflow_Instance__c> rows = [
            SELECT Id, Context_JSON__c, Parent_Record_Id__c, Parent_Object_Type__c,
                   Workflow_Definition__r.Workflow_Key__c,
                   Workflow_Definition__r.Definition_JSON__c,
                   Current_State__c
            FROM Workflow_Instance__c
            WHERE Id = :instanceId
            LIMIT 1
        ];
        if (rows.isEmpty()) return;
        Workflow_Instance__c inst = rows[0];

        // 1) Merge into Context_JSON__c (flat map of key → value).
        Map<String, Object> ctx;
        if (String.isNotBlank(inst.Context_JSON__c)) {
            try {
                ctx = (Map<String, Object>) JSON.deserializeUntyped(inst.Context_JSON__c);
            } catch (Exception e) {
                ctx = new Map<String, Object>();
            }
        } else {
            ctx = new Map<String, Object>();
        }
        for (String k : values.keySet()) {
            ctx.put(k, values.get(k));
        }
        inst.Context_JSON__c = JSON.serialize(ctx);
        update inst;

        // 2) For projection-enabled fields on the current phase, write
        //    through to the parent record via ProjectionWriteService.
        if (inst.Parent_Record_Id__c == null ||
            String.isBlank(inst.Parent_Object_Type__c)) return;

        WorkflowContract.Workflow wf;
        try {
            wf = WorkflowContract.parse(inst.Workflow_Definition__r.Definition_JSON__c);
        } catch (Exception e) {
            return;
        }
        WorkflowContract.State phase = wf != null ? wf.getState(inst.Current_State__c) : null;
        if (phase == null || phase.fields == null || phase.fields.isEmpty()) return;

        // Collect only fields that (a) the caller is submitting and
        // (b) are flagged projection.enabled in the contract.
        Map<String, String> projectable = new Map<String, String>();
        for (WorkflowContract.FieldDef fd : phase.fields) {
            if (fd.key == null || !values.containsKey(fd.key)) continue;
            if (fd.projection == null || fd.projection.enabled != true) continue;
            Object raw = values.get(fd.key);
            projectable.put(fd.key, raw == null ? null : String.valueOf(raw));
        }
        if (projectable.isEmpty()) return;

        ProjectionWriteService.ProjectionRequest req =
            new ProjectionWriteService.ProjectionRequest();
        req.parentRecordId     = inst.Parent_Record_Id__c;
        req.parentObjectType   = inst.Parent_Object_Type__c;
        req.workflowKey        = inst.Workflow_Definition__r.Workflow_Key__c;
        req.workflowInstanceId = inst.Id;
        req.fieldValues        = projectable;

        ProjectionWriteService.project(
            new List<ProjectionWriteService.ProjectionRequest>{ req }
        );
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

        // Per-phase editable fields (projection + context-backed)
        view.phaseFields = buildPhaseFields(inst, wf);

        return view;
    }

    /**
     * Build a list of PhaseFieldView for the current phase. Resolves the
     * current value from (a) parent record's projected field when the
     * projection is enabled + mapped, else (b) Context_JSON__c. Picklist
     * values are resolved via describe on the projected target field.
     */
    private static List<PhaseFieldView> buildPhaseFields(
        Workflow_Instance__c inst,
        WorkflowContract.Workflow wf
    ) {
        List<PhaseFieldView> out = new List<PhaseFieldView>();
        if (inst == null || wf == null || String.isBlank(inst.Current_State__c)) return out;

        WorkflowContract.State phase = wf.getState(inst.Current_State__c);
        if (phase == null || phase.fields == null || phase.fields.isEmpty()) return out;

        // Parse context once
        Map<String, Object> ctx = new Map<String, Object>();
        if (String.isNotBlank(inst.Context_JSON__c)) {
            try {
                ctx = (Map<String, Object>) JSON.deserializeUntyped(inst.Context_JSON__c);
            } catch (Exception e) {
                ctx = new Map<String, Object>();
            }
        }

        // Collect the set of field keys that want projection lookup + the
        // workflow key so we can resolve target fields in one CMDT query.
        Set<String> projectionKeys = new Set<String>();
        for (WorkflowContract.FieldDef fd : phase.fields) {
            if (fd.projection != null && fd.projection.enabled == true && fd.key != null) {
                projectionKeys.add(fd.key);
            }
        }

        Map<String, Workflow_Projection__mdt> projectionByFieldKey = new Map<String, Workflow_Projection__mdt>();
        if (!projectionKeys.isEmpty()) {
            String workflowKey = wf.workflowKey;
            // Workflow-scoped + shared (Workflow_Key__c = null) rows.
            for (Workflow_Projection__mdt p : [
                SELECT Field_Key__c, Target_Object__c, Target_Field__c,
                       Workflow_Key__c, Write_Precedence__c, Active__c
                FROM Workflow_Projection__mdt
                WHERE Active__c = TRUE
                  AND Field_Key__c IN :projectionKeys
                  AND (Workflow_Key__c = :workflowKey OR Workflow_Key__c = NULL)
            ]) {
                // Prefer workflow-scoped over shared; lower precedence wins.
                Workflow_Projection__mdt existing = projectionByFieldKey.get(p.Field_Key__c);
                if (existing == null) {
                    projectionByFieldKey.put(p.Field_Key__c, p);
                } else {
                    Boolean existingIsScoped = existing.Workflow_Key__c == workflowKey;
                    Boolean candidateIsScoped = p.Workflow_Key__c == workflowKey;
                    if (candidateIsScoped && !existingIsScoped) {
                        projectionByFieldKey.put(p.Field_Key__c, p);
                    } else if (candidateIsScoped == existingIsScoped) {
                        Decimal ep = existing.Write_Precedence__c != null ? existing.Write_Precedence__c : 99999;
                        Decimal cp = p.Write_Precedence__c        != null ? p.Write_Precedence__c        : 99999;
                        if (cp < ep) projectionByFieldKey.put(p.Field_Key__c, p);
                    }
                }
            }
        }

        // Load parent record once (only fields we need) to read projected
        // values. SOQL with dynamic SELECT list keyed by fields we care about.
        SObject parentRecord = null;
        if (!projectionByFieldKey.isEmpty()
            && inst.Parent_Record_Id__c != null
            && String.isNotBlank(inst.Parent_Object_Type__c)) {
            Set<String> parentFields = new Set<String>{ 'Id' };
            String parentObj = null;
            for (Workflow_Projection__mdt p : projectionByFieldKey.values()) {
                if (p.Target_Object__c == inst.Parent_Object_Type__c
                    && String.isNotBlank(p.Target_Field__c)) {
                    parentFields.add(p.Target_Field__c);
                    parentObj = p.Target_Object__c;
                }
            }
            if (parentObj != null && parentFields.size() > 1) {
                try {
                    String soql = 'SELECT ' + String.join(new List<String>(parentFields), ',')
                                + ' FROM ' + parentObj
                                + ' WHERE Id = :parentId LIMIT 1';
                    Id parentId = inst.Parent_Record_Id__c;
                    List<SObject> rs = Database.query(soql);
                    if (!rs.isEmpty()) parentRecord = rs[0];
                } catch (Exception e) {
                    // Degrade silently — fall back to context-only values.
                }
            }
        }

        // Global describe cache for picklist resolution
        Map<String, Schema.SObjectType> gd = Schema.getGlobalDescribe();

        for (WorkflowContract.FieldDef fd : phase.fields) {
            if (fd == null || String.isBlank(fd.key)) continue;
            PhaseFieldView v = new PhaseFieldView();
            v.key       = fd.key;
            v.label     = String.isNotBlank(fd.label) ? fd.label : fd.key;
            v.fieldType = fd.fieldType != null ? fd.fieldType : 'Text';
            v.required  = fd.required == true;

            Workflow_Projection__mdt proj = projectionByFieldKey.get(fd.key);
            Object currentVal = null;
            if (proj != null) {
                v.projectedFieldApiName = proj.Target_Field__c;
                // Prefer the projected parent value when present.
                if (parentRecord != null
                    && proj.Target_Object__c == inst.Parent_Object_Type__c
                    && String.isNotBlank(proj.Target_Field__c)) {
                    try {
                        currentVal = parentRecord.get(proj.Target_Field__c);
                    } catch (Exception e) {
                        currentVal = null;
                    }
                }
                // Picklist options (only if target happens to be a picklist)
                if ('Picklist'.equalsIgnoreCase(v.fieldType)
                    && gd.containsKey(proj.Target_Object__c)) {
                    Schema.DescribeSObjectResult od =
                        gd.get(proj.Target_Object__c).getDescribe();
                    Map<String, Schema.SObjectField> fmap = od.fields.getMap();
                    if (fmap.containsKey(proj.Target_Field__c.toLowerCase())) {
                        Schema.DescribeFieldResult fdesc =
                            fmap.get(proj.Target_Field__c.toLowerCase()).getDescribe();
                        if (fdesc.getType() == Schema.DisplayType.PICKLIST) {
                            v.picklistValues = new List<String>();
                            for (Schema.PicklistEntry pe : fdesc.getPicklistValues()) {
                                if (pe.isActive()) v.picklistValues.add(pe.getValue());
                            }
                        }
                    }
                }
            }
            if (currentVal == null && ctx.containsKey(fd.key)) {
                currentVal = ctx.get(fd.key);
            }
            v.currentValue = serializeFieldValue(currentVal);
            out.add(v);
        }
        return out;
    }

    private static String serializeFieldValue(Object val) {
        if (val == null) return null;
        if (val instanceof Boolean) return ((Boolean) val) ? 'true' : 'false';
        if (val instanceof Date)     return String.valueOf((Date) val);
        if (val instanceof Datetime) return ((Datetime) val).format('yyyy-MM-dd\'T\'HH:mm:ss');
        return String.valueOf(val);
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
