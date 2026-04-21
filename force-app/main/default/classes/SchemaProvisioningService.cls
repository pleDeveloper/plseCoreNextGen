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
        if (gwResult.status == 'Completed' || gwResult.status == 'Failed' ||
            gwResult.status == 'Partial') {
            req.Completed_Date__c = Datetime.now();
            if (gwResult.status == 'Failed' || gwResult.status == 'Partial') {
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
            req.Status__c == 'Cancelled' || req.Status__c == 'Partial') {
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
        // Default implementation — Tooling API REST gateway.
        // See architecture doc §4.6 Correction 4: Apex Metadata.CustomField
        // is not available in this org; we use the Tooling API via a
        // Named Credential self-org callout instead.
        return new ToolingApiDeploymentGateway();
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

}
