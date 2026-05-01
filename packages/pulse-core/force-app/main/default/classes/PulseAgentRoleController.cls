/**
 * PulseAgentRoleController
 *
 * AuraEnabled façade for the Admin Studio "Agent role library" panel.
 * Manages Agent_Role__mdt records via the Metadata API, mirroring the
 * pattern established by PulseEmailRouterController for routing rules.
 *
 *  - listRoles()                        — full list (active + inactive) for the library UI
 *  - listActiveRoleSummaries()          — cacheable, picker-shaped summary
 *                                         of active roles for the workflow
 *                                         builder role dropdown
 *  - upsertRole(Map<String,Object>)     — deploys an Agent_Role__mdt record
 *                                         via Metadata.Operations.enqueueDeployment
 *  - deleteRole(String developerName)   — soft delete (Active__c = false). The
 *                                         Apex Metadata API cannot remove CMDT
 *                                         records, so we deactivate.
 *  - getDeployStatus(String jobId)      — polls AsyncApexJob status for the UI.
 *
 * Mutating methods accept Map<String,Object> rather than a typed inner class
 * to dodge the Aura JSON→typed-DTO deserialization bug we hit with custom
 * inner classes (see PulseEmailRouterController for the full note).
 */
global with sharing class PulseAgentRoleController {

    // ─── DTOs ──────────────────────────────────────────────────────────

    global class RoleView {
        @AuraEnabled public String  developerName;
        @AuraEnabled public String  roleKey;
        @AuraEnabled public String  displayName;
        @AuraEnabled public String  description;
        @AuraEnabled public String  providerName;
        @AuraEnabled public String  defaultAutonomy;
        @AuraEnabled public String  systemPrompt;
        @AuraEnabled public String  toolAllowlistJson;
        @AuraEnabled public String  suggestedPhaseTypes;
        @AuraEnabled public Boolean active;
    }

    /**
     * Trimmed view shape used by the Workflow Builder role picker. Only
     * carries enough to render the dropdown and the read-only role
     * description preview underneath. Cacheable.
     */
    global class RoleSummaryView {
        @AuraEnabled public String developerName;
        @AuraEnabled public String roleKey;
        @AuraEnabled public String displayName;
        @AuraEnabled public String description;
        @AuraEnabled public String providerName;
        @AuraEnabled public String defaultAutonomy;
    }

    global class RoleDeployResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public Id      jobId;
        @AuraEnabled public String  developerName;
        @AuraEnabled public String  error;
    }

    global class DeployStatusView {
        @AuraEnabled public String  status;     // Queued | Processing | Completed | Failed | Aborted | Unknown
        @AuraEnabled public Boolean done;
        @AuraEnabled public String  errors;
    }

    // ─── List ──────────────────────────────────────────────────────────

    @AuraEnabled
    global static List<RoleView> listRoles() {
        List<RoleView> out = new List<RoleView>();
        for (Agent_Role__mdt r : [
            SELECT DeveloperName, Role_Key__c, Display_Name__c, Description__c,
                   Provider_Name__c, Default_Autonomy__c, System_Prompt__c,
                   Tool_Allowlist_JSON__c, Suggested_Phase_Types__c, Active__c
            FROM   Agent_Role__mdt
            ORDER BY Active__c DESC, Display_Name__c ASC NULLS LAST, DeveloperName ASC
        ]) {
            RoleView v = new RoleView();
            v.developerName       = r.DeveloperName;
            v.roleKey             = r.Role_Key__c;
            v.displayName         = r.Display_Name__c;
            v.description         = r.Description__c;
            v.providerName        = r.Provider_Name__c;
            v.defaultAutonomy     = r.Default_Autonomy__c;
            v.systemPrompt        = r.System_Prompt__c;
            v.toolAllowlistJson   = r.Tool_Allowlist_JSON__c;
            v.suggestedPhaseTypes = r.Suggested_Phase_Types__c;
            v.active              = r.Active__c == true;
            out.add(v);
        }
        return out;
    }

    @AuraEnabled(cacheable=true)
    global static List<RoleSummaryView> listActiveRoleSummaries() {
        List<RoleSummaryView> out = new List<RoleSummaryView>();
        for (Agent_Role__mdt r : [
            SELECT DeveloperName, Role_Key__c, Display_Name__c, Description__c,
                   Provider_Name__c, Default_Autonomy__c
            FROM   Agent_Role__mdt
            WHERE  Active__c = true
            ORDER BY Display_Name__c ASC NULLS LAST, DeveloperName ASC
        ]) {
            RoleSummaryView v = new RoleSummaryView();
            v.developerName   = r.DeveloperName;
            v.roleKey         = r.Role_Key__c;
            v.displayName     = r.Display_Name__c;
            v.description     = r.Description__c;
            v.providerName    = r.Provider_Name__c;
            v.defaultAutonomy = r.Default_Autonomy__c;
            out.add(v);
        }
        return out;
    }

    // ─── Mutations ─────────────────────────────────────────────────────

    /**
     * Test seam around Metadata.Operations.enqueueDeployment. Tests
     * swap in a stub via PulseAgentRoleController.deployer = ….
     */
    public interface IRoleDeployer {
        Id enqueue(Metadata.DeployContainer container);
    }

    public class DefaultRoleDeployer implements IRoleDeployer {
        public Id enqueue(Metadata.DeployContainer container) {
            return Metadata.Operations.enqueueDeployment(container, null);
        }
    }

    @TestVisible
    private static IRoleDeployer deployer = new DefaultRoleDeployer();

    /**
     * Last container we tried to deploy. Exposed for tests so they can
     * assert the prepared payload without going through the async pipeline.
     */
    @TestVisible
    private static Metadata.DeployContainer lastDeployContainer;

    @AuraEnabled
    global static RoleDeployResult upsertRole(Map<String, Object> payload) {
        RoleDeployResult out = new RoleDeployResult();
        try {
            RoleInput input = coerceToRoleInput(payload);
            if (input == null || String.isBlank(input.roleKey)) {
                out.success = false;
                out.error = 'roleKey is required';
                return out;
            }
            if (String.isBlank(input.displayName)) {
                out.success = false;
                out.error = 'displayName is required';
                return out;
            }
            if (String.isNotBlank(input.toolAllowlistJson)) {
                try {
                    Object parsed = JSON.deserializeUntyped(input.toolAllowlistJson);
                    if (!(parsed instanceof List<Object>)) {
                        out.success = false;
                        out.error = 'toolAllowlistJson must be a JSON array of tool keys';
                        return out;
                    }
                } catch (Exception je) {
                    out.success = false;
                    out.error = 'toolAllowlistJson is invalid JSON: ' + je.getMessage();
                    return out;
                }
            }
            if (String.isNotBlank(input.defaultAutonomy)
                && !ALLOWED_AUTONOMY.contains(input.defaultAutonomy)) {
                out.success = false;
                out.error = 'defaultAutonomy must be one of: '
                    + String.join(new List<String>(ALLOWED_AUTONOMY), ', ');
                return out;
            }

            String devName = String.isNotBlank(input.developerName)
                ? toDeveloperName(input.developerName)
                : toDeveloperName(input.roleKey);

            Metadata.CustomMetadata cm = new Metadata.CustomMetadata();
            cm.fullName = 'Agent_Role.' + devName;
            cm.label    = String.isNotBlank(input.displayName)
                ? input.displayName
                : devName.replace('_', ' ');

            cm.values.add(makeValue('Role_Key__c', input.roleKey));
            cm.values.add(makeValue('Display_Name__c', input.displayName));
            cm.values.add(makeValue('Active__c',
                input.active != null ? input.active : true));
            if (input.description != null) {
                cm.values.add(makeValue('Description__c', input.description));
            }
            if (String.isNotBlank(input.providerName)) {
                cm.values.add(makeValue('Provider_Name__c', input.providerName));
            }
            if (String.isNotBlank(input.defaultAutonomy)) {
                cm.values.add(makeValue('Default_Autonomy__c', input.defaultAutonomy));
            }
            if (input.systemPrompt != null) {
                cm.values.add(makeValue('System_Prompt__c', input.systemPrompt));
            }
            if (input.toolAllowlistJson != null) {
                cm.values.add(makeValue('Tool_Allowlist_JSON__c', input.toolAllowlistJson));
            }
            if (input.suggestedPhaseTypes != null) {
                cm.values.add(makeValue('Suggested_Phase_Types__c', input.suggestedPhaseTypes));
            }

            Metadata.DeployContainer container = new Metadata.DeployContainer();
            container.addMetadata(cm);
            lastDeployContainer = container;

            Id jobId = deployer.enqueue(container);
            out.success = true;
            out.jobId = jobId;
            out.developerName = devName;
            return out;
        } catch (Exception e) {
            out.success = false;
            out.error = e.getTypeName() + ': ' + e.getMessage();
            return out;
        }
    }

    /**
     * Soft-delete: the Apex Metadata API does not support removing CMDT
     * records, so we deploy an Active__c=false update. Admins can
     * re-activate via Setup if needed.
     */
    @AuraEnabled
    global static RoleDeployResult deleteRole(String developerName) {
        RoleDeployResult out = new RoleDeployResult();
        try {
            if (String.isBlank(developerName)) {
                out.success = false;
                out.error = 'developerName is required';
                return out;
            }
            String devName = toDeveloperName(developerName);

            Metadata.CustomMetadata cm = new Metadata.CustomMetadata();
            cm.fullName = 'Agent_Role.' + devName;
            cm.label    = devName.replace('_', ' ');
            cm.values.add(makeValue('Active__c', false));

            Metadata.DeployContainer container = new Metadata.DeployContainer();
            container.addMetadata(cm);
            lastDeployContainer = container;

            Id jobId = deployer.enqueue(container);
            out.success = true;
            out.jobId = jobId;
            out.developerName = devName;
            return out;
        } catch (Exception e) {
            out.success = false;
            out.error = e.getTypeName() + ': ' + e.getMessage();
            return out;
        }
    }

    @AuraEnabled
    global static DeployStatusView getDeployStatus(String jobId) {
        DeployStatusView v = new DeployStatusView();
        if (String.isBlank(jobId)) {
            v.status = 'Unknown';
            v.done = true;
            v.errors = 'jobId is required';
            return v;
        }
        List<AsyncApexJob> jobs = [
            SELECT Id, Status, ExtendedStatus, NumberOfErrors
            FROM   AsyncApexJob
            WHERE  Id = :jobId
            LIMIT 1
        ];
        if (jobs.isEmpty()) {
            // Metadata deploy jobs are not always queryable as AsyncApexJob —
            // the UI still gets a sane answer so it can stop polling.
            v.status = 'Unknown';
            v.done = true;
            return v;
        }
        AsyncApexJob j = jobs[0];
        v.status = j.Status;
        v.done = (j.Status == 'Completed' || j.Status == 'Failed' || j.Status == 'Aborted');
        if (j.NumberOfErrors != null && j.NumberOfErrors > 0) {
            v.errors = j.ExtendedStatus;
        }
        return v;
    }

    // ─── Coercion ──────────────────────────────────────────────────────

    public class RoleInput {
        public String  developerName;
        public String  roleKey;
        public String  displayName;
        public String  description;
        public String  providerName;
        public String  defaultAutonomy;
        public String  systemPrompt;
        public String  toolAllowlistJson;
        public String  suggestedPhaseTypes;
        public Boolean active;
    }

    @TestVisible
    private static final Set<String> ALLOWED_AUTONOMY = new Set<String>{
        'Propose_Only', 'Act_With_Approval', 'Autonomous_Safe'
    };

    @TestVisible
    private static RoleInput coerceToRoleInput(Map<String, Object> raw) {
        RoleInput out = new RoleInput();
        if (raw == null) return out;

        Object dn = raw.get('developerName');
        if (dn instanceof String) out.developerName = (String) dn;

        Object rk = raw.get('roleKey');
        if (rk instanceof String) out.roleKey = (String) rk;
        else if (rk != null) out.roleKey = String.valueOf(rk);

        Object dispName = raw.get('displayName');
        if (dispName instanceof String) out.displayName = (String) dispName;

        Object descObj = raw.get('description');
        if (descObj instanceof String) out.description = (String) descObj;

        Object prov = raw.get('providerName');
        if (prov instanceof String) out.providerName = (String) prov;

        Object aut = raw.get('defaultAutonomy');
        if (aut instanceof String) out.defaultAutonomy = (String) aut;

        Object sp = raw.get('systemPrompt');
        if (sp instanceof String) out.systemPrompt = (String) sp;

        Object tj = raw.get('toolAllowlistJson');
        if (tj instanceof String) {
            out.toolAllowlistJson = (String) tj;
        } else if (tj != null) {
            // Accept already-parsed list/map and re-serialize.
            out.toolAllowlistJson = JSON.serialize(tj);
        }

        Object spt = raw.get('suggestedPhaseTypes');
        if (spt instanceof String) {
            out.suggestedPhaseTypes = (String) spt;
        } else if (spt instanceof List<Object>) {
            // Convenience: accept arrays from the LWC side and join.
            List<String> parts = new List<String>();
            for (Object x : (List<Object>) spt) {
                if (x != null) parts.add(String.valueOf(x));
            }
            out.suggestedPhaseTypes = String.join(parts, ',');
        }

        Object act = raw.get('active');
        if (act instanceof Boolean) out.active = (Boolean) act;
        else if (act != null) out.active = Boolean.valueOf(String.valueOf(act));

        return out;
    }

    private static Metadata.CustomMetadataValue makeValue(String field, Object val) {
        Metadata.CustomMetadataValue v = new Metadata.CustomMetadataValue();
        v.field = field;
        v.value = val;
        return v;
    }

    @TestVisible
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
