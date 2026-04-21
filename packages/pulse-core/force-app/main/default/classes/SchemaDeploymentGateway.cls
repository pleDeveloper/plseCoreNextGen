/**
 * SchemaDeploymentGateway
 *
 * Swappable abstraction for metadata deployment.  The provisioning service
 * programs against this interface so the underlying mechanism (Apex Metadata
 * API, SOAP wrapper, external deployer, guided-setup generator) can be
 * changed without touching business logic.
 *
 * IMPORTANT: Subscriber-org / 2GP behaviour of each implementation MUST be
 * manually verified in scratch-org and packaging-org environments before
 * relying on it in production publishing flows.
 */
global abstract class SchemaDeploymentGateway {

    // ── Inner types ─────────────────────────────────────────────────────

    /** One field to be created or verified on a target object. */
    global class FieldSpec {
        global String objectApiName;
        global String fieldApiName;
        global String fieldLabel;
        global String fieldType;   // Text, Number, Date, DateTime, Picklist, Checkbox, Currency, Percent, LongTextArea
        global Integer length;     // for Text / LongTextArea
        global Integer precision;  // for Number / Currency / Percent
        global Integer scale;      // for Number / Currency / Percent
        global List<String> picklistValues;
    }

    /** Complete deployment plan — serialised to Deployment_Request__c.Plan_JSON__c. */
    global class DeploymentPlan {
        global String targetObject;
        global String workflowKey;
        global List<FieldSpec> fields;
        global List<String> validationErrors;

        global DeploymentPlan() {
            this.fields = new List<FieldSpec>();
            this.validationErrors = new List<String>();
        }

        global Boolean isValid() {
            return validationErrors == null || validationErrors.isEmpty();
        }
    }

    /** Result of an enqueue or status-check call. */
    global class DeploymentResult {
        global String status;      // Queued, In_Progress, Completed, Failed
        global String message;
        global String deploymentId; // platform-specific async id when available
    }

    // ── Abstract contract ───────────────────────────────────────────────

    /**
     * Build a deployment plan for the given field specs.
     * Validates field budget, collision detection, and type feasibility.
     * Does NOT execute the deployment.
     */
    global abstract DeploymentPlan buildPlan(
        String targetObject,
        String workflowKey,
        List<FieldSpec> requestedFields
    );

    /**
     * Enqueue the plan for asynchronous deployment.
     * Implementation must update the Deployment_Request__c status to Queued
     * and return a result with the async tracking id when available.
     */
    global abstract DeploymentResult enqueue(
        Id deploymentRequestId,
        DeploymentPlan plan
    );

    /**
     * Poll or derive current status of a previously enqueued deployment.
     */
    global abstract DeploymentResult getStatus(Id deploymentRequestId);

    // ── Shared helpers available to all implementations ──────────────────

    /**
     * Count existing custom fields on an object.  Used by implementations
     * for field-budget validation.  The Salesforce platform limit is
     * typically 500 custom fields per object (varies by edition).
     */
    protected Integer countCustomFields(String objectApiName) {
        Schema.SObjectType sot = Schema.getGlobalDescribe().get(objectApiName);
        if (sot == null) {
            return -1; // object not found
        }
        Integer count = 0;
        for (Schema.SObjectField f : sot.getDescribe().fields.getMap().values()) {
            if (f.getDescribe().isCustom()) {
                count++;
            }
        }
        return count;
    }

    /**
     * Check whether a specific field API name already exists on an object.
     */
    protected Boolean fieldExists(String objectApiName, String fieldApiName) {
        Schema.SObjectType sot = Schema.getGlobalDescribe().get(objectApiName);
        if (sot == null) {
            return false;
        }
        return sot.getDescribe().fields.getMap().containsKey(fieldApiName.toLowerCase());
    }

    /** Hard budget ceiling — conservative default, can be overridden. */
    protected virtual Integer getFieldBudgetLimit() {
        return 500;
    }
}
