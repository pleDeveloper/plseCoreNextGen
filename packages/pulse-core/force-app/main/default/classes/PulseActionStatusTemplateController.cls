/**
 * PulseActionStatusTemplateController
 *
 * AuraEnabled façade for the Admin Studio / Workflow Builder "Status
 * machine" editor.
 *
 *   listTemplates()                     — enumerate Action_Status_Template__mdt
 *   upsertTemplate(Map<String,Object>)  — deploy a new/updated template
 *
 * Input signature for upsertTemplate is Map<String, Object> rather than
 * a typed DTO. This dodges the Aura LWC→Apex deserialization failure
 * (generic internal-server-error envelope) empirically reproduced in
 * docs/diagnostics/aura-upsertTrigger-repro.sh. See
 * PulseWorkflowTriggerController.upsertTrigger + coerceToTriggerDto for
 * the matching pattern. Outputs CAN remain as typed inner classes
 * because Aura output serialization is unaffected.
 *
 * Deploy path uses Metadata.Operations.enqueueDeployment, mirroring
 * PulseGlobalActionHubController.upsertColumnConfig so admins never
 * need to hand-edit custom metadata XML.
 */
public with sharing class PulseActionStatusTemplateController {

    // ─── DTOs (output-only) ─────────────────────────────────────────

    public class TemplateView {
        @AuraEnabled public String developerName;
        @AuraEnabled public String templateKey;
        @AuraEnabled public String displayName;
        @AuraEnabled public String description;
        @AuraEnabled public String statusesJson;
    }

    public class UpsertResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public Id      deploymentJobId;
        @AuraEnabled public String  message;
    }

    /**
     * Internal coerced shape (not @AuraEnabled — never exposed to Aura).
     */
    public class TemplateInput {
        public String templateKey;
        public String displayName;
        public String description;
        public String statusesJson;
    }

    // ─── listTemplates ──────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static List<TemplateView> listTemplates() {
        List<TemplateView> out = new List<TemplateView>();
        for (Action_Status_Template__mdt t : [
            SELECT DeveloperName, MasterLabel,
                   Template_Key__c, Display_Name__c,
                   Description__c, Statuses_JSON__c
            FROM   Action_Status_Template__mdt
            ORDER BY MasterLabel ASC
        ]) {
            TemplateView v = new TemplateView();
            v.developerName = t.DeveloperName;
            v.templateKey   = String.isNotBlank(t.Template_Key__c)
                ? t.Template_Key__c : t.DeveloperName;
            v.displayName   = String.isNotBlank(t.Display_Name__c)
                ? t.Display_Name__c : t.MasterLabel;
            v.description   = t.Description__c;
            v.statusesJson  = t.Statuses_JSON__c;
            out.add(v);
        }
        return out;
    }

    // ─── upsertTemplate ─────────────────────────────────────────────

    @AuraEnabled
    public static UpsertResult upsertTemplate(Map<String, Object> payload) {
        UpsertResult res = new UpsertResult();
        try {
            TemplateInput input = coerceTemplateInput(payload);
            if (input == null || String.isBlank(input.templateKey)) {
                res.success = false;
                res.message = 'templateKey is required';
                return res;
            }
            if (String.isBlank(input.statusesJson)) {
                res.success = false;
                res.message = 'statusesJson is required';
                return res;
            }
            // Lightweight shape check: must parse to a non-empty array.
            try {
                Object parsed = JSON.deserializeUntyped(input.statusesJson);
                if (!(parsed instanceof List<Object>)
                    || ((List<Object>) parsed).isEmpty()) {
                    res.success = false;
                    res.message = 'statusesJson must be a non-empty array';
                    return res;
                }
            } catch (Exception je) {
                res.success = false;
                res.message = 'statusesJson is invalid JSON: ' + je.getMessage();
                return res;
            }

            String devName = toDeveloperName(input.templateKey);
            String label   = String.isNotBlank(input.displayName)
                ? input.displayName : input.templateKey.replace('_', ' ');

            Metadata.CustomMetadata cm = new Metadata.CustomMetadata();
            cm.fullName = 'Action_Status_Template.' + devName;
            cm.label    = label;

            cm.values.add(makeValue('Template_Key__c', input.templateKey));
            cm.values.add(makeValue('Display_Name__c',
                String.isNotBlank(input.displayName) ? input.displayName : label));
            if (input.description != null) {
                cm.values.add(makeValue('Description__c', input.description));
            }
            cm.values.add(makeValue('Statuses_JSON__c', input.statusesJson));

            Metadata.DeployContainer container = new Metadata.DeployContainer();
            container.addMetadata(cm);

            Id jobId = Metadata.Operations.enqueueDeployment(container, null);
            res.success = true;
            res.deploymentJobId = jobId;
            res.message = 'Deployment enqueued';
        } catch (Exception e) {
            res.success = false;
            res.message = e.getTypeName() + ': ' + e.getMessage();
        }
        return res;
    }

    // ─── Helpers ────────────────────────────────────────────────────

    @TestVisible
    private static TemplateInput coerceTemplateInput(Map<String, Object> raw) {
        TemplateInput out = new TemplateInput();
        if (raw == null) return out;

        Object k = raw.get('templateKey');
        if (k instanceof String) out.templateKey = (String) k;

        Object d = raw.get('displayName');
        if (d instanceof String) out.displayName = (String) d;

        Object descVal = raw.get('description');
        if (descVal instanceof String) out.description = (String) descVal;

        Object s = raw.get('statusesJson');
        if (s instanceof String) {
            out.statusesJson = (String) s;
        } else if (s != null) {
            // Allow clients to send an already-parsed list/map — re-serialize.
            out.statusesJson = JSON.serialize(s);
        }
        return out;
    }

    private static Metadata.CustomMetadataValue makeValue(String field, Object val) {
        Metadata.CustomMetadataValue v = new Metadata.CustomMetadataValue();
        v.field = field;
        v.value = val;
        return v;
    }

    private static String toDeveloperName(String raw) {
        if (String.isBlank(raw)) return 'Unnamed';
        String cleaned = raw.replaceAll('[^A-Za-z0-9_]', '_');
        while (cleaned.contains('__')) cleaned = cleaned.replace('__', '_');
        if (cleaned.startsWith('_')) cleaned = cleaned.substring(1);
        if (cleaned.endsWith('_'))   cleaned = cleaned.substring(0, cleaned.length() - 1);
        if (String.isBlank(cleaned)) cleaned = 'Unnamed';
        if (!Pattern.matches('[A-Za-z].*', cleaned)) cleaned = 'X_' + cleaned;
        return cleaned;
    }
}
