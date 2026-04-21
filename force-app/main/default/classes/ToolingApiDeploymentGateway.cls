/**
 * ToolingApiDeploymentGateway
 *
 * Schema deployment gateway that creates CustomField records via the
 * Tooling API REST endpoint.  Uses a Named Credential (Pulse_Self_Org_Tooling)
 * that points back at the same org (self-org callout pattern).
 *
 * This replaces the Apex Metadata API approach (Metadata.CustomField) which
 * is not exposed in this org — see architecture doc §4.6 Correction 4.
 *
 * Wave 2 scope: synchronous per-field creation.  If volume grows, the
 * gateway can be re-homed to Queueable in a future wave.
 */
public with sharing class ToolingApiDeploymentGateway extends SchemaDeploymentGateway {

    @TestVisible private static final String NAMED_CREDENTIAL = 'callout:Pulse_Self_Org_Tooling';
    @TestVisible private static final String API_VERSION = 'v62.0';


    // ── buildPlan ──────────────────────────────────────────────────────

    public override SchemaDeploymentGateway.DeploymentPlan buildPlan(
        String targetObject,
        String workflowKey,
        List<SchemaDeploymentGateway.FieldSpec> requestedFields
    ) {
        SchemaDeploymentGateway.DeploymentPlan plan =
            new SchemaDeploymentGateway.DeploymentPlan();
        plan.targetObject = targetObject;
        plan.workflowKey  = workflowKey;

        // Validate object exists
        Map<String, Schema.SObjectType> gd = Schema.getGlobalDescribe();
        if (!gd.containsKey(targetObject)) {
            plan.validationErrors.add('Target object does not exist: ' + targetObject);
            return plan;
        }

        // Field budget check
        Integer existing = countCustomFields(targetObject);
        Integer budgetLimit = getFieldBudgetLimit();
        Integer newFieldCount = 0;

        for (SchemaDeploymentGateway.FieldSpec fs : requestedFields) {
            if (fieldExists(targetObject, fs.fieldApiName)) {
                continue;
            }
            newFieldCount++;
            plan.fields.add(fs);
        }

        if (existing + newFieldCount > budgetLimit) {
            plan.validationErrors.add(
                'Field budget exceeded on ' + targetObject + ': ' +
                existing + ' existing + ' + newFieldCount + ' new > ' +
                budgetLimit + ' limit'
            );
        }

        // Type feasibility — reject unsupported types early
        Set<String> supported = new Set<String>{
            'Text', 'Number', 'Date', 'DateTime', 'Picklist',
            'Checkbox', 'Currency', 'Percent', 'LongTextArea'
        };
        for (SchemaDeploymentGateway.FieldSpec fs : plan.fields) {
            if (!supported.contains(fs.fieldType)) {
                plan.validationErrors.add(
                    'Unsupported field type "' + fs.fieldType +
                    '" for field ' + fs.fieldApiName
                );
            }
        }

        return plan;
    }

    // ── enqueue ────────────────────────────────────────────────────────

    public override SchemaDeploymentGateway.DeploymentResult enqueue(
        Id deploymentRequestId,
        SchemaDeploymentGateway.DeploymentPlan plan
    ) {
        List<String> successIds = new List<String>();
        List<String> errors     = new List<String>();

        for (SchemaDeploymentGateway.FieldSpec fs : plan.fields) {
            // Picklist is validated in the plan but requires valueSet payload
            if (fs.fieldType == 'Picklist') {
                throw new UnsupportedOperationException(
                    'Picklist CustomField creation via Tooling API requires ' +
                    'a valueSet payload \u2014 deferred to a later wave.'
                );
            }

            String body = buildFieldPayload(plan.targetObject, fs);
            String path = '/services/data/' + API_VERSION +
                          '/tooling/sobjects/CustomField';

            HttpResponse resp = invokeToolingApi('POST', path, body);
            Integer statusCode = resp.getStatusCode();

            if (statusCode == 201 || statusCode == 200) {
                Map<String, Object> parsed =
                    (Map<String, Object>) JSON.deserializeUntyped(resp.getBody());
                String fieldId = (String) parsed.get('id');
                successIds.add(fs.fieldApiName + '=' + fieldId);
            } else {
                String errMsg = fs.fieldApiName + ': ' + resp.getBody();
                errors.add(errMsg);
            }
        }

        // Determine outcome
        SchemaDeploymentGateway.DeploymentResult dr =
            new SchemaDeploymentGateway.DeploymentResult();

        if (errors.isEmpty()) {
            dr.status  = 'Completed';
            dr.message = 'All ' + successIds.size() + ' fields created';
        } else if (successIds.isEmpty()) {
            dr.status  = 'Failed';
            dr.message = String.join(errors, '; ');
        } else {
            dr.status  = 'Partial';
            dr.message = successIds.size() + ' succeeded, ' +
                         errors.size() + ' failed: ' + String.join(errors, '; ');
        }

        dr.deploymentId = deploymentRequestId;
        return dr;
    }

    // ── getStatus ──────────────────────────────────────────────────────

    public override SchemaDeploymentGateway.DeploymentResult getStatus(
        Id deploymentRequestId
    ) {
        // Tooling API creates are synchronous — status is already terminal
        // by the time enqueue() returns.  Read persisted state.
        Deployment_Request__c req = [
            SELECT Status__c, Result_JSON__c, Error_Message__c
            FROM   Deployment_Request__c
            WHERE  Id = :deploymentRequestId
            LIMIT  1
        ];

        SchemaDeploymentGateway.DeploymentResult dr =
            new SchemaDeploymentGateway.DeploymentResult();
        dr.status  = req.Status__c;
        dr.message = req.Error_Message__c;
        return dr;
    }

    // ── Private helpers ────────────────────────────────────────────────

    @TestVisible
    private static String buildFieldPayload(
        String targetObject,
        SchemaDeploymentGateway.FieldSpec fs
    ) {
        Map<String, Object> metadata = new Map<String, Object>();

        if (fs.fieldType == 'Text') {
            metadata.put('type', 'Text');
            metadata.put('label', fs.fieldLabel);
            metadata.put('length', fs.length != null ? fs.length : 255);
        } else if (fs.fieldType == 'LongTextArea') {
            metadata.put('type', 'LongTextArea');
            metadata.put('label', fs.fieldLabel);
            metadata.put('length', fs.length != null ? fs.length : 32768);
            metadata.put('visibleLines', 6);
        } else if (fs.fieldType == 'Number') {
            metadata.put('type', 'Number');
            metadata.put('label', fs.fieldLabel);
            metadata.put('precision', fs.precision != null ? fs.precision : 18);
            metadata.put('scale', fs.scale != null ? fs.scale : 0);
        } else if (fs.fieldType == 'Currency') {
            metadata.put('type', 'Currency');
            metadata.put('label', fs.fieldLabel);
            metadata.put('precision', fs.precision != null ? fs.precision : 18);
            metadata.put('scale', fs.scale != null ? fs.scale : 2);
        } else if (fs.fieldType == 'Percent') {
            metadata.put('type', 'Percent');
            metadata.put('label', fs.fieldLabel);
            metadata.put('precision', fs.precision != null ? fs.precision : 5);
            metadata.put('scale', fs.scale != null ? fs.scale : 2);
        } else if (fs.fieldType == 'Date') {
            metadata.put('type', 'Date');
            metadata.put('label', fs.fieldLabel);
        } else if (fs.fieldType == 'DateTime') {
            metadata.put('type', 'DateTime');
            metadata.put('label', fs.fieldLabel);
        } else if (fs.fieldType == 'Checkbox') {
            metadata.put('type', 'Checkbox');
            metadata.put('label', fs.fieldLabel);
            metadata.put('defaultValue', false);
        }

        metadata.put('required', false);

        Map<String, Object> payload = new Map<String, Object>();
        payload.put('FullName', targetObject + '.' + fs.fieldApiName);
        payload.put('Metadata', metadata);

        return JSON.serialize(payload);
    }

    @TestVisible
    private static HttpResponse invokeToolingApi(
        String method, String path, String body
    ) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(NAMED_CREDENTIAL + path);
        req.setMethod(method);
        req.setHeader('Content-Type', 'application/json');
        if (body != null) {
            req.setBody(body);
        }
        return new Http().send(req);
    }
}
