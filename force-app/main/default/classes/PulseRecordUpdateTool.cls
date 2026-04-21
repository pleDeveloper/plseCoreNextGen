public with sharing class PulseRecordUpdateTool implements PulseTool {

    private static final String TOOL_KEY = 'update_record';

    @TestVisible
    private static Map<String, Set<String>> fieldAllowlist = new Map<String, Set<String>>();

    public String getToolKey() {
        return TOOL_KEY;
    }

    public String getDescription() {
        return 'Update a Salesforce record. Requires recordId, objectType, and a fields map of API name to value.';
    }

    public Map<String, Object> getInputSchema() {
        return new Map<String, Object>{
            'type' => 'object',
            'properties' => new Map<String, Object>{
                'recordId' => new Map<String, Object>{
                    'type' => 'string',
                    'description' => 'The Salesforce record Id to update'
                },
                'objectType' => new Map<String, Object>{
                    'type' => 'string',
                    'description' => 'SObject API name (e.g. Account, Opportunity)'
                },
                'fields' => new Map<String, Object>{
                    'type' => 'object',
                    'description' => 'Map of field API name to new value'
                }
            },
            'required' => new List<String>{ 'recordId', 'objectType', 'fields' }
        };
    }

    public String getDefaultHitlPolicy() {
        return 'Approval_Required';
    }

    public PulseTool.Result execute(PulseTool.Context ctx) {
        String recordId = (String) ctx.input.get('recordId');
        String objectType = (String) ctx.input.get('objectType');
        Map<String, Object> fields = (Map<String, Object>) ctx.input.get('fields');

        if (String.isBlank(recordId) || String.isBlank(objectType)
                || fields == null || fields.isEmpty()) {
            return PulseTool.Result.fail('Missing required: recordId, objectType, fields');
        }

        Set<String> allowed = fieldAllowlist.get(objectType);
        if (allowed != null) {
            for (String fieldName : fields.keySet()) {
                if (!allowed.contains(fieldName.toLowerCase())) {
                    return PulseTool.Result.fail(
                        'Field not in allowlist: ' + objectType + '.' + fieldName);
                }
            }
        }

        Schema.SObjectType sot = Schema.getGlobalDescribe().get(objectType);
        if (sot == null) {
            return PulseTool.Result.fail('Unknown object type: ' + objectType);
        }

        Schema.DescribeSObjectResult desc = sot.getDescribe();
        if (!desc.isUpdateable()) {
            return PulseTool.Result.fail('Object is not updateable: ' + objectType);
        }

        SObject record = sot.newSObject(Id.valueOf(recordId));
        Map<String, Schema.SObjectField> fieldMap = desc.fields.getMap();

        for (String fieldName : fields.keySet()) {
            Schema.SObjectField sof = fieldMap.get(fieldName.toLowerCase());
            if (sof == null) {
                return PulseTool.Result.fail('Unknown field: ' + objectType + '.' + fieldName);
            }
            if (!sof.getDescribe().isUpdateable()) {
                return PulseTool.Result.fail(
                    'Field not updateable: ' + objectType + '.' + fieldName);
            }
            record.put(fieldName, fields.get(fieldName));
        }

        try {
            update record;
            return PulseTool.Result.ok(JSON.serialize(new Map<String, String>{
                'status' => 'updated',
                'recordId' => recordId
            }));
        } catch (Exception e) {
            return PulseTool.Result.fail('Update failed: ' + e.getMessage());
        }
    }

    public static void setFieldAllowlist(String objectType, Set<String> allowedFields) {
        Set<String> lower = new Set<String>();
        for (String f : allowedFields) {
            lower.add(f.toLowerCase());
        }
        fieldAllowlist.put(objectType, lower);
    }
}
