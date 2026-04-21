/**
 * SchemaProvisioningService
 *
 * Orchestrates schema auto-provisioning for workflow projections.
 * Follows the plan → enqueue model described in architecture doc §4.6:
 *   1. Accept requested field specs for a workflow publish.
 *   2. Delegate plan-building to the pluggable SchemaDeploymentGateway.
 *   3. Persist the plan in Deployment_Request__c.
 *   4. Enqueue async deployment via the gateway.
 *   5. Publish Pulse_Deployment_Status__e on every status transition.
 *
 * This class never performs metadata operations itself — all deployment
 * mechanics are encapsulated in the gateway implementation.
 */
public with sharing class SchemaProvisioningService {

    // ── Testability seams ───────────────────────────────────────────────

    @TestVisible
    private static SchemaDeploymentGateway gatewayOverride;

    /** Allow tests to suppress EventBus.publish */
    @TestVisible
    private static Boolean suppressEvents = false;

    // ── Inner types ─────────────────────────────────────────────────────

    public class ProvisioningResult {
        public Id     deploymentRequestId;
        public String status;
        public String message;
        public List<String> validationErrors;
    }

    // ── Public API ──────────────────────────────────────────────────────

    /**
     * Plan and enqueue a schema deployment for the given workflow definition.
     *
     * @param workflowDefinitionId  lookup to Workflow_Definition__c
     * @param targetObject          API name of the parent object
     * @param workflowKey           stable workflow key for projection scoping
     * @param requestedFields       field specs the publish flow needs provisioned
     * @return result with deployment request id, status, validation errors
     */
    public static ProvisioningResult provision(
        Id     workflowDefinitionId,
        String targetObject,
        String workflowKey,
        List<SchemaDeploymentGateway.FieldSpec> requestedFields
    ) {
        ProvisioningResult result = new ProvisioningResult();
        SchemaDeploymentGateway gw = resolveGateway();

        // 1. Build plan (validates budget, collisions, type feasibility)
        SchemaDeploymentGateway.DeploymentPlan plan = gw.buildPlan(
            targetObject, workflowKey, requestedFields
        );

        // 2. Create Deployment_Request__c in Draft with plan JSON
        Deployment_Request__c req = new Deployment_Request__c(
            Status__c              = 'Draft',
            Target_Object__c       = targetObject,
            Workflow_Definition__c  = workflowDefinitionId,
            Plan_JSON__c           = JSON.serialize(plan),
            Requested_By__c        = UserInfo.getUserId()
        );
        insert req;
        result.deploymentRequestId = req.Id;

        // 3. If plan has validation errors, mark Failed and return early
        if (!plan.isValid()) {
            req.Status__c       = 'Failed';
            req.Error_Message__c = String.join(plan.validationErrors, '\n');
            req.Completed_Date__c = Datetime.now();
            update req;

            result.status           = 'Failed';
            result.message          = 'Plan validation failed';
            result.validationErrors = plan.validationErrors;

            publishStatus(req.Id, 'Failed', result.message, targetObject);
            return result;
        }

        // 4. No fields to deploy — mark Completed immediately
        if (plan.fields == null || plan.fields.isEmpty()) {
            req.Status__c         = 'Completed';
            req.Completed_Date__c = Datetime.now();
            req.Result_JSON__c    = '{"fieldsDeployed":0}';
            update req;

            result.status  = 'Completed';
            result.message = 'No new fields required';

            publishStatus(req.Id, 'Completed', result.message, targetObject);
            return result;
        }

        // 5. Enqueue deployment via gateway
        SchemaDeploymentGateway.DeploymentResult gwResult;
        try {
            gwResult = gw.enqueue(req.Id, plan);
        } catch (Exception ex) {
            req.Status__c        = 'Failed';
            req.Error_Message__c = ex.getMessage();
            req.Completed_Date__c = Datetime.now();
            update req;

            result.status  = 'Failed';
            result.message = 'Enqueue failed: ' + ex.getMessage();

            publishStatus(req.Id, 'Failed', result.message, targetObject);
            return result;
        }

        // 6. Persist gateway response
        req.Status__c      = gwResult.status;
        req.Result_JSON__c = JSON.serialize(new Map<String, String>{
            'deploymentId' => gwResult.deploymentId,
            'message'      => gwResult.message
        });
        if (gwResult.status == 'Completed' || gwResult.status == 'Failed') {
            req.Completed_Date__c = Datetime.now();
            if (gwResult.status == 'Failed') {
                req.Error_Message__c = gwResult.message;
            }
        }
        update req;

        result.status  = gwResult.status;
        result.message = gwResult.message;

        publishStatus(req.Id, gwResult.status, gwResult.message, targetObject);
        return result;
    }

    /**
     * Check and update the status of a previously enqueued deployment.
     * Called by polling jobs or platform-event callbacks.
     */
    public static ProvisioningResult checkStatus(Id deploymentRequestId) {
        ProvisioningResult result = new ProvisioningResult();
        result.deploymentRequestId = deploymentRequestId;

        Deployment_Request__c req = [
            SELECT Id, Status__c, Target_Object__c, Plan_JSON__c
            FROM   Deployment_Request__c
            WHERE  Id = :deploymentRequestId
            LIMIT  1
        ];

        // Terminal states — nothing to poll
        if (req.Status__c == 'Completed' || req.Status__c == 'Failed' ||
            req.Status__c == 'Cancelled') {
            result.status  = req.Status__c;
            result.message = 'Deployment already in terminal state';
            return result;
        }

        SchemaDeploymentGateway gw = resolveGateway();
        SchemaDeploymentGateway.DeploymentResult gwResult = gw.getStatus(deploymentRequestId);

        // Update record if status changed
        if (gwResult.status != req.Status__c) {
            req.Status__c      = gwResult.status;
            req.Result_JSON__c = JSON.serialize(new Map<String, String>{
                'deploymentId' => gwResult.deploymentId,
                'message'      => gwResult.message
            });
            if (gwResult.status == 'Completed' || gwResult.status == 'Failed') {
                req.Completed_Date__c = Datetime.now();
                if (gwResult.status == 'Failed') {
                    req.Error_Message__c = gwResult.message;
                }
            }
            update req;

            publishStatus(
                req.Id, gwResult.status, gwResult.message, req.Target_Object__c
            );
        }

        result.status  = gwResult.status;
        result.message = gwResult.message;
        return result;
    }

    /**
     * Cancel a deployment that has not yet reached a terminal state.
     */
    public static void cancel(Id deploymentRequestId) {
        Deployment_Request__c req = [
            SELECT Id, Status__c, Target_Object__c
            FROM   Deployment_Request__c
            WHERE  Id = :deploymentRequestId
            LIMIT  1
        ];

        if (req.Status__c == 'Completed' || req.Status__c == 'Failed' ||
            req.Status__c == 'Cancelled') {
            return; // already terminal
        }

        req.Status__c         = 'Cancelled';
        req.Completed_Date__c = Datetime.now();
        update req;

        publishStatus(req.Id, 'Cancelled', 'Deployment cancelled by user', req.Target_Object__c);
    }

    // ── Private helpers ─────────────────────────────────────────────────

    private static SchemaDeploymentGateway resolveGateway() {
        if (gatewayOverride != null) {
            return gatewayOverride;
        }
        // Default implementation — Apex Metadata API gateway.
        // Swap this for SOAP wrapper / external deployer by changing
        // this factory method or introducing a Feature_Flag__mdt lookup.
        return new MetadataApiDeploymentGateway();
    }

    private static void publishStatus(
        Id requestId, String status, String message, String targetObject
    ) {
        if (suppressEvents) {
            return;
        }
        Pulse_Deployment_Status__e evt = new Pulse_Deployment_Status__e(
            Deployment_Request_Id__c = requestId,
            Status__c                = status,
            Message__c               = message != null && message.length() > 255
                                         ? message.substring(0, 255)
                                         : message,
            Target_Object__c         = targetObject
        );
        EventBus.publish(evt);
    }

    // ── Default gateway implementation ──────────────────────────────────

    /**
     * Metadata API deployment gateway using Apex Metadata operations.
     *
     * NOTE: This implementation uses Metadata.Operations.enqueueDeployment()
     * which is asynchronous.  Subscriber-org and 2GP behavior MUST be
     * verified manually per architecture doc §4.6 / Correction 4.
     *
     * If this path proves unviable in subscriber orgs, replace this class
     * with an external-deployer or guided-setup gateway — the provisioning
     * service does not need to change.
     */
    @TestVisible
    private class MetadataApiDeploymentGateway extends SchemaDeploymentGateway {

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
                // Skip fields that already exist
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

        public override SchemaDeploymentGateway.DeploymentResult enqueue(
            Id deploymentRequestId,
            SchemaDeploymentGateway.DeploymentPlan plan
        ) {
            Metadata.DeployContainer container = new Metadata.DeployContainer();

            for (SchemaDeploymentGateway.FieldSpec fs : plan.fields) {
                Metadata.CustomField cf = new Metadata.CustomField();
                cf.fullName  = plan.targetObject + '.' + fs.fieldApiName;
                cf.label     = fs.fieldLabel;

                if (fs.fieldType == 'Text') {
                    cf.type   = Metadata.FieldType.Text;
                    cf.length = fs.length != null ? fs.length : 255;
                } else if (fs.fieldType == 'Number') {
                    cf.type      = Metadata.FieldType.Number;
                    cf.precision = fs.precision != null ? fs.precision : 18;
                    cf.scale_x   = fs.scale != null ? fs.scale : 0;
                } else if (fs.fieldType == 'Date') {
                    cf.type = Metadata.FieldType.Date;
                } else if (fs.fieldType == 'DateTime') {
                    cf.type = Metadata.FieldType.DateTime;
                } else if (fs.fieldType == 'Checkbox') {
                    cf.type = Metadata.FieldType.Checkbox;
                } else if (fs.fieldType == 'Currency') {
                    cf.type      = Metadata.FieldType.Currency;
                    cf.precision = fs.precision != null ? fs.precision : 18;
                    cf.scale_x   = fs.scale != null ? fs.scale : 2;
                } else if (fs.fieldType == 'Percent') {
                    cf.type      = Metadata.FieldType.Percent;
                    cf.precision = fs.precision != null ? fs.precision : 5;
                    cf.scale_x   = fs.scale != null ? fs.scale : 2;
                } else if (fs.fieldType == 'LongTextArea') {
                    cf.type           = Metadata.FieldType.LongTextArea;
                    cf.length         = fs.length != null ? fs.length : 32768;
                    cf.visibleLines   = 6;
                } else if (fs.fieldType == 'Picklist') {
                    cf.type = Metadata.FieldType.Picklist;
                    // Picklist values require a ValueSet — handled separately
                    // in the deploy callback or via post-deploy step.
                    // Marking as text-fallback here is the safe default;
                    // the full picklist deploy path requires additional
                    // 2GP verification.
                    cf.type   = Metadata.FieldType.Text;
                    cf.length = 255;
                }

                container.addMetadata(cf);
            }

            // Enqueue async deployment with callback
            // NOTE: Metadata.Operations.enqueueDeployment() is subject to
            // daily Apex Metadata API limits and subscriber-org restrictions.
            // 2GP behavior must be manually verified.
            Id asyncId = Metadata.Operations.enqueueDeployment(
                container,
                new DeploymentCallback(deploymentRequestId)
            );

            SchemaDeploymentGateway.DeploymentResult dr =
                new SchemaDeploymentGateway.DeploymentResult();
            dr.status       = 'Queued';
            dr.message      = 'Metadata deployment enqueued';
            dr.deploymentId = asyncId;
            return dr;
        }

        public override SchemaDeploymentGateway.DeploymentResult getStatus(
            Id deploymentRequestId
        ) {
            // The Apex Metadata API uses a callback pattern rather than
            // poll-based status.  Status is updated by DeploymentCallback
            // on completion.  This method reads the persisted state.
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
    }

    // ── Metadata deploy callback ────────────────────────────────────────

    /**
     * Callback invoked by the platform when Metadata.Operations deployment
     * completes.  Updates Deployment_Request__c and publishes status event.
     */
    public class DeploymentCallback implements Metadata.DeployCallback {
        private Id deploymentRequestId;

        public DeploymentCallback(Id deploymentRequestId) {
            this.deploymentRequestId = deploymentRequestId;
        }

        public void handleResult(
            Metadata.DeployResult result,
            Metadata.DeployCallbackContext context
        ) {
            Deployment_Request__c req = [
                SELECT Id, Status__c, Target_Object__c
                FROM   Deployment_Request__c
                WHERE  Id = :deploymentRequestId
                LIMIT  1
            ];

            if (result != null && result.status == Metadata.DeployStatus.Succeeded) {
                req.Status__c         = 'Completed';
                req.Completed_Date__c = Datetime.now();
                req.Result_JSON__c    = '{"status":"Succeeded"}';
            } else {
                req.Status__c         = 'Failed';
                req.Completed_Date__c = Datetime.now();
                String errMsg = result != null
                    ? 'Deployment failed: ' + result.status
                    : 'Deployment result was null';
                req.Error_Message__c = errMsg;
                req.Result_JSON__c   = '{"status":"Failed"}';
            }
            update req;

            publishStatus(
                req.Id, req.Status__c,
                req.Error_Message__c != null ? req.Error_Message__c : 'Deployment succeeded',
                req.Target_Object__c
            );
        }
    }
}
