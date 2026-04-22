/**
 * PulseGlobalActionHubController
 *
 * @AuraEnabled controller for the pulseGlobalActionHub LWC — a cross-
 * record approval inbox. Returns pending Workflow_Action__c rows
 * assigned to the running user (or their queues) with parent record
 * columns resolved from Action_Hub_Column_Config__mdt.
 *
 * DTO classes use the `public` access modifier (NOT global) and each
 * field is annotated @AuraEnabled — the serialization pattern that
 * works reliably for LWC-invoked methods.
 *
 * Sharing: `public with sharing` so the running user's record-access
 * controls which actions and parent rows they see. FLS is enforced
 * explicitly via Security.stripInaccessible for parent record reads.
 */
public with sharing class PulseGlobalActionHubController {

    // ─── DTOs ────────────────────────────────────────────────────────

    public class HubRow {
        @AuraEnabled public Id       actionId;
        @AuraEnabled public String   actionLabel;
        @AuraEnabled public String   toolKey;
        @AuraEnabled public String   phaseKey;
        @AuraEnabled public String   phaseLabel;
        @AuraEnabled public String   workflowName;
        @AuraEnabled public String   parentObjectType;
        @AuraEnabled public String   parentRecordId;
        @AuraEnabled public String   parentDisplayName;
        @AuraEnabled public Datetime requestedDate;
        @AuraEnabled public Decimal  ageInHours;
        @AuraEnabled public List<ColumnCell> columns;
        @AuraEnabled public Boolean  canRefine;
        @AuraEnabled public String   hitlPolicy;
        @AuraEnabled public String   requestJson;
        @AuraEnabled public String   assignmentKind; // 'me' | 'group' | 'unassigned'
        @AuraEnabled public String   assignedGroupName;
    }

    public class ColumnCell {
        @AuraEnabled public String field;
        @AuraEnabled public String label;
        @AuraEnabled public String value;
    }

    public class ColumnConfigView {
        @AuraEnabled public String  configKey;
        @AuraEnabled public String  targetObject;
        @AuraEnabled public String  columnsJson;
        @AuraEnabled public Boolean active;
        @AuraEnabled public String  masterLabel;
    }

    public class ColumnConfigInput {
        @AuraEnabled public String  configKey;
        @AuraEnabled public String  targetObject;
        @AuraEnabled public String  columnsJson;
        @AuraEnabled public Boolean active;
        @AuraEnabled public String  masterLabel;
    }

    public class UpsertConfigResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public Id      deploymentJobId;
        @AuraEnabled public String  message;
    }

    public class ResolveResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String  resultStatus;
        @AuraEnabled public String  message;
    }

    // Tool keys that support payload refinement in the runtime.
    private static final Set<String> REFINABLE_TOOL_KEYS = new Set<String>{
        'send_email', 'update_record', 'external_api'
    };

    // ─── getMyPendingActions ────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static List<HubRow> getMyPendingActions(Map<String, Object> filters) {
        Map<String, Object> safeFilters = filters != null ? filters : new Map<String, Object>();

        // Resolve the viewer's queue memberships.
        Set<Id> myGroupIds = resolveMyGroupIds();
        Id myUserId = UserInfo.getUserId();

        Boolean includeUnassigned = toBool(safeFilters.get('includeUnassigned'), false);
        Boolean assignedOnlyToMe  = toBool(safeFilters.get('assignedOnlyToMe'), false);
        String  parentTypeFilter  = toStr(safeFilters.get('parentObjectType'));
        String  workflowKeyFilter = toStr(safeFilters.get('workflowKey'));
        Integer maxAgeDays        = toInt(safeFilters.get('maxAgeDays'));

        List<String> clauses = new List<String>{ 'Status__c = \'Pending\'' };

        if (assignedOnlyToMe) {
            clauses.add('Assigned_User__c = :myUserId');
        } else {
            List<String> orParts = new List<String>{ 'Assigned_User__c = :myUserId' };
            if (!myGroupIds.isEmpty()) {
                orParts.add('Assigned_To_Group__c IN :myGroupIds');
            }
            if (includeUnassigned) {
                orParts.add('(Assigned_User__c = null AND Assigned_To_Group__c = null)');
            }
            clauses.add('(' + String.join(orParts, ' OR ') + ')');
        }

        if (String.isNotBlank(parentTypeFilter)) {
            clauses.add('Workflow_Instance__r.Parent_Object_Type__c = :parentTypeFilter');
        }
        if (String.isNotBlank(workflowKeyFilter)) {
            clauses.add('Workflow_Instance__r.Workflow_Definition__r.Workflow_Key__c = :workflowKeyFilter');
        }
        Datetime ageCutoff = null;
        if (maxAgeDays != null && maxAgeDays > 0) {
            ageCutoff = Datetime.now().addDays(-maxAgeDays);
            clauses.add('CreatedDate >= :ageCutoff');
        }

        String soql =
            'SELECT Id, Label__c, Tool_Key__c, HITL_Policy__c, Request_JSON__c, ' +
            '       Phase_Key__c, CreatedDate, Assigned_User__c, Assigned_To_Group__c, ' +
            '       Workflow_Instance__c, Workflow_Instance__r.Parent_Object_Type__c, ' +
            '       Workflow_Instance__r.Parent_Record_Id__c, ' +
            '       Workflow_Instance__r.Workflow_Definition__r.Name, ' +
            '       Workflow_Instance__r.Workflow_Definition__r.Definition_JSON__c ' +
            'FROM Workflow_Action__c ' +
            'WHERE ' + String.join(clauses, ' AND ') + ' ' +
            'ORDER BY CreatedDate ASC ' +
            'LIMIT 200';

        List<Workflow_Action__c> rows;
        try {
            rows = Database.query(soql);
        } catch (Exception e) {
            return new List<HubRow>();
        }

        // Group IDs are stored as Text on Workflow_Action__c (no custom
        // Lookup to Group is allowed in metadata), so do a separate query
        // to fetch Group names for display.
        Set<Id> groupIdsToResolve = new Set<Id>();
        for (Workflow_Action__c a : rows) {
            if (String.isNotBlank(a.Assigned_To_Group__c)) {
                try { groupIdsToResolve.add(Id.valueOf(a.Assigned_To_Group__c)); }
                catch (Exception ignored) {}
            }
        }
        Map<Id, String> groupNamesById = new Map<Id, String>();
        if (!groupIdsToResolve.isEmpty()) {
            for (Group g : [SELECT Id, Name FROM Group WHERE Id IN :groupIdsToResolve]) {
                groupNamesById.put(g.Id, g.Name);
            }
        }

        if (rows.isEmpty()) return new List<HubRow>();

        // Group parent record ids by SObject type for bulk fetch.
        Map<String, Set<Id>> idsByType = new Map<String, Set<Id>>();
        for (Workflow_Action__c a : rows) {
            String pType = a.Workflow_Instance__r != null
                ? a.Workflow_Instance__r.Parent_Object_Type__c : null;
            String pId   = a.Workflow_Instance__r != null
                ? a.Workflow_Instance__r.Parent_Record_Id__c : null;
            if (String.isBlank(pType) || String.isBlank(pId)) continue;
            Id asId;
            try { asId = (Id) pId; } catch (Exception e) { continue; }
            if (!idsByType.containsKey(pType)) {
                idsByType.put(pType, new Set<Id>());
            }
            idsByType.get(pType).add(asId);
        }

        Map<String, Action_Hub_Column_Config__mdt> configByObject = loadConfigsByObject();
        Action_Hub_Column_Config__mdt fallback = configByObject.get('*');

        Map<Id, SObject> parentsById = new Map<Id, SObject>();
        Map<String, List<Map<String, String>>> colsByObject = new Map<String, List<Map<String, String>>>();

        for (String objType : idsByType.keySet()) {
            Action_Hub_Column_Config__mdt cfg = configByObject.containsKey(objType)
                ? configByObject.get(objType) : fallback;
            List<Map<String, String>> cols = parseColumns(cfg);
            colsByObject.put(objType, cols);

            Set<String> fields = new Set<String>{ 'Id' };
            Schema.SObjectType sot = Schema.getGlobalDescribe().get(objType);
            if (sot == null) continue;
            Map<String, Schema.SObjectField> fmap = sot.getDescribe().fields.getMap();
            if (fmap.containsKey('name')) fields.add('Name');
            for (Map<String, String> col : cols) {
                String fname = col.get('field');
                if (String.isNotBlank(fname) && fmap.containsKey(fname.toLowerCase())) {
                    fields.add(fname);
                }
            }

            Set<Id> ids = idsByType.get(objType);
            String parentSoql =
                'SELECT ' + String.join(new List<String>(fields), ', ') +
                ' FROM ' + String.escapeSingleQuotes(objType) +
                ' WHERE Id IN :ids';
            try {
                List<SObject> recs = Database.query(parentSoql);
                SObjectAccessDecision decision = Security.stripInaccessible(
                    AccessType.READABLE, recs
                );
                for (SObject r : decision.getRecords()) {
                    parentsById.put((Id) r.get('Id'), r);
                }
            } catch (Exception e) {
                continue;
            }
        }

        List<HubRow> out = new List<HubRow>();
        Datetime nowDt = Datetime.now();
        for (Workflow_Action__c a : rows) {
            HubRow row = new HubRow();
            row.actionId    = a.Id;
            row.actionLabel = a.Label__c;
            row.toolKey     = a.Tool_Key__c;
            row.phaseKey    = a.Phase_Key__c;
            row.hitlPolicy  = a.HITL_Policy__c;
            row.requestJson = a.Request_JSON__c;
            row.requestedDate = a.CreatedDate;
            row.ageInHours  = ((nowDt.getTime() - a.CreatedDate.getTime()) / 1000.0) / 3600.0;
            row.canRefine   = REFINABLE_TOOL_KEYS.contains(a.Tool_Key__c);

            if (a.Assigned_User__c == myUserId) {
                row.assignmentKind = 'me';
            } else if (String.isNotBlank(a.Assigned_To_Group__c) && myGroupIds.contains(a.Assigned_To_Group__c)) {
                row.assignmentKind = 'group';
                row.assignedGroupName = groupNamesById.get(a.Assigned_To_Group__c);
            } else {
                row.assignmentKind = 'unassigned';
            }

            if (a.Workflow_Instance__r != null) {
                row.parentObjectType = a.Workflow_Instance__r.Parent_Object_Type__c;
                row.parentRecordId   = a.Workflow_Instance__r.Parent_Record_Id__c;
                if (a.Workflow_Instance__r.Workflow_Definition__r != null) {
                    row.workflowName = a.Workflow_Instance__r.Workflow_Definition__r.Name;
                    String defJson = a.Workflow_Instance__r.Workflow_Definition__r.Definition_JSON__c;
                    row.phaseLabel = extractPhaseLabel(defJson, a.Phase_Key__c);
                }
            }

            List<ColumnCell> cells = new List<ColumnCell>();
            SObject parent = null;
            if (String.isNotBlank(row.parentRecordId)) {
                try { parent = parentsById.get((Id) row.parentRecordId); } catch (Exception e) {}
            }
            if (parent != null) {
                row.parentDisplayName = safeGetFieldString(parent, 'Name', row.parentRecordId);
            } else {
                row.parentDisplayName = row.parentRecordId;
            }
            List<Map<String, String>> cols = colsByObject.get(row.parentObjectType);
            if (cols == null) {
                ColumnCell c = new ColumnCell();
                c.field = 'Name';
                c.label = 'Record';
                c.value = row.parentDisplayName;
                cells.add(c);
            } else {
                for (Map<String, String> col : cols) {
                    ColumnCell cell = new ColumnCell();
                    cell.field = col.get('field');
                    cell.label = col.get('label');
                    cell.value = parent != null
                        ? safeGetFieldString(parent, cell.field, '')
                        : '';
                    cells.add(cell);
                }
            }
            row.columns = cells;

            out.add(row);
        }
        return out;
    }

    // ─── approveAction / rejectAction ───────────────────────────────

    @AuraEnabled
    public static ResolveResult approveAction(
        Id actionId, String refinedPayloadJson, String notes
    ) {
        return invokeResolve(actionId, true, refinedPayloadJson);
    }

    @AuraEnabled
    public static ResolveResult rejectAction(Id actionId, String notes) {
        return invokeResolve(actionId, false, null);
    }

    private static ResolveResult invokeResolve(
        Id actionId, Boolean approved, String refinedPayloadJson
    ) {
        ResolveResult r = new ResolveResult();
        if (actionId == null) {
            r.success = false;
            r.message = 'actionId is required';
            return r;
        }
        try {
            PulseToolModels.Result tr = HitlService.resolveApproval(
                actionId, approved, UserInfo.getUserId(), refinedPayloadJson
            );
            r.success = tr.success;
            if (tr.success) {
                r.resultStatus = approved ? 'Executed' : 'Rejected';
                r.message = approved ? 'Action approved and executed' : 'Action rejected';
            } else {
                r.resultStatus = 'Failed';
                r.message = tr.errorMessage;
            }
        } catch (Exception e) {
            r.success = false;
            r.resultStatus = 'Failed';
            r.message = e.getMessage();
        }
        return r;
    }

    // ─── listColumnConfigs ──────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static List<ColumnConfigView> listColumnConfigs() {
        List<ColumnConfigView> out = new List<ColumnConfigView>();
        for (Action_Hub_Column_Config__mdt cfg : [
            SELECT MasterLabel, DeveloperName, Config_Key__c, Target_Object__c,
                   Columns_JSON__c, Active__c
            FROM Action_Hub_Column_Config__mdt
            ORDER BY Target_Object__c ASC, MasterLabel ASC
        ]) {
            ColumnConfigView v = new ColumnConfigView();
            v.configKey    = String.isNotBlank(cfg.Config_Key__c)
                ? cfg.Config_Key__c : cfg.DeveloperName;
            v.targetObject = cfg.Target_Object__c;
            v.columnsJson  = cfg.Columns_JSON__c;
            v.active       = cfg.Active__c;
            v.masterLabel  = cfg.MasterLabel;
            out.add(v);
        }
        return out;
    }

    // ─── upsertColumnConfig ─────────────────────────────────────────

    /**
     * Accepts Map<String, Object> instead of a typed inner DTO class.
     * The Aura LWC→Apex framework fails to deserialize typed inner-class
     * inputs with a generic "internal server error (-583189392)" envelope
     * — see docs/diagnostics/aura-upsertTrigger-repro.sh. We coerce the
     * raw map to ColumnConfigInput internally.
     */
    @AuraEnabled
    public static UpsertConfigResult upsertColumnConfig(Map<String, Object> payload) {
        ColumnConfigInput input = coerceToColumnConfigInput(payload);

        UpsertConfigResult res = new UpsertConfigResult();
        if (input == null || String.isBlank(input.configKey)) {
            res.success = false;
            res.message = 'configKey is required';
            return res;
        }
        if (String.isBlank(input.targetObject)) {
            res.success = false;
            res.message = 'targetObject is required';
            return res;
        }

        String devName = toDeveloperName(input.configKey);
        String label   = String.isNotBlank(input.masterLabel)
            ? input.masterLabel : input.configKey.replace('_', ' ');

        Metadata.CustomMetadata cm = new Metadata.CustomMetadata();
        cm.fullName = 'Action_Hub_Column_Config.' + devName;
        cm.label    = label;

        cm.values.add(makeValue('Config_Key__c', input.configKey));
        cm.values.add(makeValue('Target_Object__c', input.targetObject));
        cm.values.add(makeValue('Columns_JSON__c',
            String.isNotBlank(input.columnsJson) ? input.columnsJson : '[]'));
        cm.values.add(makeValue('Active__c', input.active != null ? input.active : true));

        Metadata.DeployContainer container = new Metadata.DeployContainer();
        container.addMetadata(cm);

        try {
            Id jobId = Metadata.Operations.enqueueDeployment(container, null);
            res.success = true;
            res.deploymentJobId = jobId;
            res.message = 'Deployment enqueued';
        } catch (Exception e) {
            res.success = false;
            res.message = 'Deploy failed: ' + e.getMessage();
        }
        return res;
    }

    // ─── Internal helpers ───────────────────────────────────────────

    @TestVisible
    private static ColumnConfigInput coerceToColumnConfigInput(Map<String, Object> raw) {
        ColumnConfigInput out = new ColumnConfigInput();
        out.active = true; // default; overridden by explicit value below
        if (raw == null) return out;
        Object k = raw.get('configKey');
        if (k instanceof String) out.configKey = (String) k;
        Object t = raw.get('targetObject');
        if (t instanceof String) out.targetObject = (String) t;
        Object c = raw.get('columnsJson');
        if (c instanceof String) {
            out.columnsJson = (String) c;
        } else if (c != null) {
            // Allow clients to pass an already-parsed array/object — re-serialize
            out.columnsJson = JSON.serialize(c);
        }
        Object a = raw.get('active');
        if (a instanceof Boolean) {
            out.active = (Boolean) a;
        } else if (a instanceof String) {
            out.active = 'true'.equalsIgnoreCase((String) a);
        } else {
            out.active = true;
        }
        Object l = raw.get('masterLabel');
        if (l instanceof String) out.masterLabel = (String) l;
        return out;
    }

    private static Set<Id> resolveMyGroupIds() {
        Set<Id> ids = new Set<Id>();
        for (GroupMember gm : [
            SELECT GroupId FROM GroupMember WHERE UserOrGroupId = :UserInfo.getUserId()
        ]) {
            ids.add(gm.GroupId);
        }
        return ids;
    }

    private static Map<String, Action_Hub_Column_Config__mdt> loadConfigsByObject() {
        Map<String, Action_Hub_Column_Config__mdt> byObj =
            new Map<String, Action_Hub_Column_Config__mdt>();
        for (Action_Hub_Column_Config__mdt cfg : [
            SELECT MasterLabel, DeveloperName, Config_Key__c, Target_Object__c,
                   Columns_JSON__c, Active__c
            FROM Action_Hub_Column_Config__mdt
            WHERE Active__c = true
        ]) {
            if (String.isBlank(cfg.Target_Object__c)) continue;
            byObj.put(cfg.Target_Object__c, cfg);
        }
        return byObj;
    }

    private static List<Map<String, String>> parseColumns(Action_Hub_Column_Config__mdt cfg) {
        List<Map<String, String>> out = new List<Map<String, String>>();
        if (cfg == null || String.isBlank(cfg.Columns_JSON__c)) return out;
        try {
            Object parsed = JSON.deserializeUntyped(cfg.Columns_JSON__c);
            if (!(parsed instanceof List<Object>)) return out;
            for (Object o : (List<Object>) parsed) {
                if (!(o instanceof Map<String, Object>)) continue;
                Map<String, Object> m = (Map<String, Object>) o;
                Map<String, String> col = new Map<String, String>();
                col.put('field', toStr(m.get('field')));
                col.put('label', toStr(m.get('label')));
                if (String.isNotBlank(col.get('field'))) out.add(col);
            }
        } catch (Exception e) {
            return new List<Map<String, String>>();
        }
        return out;
    }

    private static String safeGetFieldString(SObject rec, String fieldName, String fallback) {
        if (rec == null || String.isBlank(fieldName)) return fallback;
        try {
            Object v = rec.get(fieldName);
            if (v == null) return fallback;
            if (v instanceof Date) return String.valueOf((Date) v);
            if (v instanceof Datetime) return ((Datetime) v).format();
            return String.valueOf(v);
        } catch (Exception e) {
            return fallback;
        }
    }

    private static String extractPhaseLabel(String defJson, String phaseKey) {
        if (String.isBlank(defJson) || String.isBlank(phaseKey)) return phaseKey;
        try {
            WorkflowContract.Workflow wf = WorkflowContract.parse(defJson);
            WorkflowContract.State s = wf.getState(phaseKey);
            return (s != null && String.isNotBlank(s.label)) ? s.label : phaseKey;
        } catch (Exception e) {
            return phaseKey;
        }
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
        if (cleaned.endsWith('_')) cleaned = cleaned.substring(0, cleaned.length() - 1);
        if (String.isBlank(cleaned)) cleaned = 'Unnamed';
        if (!Pattern.matches('[A-Za-z].*', cleaned)) cleaned = 'X_' + cleaned;
        return cleaned;
    }

    private static Boolean toBool(Object o, Boolean defVal) {
        if (o == null) return defVal;
        if (o instanceof Boolean) return (Boolean) o;
        if (o instanceof String) return ((String) o).equalsIgnoreCase('true');
        return defVal;
    }

    private static Integer toInt(Object o) {
        if (o == null) return null;
        if (o instanceof Integer) return (Integer) o;
        if (o instanceof Decimal) return ((Decimal) o).intValue();
        if (o instanceof Long)    return ((Long) o).intValue();
        if (o instanceof String) {
            try { return Integer.valueOf((String) o); } catch (Exception e) { return null; }
        }
        return null;
    }

    private static String toStr(Object o) {
        if (o == null) return null;
        return String.valueOf(o);
    }
}
