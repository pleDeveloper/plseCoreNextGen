/**
 * PulseWorkflowTriggerController
 *
 * AuraEnabled façade for the Admin Studio Triggers panel.
 * - listTriggers(workflowDefinitionId)
 * - upsertTrigger(payload) — inserts/updates + auto-provisions the Apex trigger
 * - deleteTrigger(triggerId)
 * - describeObjectFields(sObjectApiName) — for the field picker in the UI
 */
public with sharing class PulseWorkflowTriggerController {

    // ── Inner DTOs ────────────────────────────────────────────────────
    //
    // These DTOs are used only for OUTPUT (return values) — see the
    // upsertTrigger block below for why the input parameter accepts
    // Map<String, Object> and not the typed TriggerDto. listTriggers
    // returns List<TriggerDto> successfully because Aura's output
    // serialization of inner DTOs is not affected by this bug.

    public class TriggerDto {
        @AuraEnabled public Id     recordId;
        @AuraEnabled public Id     workflowDefinitionId;
        @AuraEnabled public String name;
        @AuraEnabled public String targetObject;
        @AuraEnabled public String eventType;
        @AuraEnabled public String conditionJson;
        @AuraEnabled public String initialStateKey;
        @AuraEnabled public Boolean active;
    }

    public class UpsertResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public Id      recordId;
        @AuraEnabled public String  triggerName;              // canonical Apex trigger on target
        @AuraEnabled public Boolean apexTriggerAlreadyExisted;
        @AuraEnabled public Boolean apexTriggerProvisioned;   // true if callout succeeded or trigger already present
        @AuraEnabled public String  provisioningMessage;
        @AuraEnabled public String  warning;                  // non-fatal problem (e.g. NC missing)
        @AuraEnabled public String  error;

        public UpsertResult() {
            this.success = false;
            this.apexTriggerAlreadyExisted = false;
            this.apexTriggerProvisioned = false;
        }
    }

    public class FieldInfo {
        @AuraEnabled public String apiName;
        @AuraEnabled public String label;
        @AuraEnabled public String fieldType;   // STRING, PICKLIST, DATE, DATETIME, BOOLEAN, CURRENCY, DOUBLE, INTEGER, etc.
        @AuraEnabled public Boolean nillable;
        @AuraEnabled public List<String> picklistValues;
    }

    // ── List ──────────────────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static List<TriggerDto> listTriggers(Id workflowDefinitionId) {
        List<TriggerDto> out = new List<TriggerDto>();
        if (workflowDefinitionId == null) return out;

        for (Workflow_Trigger__c t : [
            SELECT Id, Name, Workflow_Definition__c, Target_Object__c, Event_Type__c,
                   Condition_JSON__c, Initial_State_Key__c, Active__c
            FROM   Workflow_Trigger__c
            WHERE  Workflow_Definition__c = :workflowDefinitionId
            ORDER BY CreatedDate ASC
        ]) {
            TriggerDto d = new TriggerDto();
            d.recordId             = t.Id;
            d.workflowDefinitionId = t.Workflow_Definition__c;
            d.name                 = t.Name;
            d.targetObject         = t.Target_Object__c;
            d.eventType            = t.Event_Type__c;
            d.conditionJson        = t.Condition_JSON__c;
            d.initialStateKey      = t.Initial_State_Key__c;
            d.active               = t.Active__c;
            out.add(d);
        }
        return out;
    }

    // ── Upsert ────────────────────────────────────────────────────────
    //
    // IMPORTANT — public input signature is `Map<String, Object>`, NOT the
    // typed `TriggerDto`. In this namespaced scratch + any managed-package
    // installation, Aura's framework fails to deserialize an inbound JSON
    // object into a user-defined inner Apex class — it returns the opaque
    // "internal server error" / ID suffix `(-583189392)` envelope even
    // though the Apex method never runs. Demonstrated empirically by
    // driving /aura directly:
    //     V2 (typed DTO input, String output) → FAIL
    //     V3 (primitive inputs, String output) → SUCCESS
    //     V6 (typed DTO with String ids, String output) → FAIL
    //     V7 (Map<String,Object> input, String output) → SUCCESS
    //     minimal TestInputDto with 2 String fields → FAIL (not
    //                                                 specific to our class)
    // Accepting a Map and coercing to TriggerDto in Apex dodges the Aura
    // type-reflection path entirely. The RETURN type can stay as a typed
    // inner class — output serialization of inner DTOs works fine (proved
    // by listTriggers, which returns List<TriggerDto> successfully).
    @AuraEnabled
    public static UpsertResult upsertTrigger(Map<String, Object> payload) {
        try {
            TriggerDto dto = coerceToTriggerDto(payload);
            return upsertTriggerInternal(dto);
        } catch (Exception e) {
            UpsertResult out = new UpsertResult();
            out.success = false;
            out.error = e.getTypeName() + ': ' + e.getMessage();
            return out;
        }
    }

    @TestVisible
    private static TriggerDto coerceToTriggerDto(Map<String, Object> src) {
        TriggerDto d = new TriggerDto();
        if (src == null) return d;
        Object rid = src.get('recordId');
        if (rid != null && String.valueOf(rid) != '') d.recordId = (Id) String.valueOf(rid);
        Object wfid = src.get('workflowDefinitionId');
        if (wfid != null && String.valueOf(wfid) != '') d.workflowDefinitionId = (Id) String.valueOf(wfid);
        Object nm = src.get('name');
        if (nm != null) d.name = String.valueOf(nm);
        Object to = src.get('targetObject');
        if (to != null) d.targetObject = String.valueOf(to);
        Object et = src.get('eventType');
        if (et != null) d.eventType = String.valueOf(et);
        Object cj = src.get('conditionJson');
        if (cj != null) d.conditionJson = String.valueOf(cj);
        Object isk = src.get('initialStateKey');
        if (isk != null) d.initialStateKey = String.valueOf(isk);
        Object act = src.get('active');
        if (act instanceof Boolean) d.active = (Boolean) act;
        else if (act != null) d.active = Boolean.valueOf(String.valueOf(act));
        return d;
    }

    private static UpsertResult upsertTriggerInternal(TriggerDto payload) {
        UpsertResult out = new UpsertResult();

        if (payload == null) {
            out.success = false;
            out.error = 'payload is required';
            return out;
        }
        if (payload.workflowDefinitionId == null) {
            out.success = false;
            out.error = 'workflowDefinitionId is required';
            return out;
        }
        if (String.isBlank(payload.targetObject)) {
            out.success = false;
            out.error = 'targetObject is required';
            return out;
        }
        if (String.isBlank(payload.eventType)) {
            payload.eventType = 'Created_or_Updated';
        }
        if (payload.active == null) {
            payload.active = true;
        }
        String name = String.isNotBlank(payload.name)
            ? payload.name
            : defaultName(payload.targetObject, payload.eventType);

        // Provision the Apex trigger on the target object BEFORE DML so we
        // don't hit the "DML before callout" governor on first provision.
        // If provisioning fails (e.g. the Pulse_Self_Org_Tooling Named
        // Credential isn't configured in this org), we still save the
        // Workflow_Trigger__c row — the admin can manually create the
        // Apex trigger afterwards, and losing their form work is worse UX.
        // The result carries a warning so the LWC can surface it.
        PulseTriggerProvisioningService.ProvisionResult pr =
            PulseTriggerProvisioningService.ensureTriggerFor(payload.targetObject);
        out.triggerName               = pr.triggerName;
        out.apexTriggerAlreadyExisted = pr.alreadyExisted == true;
        out.apexTriggerProvisioned    = pr.success;
        out.provisioningMessage       = pr.message;
        if (!pr.success) {
            out.warning = pr.message;
        }

        Workflow_Trigger__c rec;
        if (payload.recordId != null) {
            rec = new Workflow_Trigger__c(
                Id                      = payload.recordId,
                Name                    = name,
                Workflow_Definition__c  = payload.workflowDefinitionId,
                Target_Object__c        = payload.targetObject,
                Event_Type__c           = payload.eventType,
                Condition_JSON__c       = payload.conditionJson,
                Initial_State_Key__c    = payload.initialStateKey,
                Active__c               = payload.active
            );
            update rec;
        } else {
            rec = new Workflow_Trigger__c(
                Name                    = name,
                Workflow_Definition__c  = payload.workflowDefinitionId,
                Target_Object__c        = payload.targetObject,
                Event_Type__c           = payload.eventType,
                Condition_JSON__c       = payload.conditionJson,
                Initial_State_Key__c    = payload.initialStateKey,
                Active__c               = payload.active
            );
            insert rec;
        }
        out.recordId = rec.Id;
        // Save succeeded even if provisioning warned; the UI shows the warning.
        out.success = true;
        return out;
    }

    // ── Delete ────────────────────────────────────────────────────────

    @AuraEnabled
    public static Boolean deleteTrigger(Id triggerId) {
        if (triggerId == null) return false;
        Workflow_Trigger__c t = new Workflow_Trigger__c(Id = triggerId);
        delete t;
        return true;
    }

    // ── Field describe ────────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static List<FieldInfo> describeObjectFields(String sObjectApiName) {
        List<FieldInfo> out = new List<FieldInfo>();
        if (String.isBlank(sObjectApiName)) return out;

        Schema.SObjectType sot = Schema.getGlobalDescribe().get(sObjectApiName);
        if (sot == null) return out;

        Map<String, Schema.SObjectField> fields = sot.getDescribe().fields.getMap();
        for (String key : fields.keySet()) {
            Schema.DescribeFieldResult d = fields.get(key).getDescribe();
            if (!d.isAccessible()) continue;
            FieldInfo fi = new FieldInfo();
            fi.apiName   = d.getName();
            fi.label     = d.getLabel();
            fi.fieldType = String.valueOf(d.getType());
            fi.nillable  = d.isNillable();
            if (d.getType() == Schema.DisplayType.PICKLIST) {
                fi.picklistValues = new List<String>();
                for (Schema.PicklistEntry pe : d.getPicklistValues()) {
                    if (pe.isActive()) fi.picklistValues.add(pe.getValue());
                }
            }
            out.add(fi);
        }
        return out;
    }

    // ── Helpers ───────────────────────────────────────────────────────

    private static String defaultName(String targetObject, String eventType) {
        String base = targetObject + ' ' + eventType;
        if (base.length() > 80) base = base.substring(0, 80);
        return base;
    }
}
