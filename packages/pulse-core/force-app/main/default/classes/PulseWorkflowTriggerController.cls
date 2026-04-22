/**
 * PulseWorkflowTriggerController
 *
 * AuraEnabled façade for the Admin Studio Triggers panel.
 * - listTriggers(workflowDefinitionId)
 * - upsertTrigger(payload) — inserts/updates + auto-provisions the Apex trigger
 * - deleteTrigger(triggerId)
 * - describeObjectFields(sObjectApiName) — for the field picker in the UI
 */
global with sharing class PulseWorkflowTriggerController {

    // ── Inner DTOs ────────────────────────────────────────────────────

    global class TriggerDto {
        @AuraEnabled public Id     recordId;
        @AuraEnabled public Id     workflowDefinitionId;
        @AuraEnabled public String name;
        @AuraEnabled public String targetObject;
        @AuraEnabled public String eventType;
        @AuraEnabled public String conditionJson;
        @AuraEnabled public String initialStateKey;
        @AuraEnabled public Boolean active;
    }

    global class UpsertResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public Id      recordId;
        @AuraEnabled public String  triggerName;              // canonical Apex trigger on target
        @AuraEnabled public Boolean apexTriggerAlreadyExisted;
        @AuraEnabled public Boolean apexTriggerProvisioned;   // true if callout succeeded or trigger already present
        @AuraEnabled public String  provisioningMessage;
        @AuraEnabled public String  warning;                  // non-fatal problem (e.g. NC missing)
        @AuraEnabled public String  error;
    }

    global class FieldInfo {
        @AuraEnabled public String apiName;
        @AuraEnabled public String label;
        @AuraEnabled public String fieldType;   // STRING, PICKLIST, DATE, DATETIME, BOOLEAN, CURRENCY, DOUBLE, INTEGER, etc.
        @AuraEnabled public Boolean nillable;
        @AuraEnabled public List<String> picklistValues;
    }

    // ── List ──────────────────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    global static List<TriggerDto> listTriggers(Id workflowDefinitionId) {
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

    @AuraEnabled
    global static UpsertResult upsertTrigger(TriggerDto payload) {
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
    global static Boolean deleteTrigger(Id triggerId) {
        if (triggerId == null) return false;
        Workflow_Trigger__c t = new Workflow_Trigger__c(Id = triggerId);
        delete t;
        return true;
    }

    // ── Field describe ────────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    global static List<FieldInfo> describeObjectFields(String sObjectApiName) {
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
