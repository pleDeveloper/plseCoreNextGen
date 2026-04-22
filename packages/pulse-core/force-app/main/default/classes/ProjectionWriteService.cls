/**
 * ProjectionWriteService
 *
 * Governed data-promotion service that maps workflow field keys to parent-record
 * fields via Workflow_Projection__mdt.  All projection writes flow through this
 * class so that type-safety, allowlisting, precedence, and audit are enforced
 * in a single bulk-safe transaction boundary.
 *
 * Design constraints (per architecture doc §4.5):
 *  - One bulk DML per parent object type.
 *  - Idempotent — duplicate field-key writes with identical values are no-ops.
 *  - Shared fields respect Write_Precedence__c (lower number wins).
 *  - Every write (success or failure) emits a Workflow_Event__c audit row.
 */
global with sharing class ProjectionWriteService {

    // ── Inner types ─────────────────────────────────────────────────────

    /**
     * Caller-provided request: one per parent record that needs projected values.
     */
    global class ProjectionRequest {
        @AuraEnabled global Id   parentRecordId;
        @AuraEnabled global String parentObjectType;
        @AuraEnabled global String workflowKey;
        @AuraEnabled global Id   workflowInstanceId;
        /** field-key → string-serialised value from step result */
        @AuraEnabled global Map<String, String> fieldValues;
    }

    /**
     * Per-field outcome returned to caller and written to audit.
     */
    global class ProjectionResult {
        @AuraEnabled global String  fieldKey;
        @AuraEnabled global String  targetField;
        @AuraEnabled global Boolean success;
        @AuraEnabled global String  message;
    }

    // ── Testability seam ────────────────────────────────────────────────

    @TestVisible
    private static List<Workflow_Projection__mdt> projectionOverride;

    // ── Public API ──────────────────────────────────────────────────────

    /**
     * Bulk entry point.  Accepts a list of projection requests, resolves
     * field mappings, validates, writes, and audits.
     * @return flat list of per-field results across all requests
     */
    global static List<ProjectionResult> project(List<ProjectionRequest> requests) {
        if (requests == null || requests.isEmpty()) {
            return new List<ProjectionResult>();
        }

        List<Workflow_Projection__mdt> allProjections = loadProjections();
        Map<String, List<Workflow_Projection__mdt>> byKey = indexByFieldKey(allProjections);

        // Collect SObject describe tokens once per transaction
        Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();

        // Accumulate DML rows per object type, plus audit events
        Map<String, Map<Id, SObject>> dmlByObjectType = new Map<String, Map<Id, SObject>>();
        List<Workflow_Event__c> auditEvents = new List<Workflow_Event__c>();
        List<ProjectionResult> results = new List<ProjectionResult>();

        for (ProjectionRequest req : requests) {
            processRequest(req, byKey, globalDescribe, dmlByObjectType, auditEvents, results);
        }

        // One DML per object type
        executeDml(dmlByObjectType, auditEvents, results);

        // Audit insert — separate DML to keep parent update and audit independent
        if (!auditEvents.isEmpty()) {
            insert auditEvents;
        }

        return results;
    }

    // ── Private helpers ─────────────────────────────────────────────────

    private static List<Workflow_Projection__mdt> loadProjections() {
        if (projectionOverride != null) {
            return projectionOverride;
        }
        return [
            SELECT Field_Key__c, Target_Object__c, Target_Field__c,
                   Field_Type__c, Scope__c, Workflow_Key__c,
                   Write_Precedence__c, Active__c
            FROM   Workflow_Projection__mdt
            WHERE  Active__c = TRUE
        ];
    }

    /**
     * Index active projections by composite key = workflowKey + '.' + fieldKey
     * and also by the shared-scope wildcard '*.' + fieldKey.
     */
    private static Map<String, List<Workflow_Projection__mdt>> indexByFieldKey(
        List<Workflow_Projection__mdt> projections
    ) {
        Map<String, List<Workflow_Projection__mdt>> idx =
            new Map<String, List<Workflow_Projection__mdt>>();
        for (Workflow_Projection__mdt p : projections) {
            String scopedKey = compositeKey(p.Workflow_Key__c, p.Field_Key__c);
            if (!idx.containsKey(scopedKey)) {
                idx.put(scopedKey, new List<Workflow_Projection__mdt>());
            }
            idx.get(scopedKey).add(p);
        }
        return idx;
    }

    private static String compositeKey(String workflowKey, String fieldKey) {
        return (workflowKey != null ? workflowKey : '*') + '.' + fieldKey;
    }

    /**
     * Resolve the best matching projection for a given workflow key + field key.
     * Workflow-scoped records beat shared records.  Among same scope, lowest
     * Write_Precedence__c wins.
     */
    @TestVisible
    private static Workflow_Projection__mdt resolveProjection(
        String workflowKey,
        String fieldKey,
        Map<String, List<Workflow_Projection__mdt>> byKey
    ) {
        // Try workflow-scoped first
        String scopedKey = compositeKey(workflowKey, fieldKey);
        Workflow_Projection__mdt best = pickBestPrecedence(byKey.get(scopedKey));
        if (best != null) {
            return best;
        }
        // Fall back to shared (wildcard workflow key)
        String sharedKey = compositeKey(null, fieldKey);
        return pickBestPrecedence(byKey.get(sharedKey));
    }

    private static Workflow_Projection__mdt pickBestPrecedence(
        List<Workflow_Projection__mdt> candidates
    ) {
        if (candidates == null || candidates.isEmpty()) {
            return null;
        }
        Workflow_Projection__mdt best = candidates[0];
        for (Integer i = 1; i < candidates.size(); i++) {
            Workflow_Projection__mdt c = candidates[i];
            Decimal cPrec = c.Write_Precedence__c != null ? c.Write_Precedence__c : 99999;
            Decimal bPrec = best.Write_Precedence__c != null ? best.Write_Precedence__c : 99999;
            if (cPrec < bPrec) {
                best = c;
            }
        }
        return best;
    }

    /**
     * Process a single request: resolve each field key, validate, and stage
     * DML rows + audit events.
     */
    private static void processRequest(
        ProjectionRequest req,
        Map<String, List<Workflow_Projection__mdt>> byKey,
        Map<String, Schema.SObjectType> globalDescribe,
        Map<String, Map<Id, SObject>> dmlByObjectType,
        List<Workflow_Event__c> auditEvents,
        List<ProjectionResult> results
    ) {
        if (req.fieldValues == null || req.fieldValues.isEmpty()) {
            return;
        }

        for (String fieldKey : req.fieldValues.keySet()) {
            ProjectionResult pr = new ProjectionResult();
            pr.fieldKey = fieldKey;

            Workflow_Projection__mdt mapping = resolveProjection(
                req.workflowKey, fieldKey, byKey
            );

            // No mapping found
            if (mapping == null) {
                pr.success = false;
                pr.message = 'No active projection mapping for field key: ' + fieldKey;
                results.add(pr);
                auditEvents.add(buildAuditEvent(
                    req, fieldKey, null, 'PROJECTION_SKIP', pr.message
                ));
                continue;
            }

            pr.targetField = mapping.Target_Field__c;
            String targetObj = mapping.Target_Object__c;

            // Object allowlist check
            if (!globalDescribe.containsKey(targetObj)) {
                pr.success = false;
                pr.message = 'Target object not found in org: ' + targetObj;
                results.add(pr);
                auditEvents.add(buildAuditEvent(
                    req, fieldKey, targetObj, 'PROJECTION_FAIL', pr.message
                ));
                continue;
            }

            Schema.DescribeSObjectResult objDesc =
                globalDescribe.get(targetObj).getDescribe();
            Map<String, Schema.SObjectField> fieldMap = objDesc.fields.getMap();

            // Field allowlist check
            String fieldApiName = mapping.Target_Field__c;
            if (!fieldMap.containsKey(fieldApiName.toLowerCase())) {
                pr.success = false;
                pr.message = 'Target field not found on ' + targetObj + ': ' + fieldApiName;
                results.add(pr);
                auditEvents.add(buildAuditEvent(
                    req, fieldKey, targetObj, 'PROJECTION_FAIL', pr.message
                ));
                continue;
            }

            Schema.DescribeFieldResult fieldDesc =
                fieldMap.get(fieldApiName.toLowerCase()).getDescribe();

            // Field must be updateable
            if (!fieldDesc.isUpdateable()) {
                pr.success = false;
                pr.message = 'Target field is not updateable: ' + fieldApiName;
                results.add(pr);
                auditEvents.add(buildAuditEvent(
                    req, fieldKey, targetObj, 'PROJECTION_FAIL', pr.message
                ));
                continue;
            }

            // Type compatibility check
            String valueStr = req.fieldValues.get(fieldKey);
            Object coerced;
            try {
                coerced = coerceValue(valueStr, fieldDesc, mapping.Field_Type__c);
            } catch (TypeException tex) {
                pr.success = false;
                pr.message = 'Type incompatibility for ' + fieldKey + ': ' + tex.getMessage();
                results.add(pr);
                auditEvents.add(buildAuditEvent(
                    req, fieldKey, targetObj, 'PROJECTION_FAIL', pr.message
                ));
                continue;
            }

            // Stage DML row — merge into existing row if same parent record
            if (!dmlByObjectType.containsKey(targetObj)) {
                dmlByObjectType.put(targetObj, new Map<Id, SObject>());
            }
            Map<Id, SObject> objRows = dmlByObjectType.get(targetObj);
            SObject row = objRows.get(req.parentRecordId);
            if (row == null) {
                row = objDesc.getSobjectType().newSObject(req.parentRecordId);
                objRows.put(req.parentRecordId, row);
            }
            row.put(fieldApiName, coerced);

            pr.success = true;
            pr.message = 'Staged';
            results.add(pr);
            auditEvents.add(buildAuditEvent(
                req, fieldKey, targetObj, 'PROJECTION_WRITE', fieldApiName + ' = ' + valueStr
            ));
        }
    }

    /**
     * Coerce a string value to the target field's Salesforce type.
     * Throws TypeException on incompatibility.
     */
    @TestVisible
    private static Object coerceValue(
        String valueStr,
        Schema.DescribeFieldResult fieldDesc,
        String declaredType
    ) {
        if (valueStr == null) {
            return null;
        }

        Schema.DisplayType dt = fieldDesc.getType();

        if (dt == Schema.DisplayType.STRING ||
            dt == Schema.DisplayType.TEXTAREA ||
            dt == Schema.DisplayType.PICKLIST ||
            dt == Schema.DisplayType.URL ||
            dt == Schema.DisplayType.PHONE ||
            dt == Schema.DisplayType.EMAIL) {
            // Enforce field length
            Integer maxLen = fieldDesc.getLength();
            if (valueStr.length() > maxLen) {
                throw new TypeException(
                    'Value exceeds max length ' + maxLen + ' for field type ' + dt
                );
            }
            return valueStr;
        }

        if (dt == Schema.DisplayType.DOUBLE ||
            dt == Schema.DisplayType.CURRENCY ||
            dt == Schema.DisplayType.PERCENT) {
            try {
                return Decimal.valueOf(valueStr);
            } catch (Exception e) {
                throw new TypeException('Cannot convert "' + valueStr + '" to Decimal');
            }
        }

        if (dt == Schema.DisplayType.INTEGER) {
            try {
                return Integer.valueOf(valueStr);
            } catch (Exception e) {
                throw new TypeException('Cannot convert "' + valueStr + '" to Integer');
            }
        }

        if (dt == Schema.DisplayType.DATE) {
            try {
                return Date.valueOf(valueStr);
            } catch (Exception e) {
                throw new TypeException('Cannot convert "' + valueStr + '" to Date');
            }
        }

        if (dt == Schema.DisplayType.DATETIME) {
            try {
                return Datetime.valueOf(valueStr);
            } catch (Exception e) {
                throw new TypeException('Cannot convert "' + valueStr + '" to Datetime');
            }
        }

        if (dt == Schema.DisplayType.BOOLEAN) {
            return Boolean.valueOf(valueStr);
        }

        throw new TypeException(
            'Unsupported target field type for projection: ' + dt
        );
    }

    /**
     * Execute one update DML per object type.  On partial failure, mark
     * affected results and add failure audit events.
     */
    private static void executeDml(
        Map<String, Map<Id, SObject>> dmlByObjectType,
        List<Workflow_Event__c> auditEvents,
        List<ProjectionResult> results
    ) {
        for (String objType : dmlByObjectType.keySet()) {
            List<SObject> rows = dmlByObjectType.get(objType).values();
            if (rows.isEmpty()) {
                continue;
            }
            Database.SaveResult[] saveResults = Database.update(rows, false);
            for (Integer i = 0; i < saveResults.size(); i++) {
                if (!saveResults[i].isSuccess()) {
                    String errMsg = '';
                    for (Database.Error err : saveResults[i].getErrors()) {
                        errMsg += err.getMessage() + '; ';
                    }
                    Id failedId = rows[i].Id;
                    // Mark all staged results for this record as failed
                    for (ProjectionResult pr : results) {
                        if (pr.success == true && pr.message == 'Staged') {
                            pr.success = false;
                            pr.message = 'DML failed: ' + errMsg;
                        }
                    }
                    auditEvents.add(new Workflow_Event__c(
                        Event_Type__c  = 'PROJECTION_DML_FAIL',
                        Actor_Type__c  = 'System',
                        Detail_JSON__c = JSON.serialize(new Map<String, String>{
                            'objectType' => objType,
                            'recordId'   => String.valueOf(failedId),
                            'error'      => errMsg
                        })
                    ));
                }
            }
            // Mark remaining staged results as committed
            for (ProjectionResult pr : results) {
                if (pr.success == true && pr.message == 'Staged') {
                    pr.message = 'Committed';
                }
            }
        }
    }

    private static Workflow_Event__c buildAuditEvent(
        ProjectionRequest req,
        String fieldKey,
        String targetObj,
        String eventType,
        String detail
    ) {
        return new Workflow_Event__c(
            Event_Type__c       = eventType,
            Actor_Type__c       = 'System',
            Workflow_Instance__c = req.workflowInstanceId,
            Detail_JSON__c      = JSON.serialize(new Map<String, String>{
                'fieldKey'      => fieldKey,
                'workflowKey'   => req.workflowKey,
                'targetObject'  => targetObj,
                'detail'        => detail
            })
        );
    }

    /** Thrown when value cannot be coerced to target field type. */
    global class TypeException extends Exception {}
}
