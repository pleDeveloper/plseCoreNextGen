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
public abstract class SchemaDeploymentGateway {

    // ── Inner types ─────────────────────────────────────────────────────

    /** One field to be created or verified on a target object. */
    public class FieldSpec {
        public String objectApiName;
        public String fieldApiName;
        public String fieldLabel;
        public String fieldType;   // Text, Number, Date, DateTime, Picklist, Checkbox, Currency, Percent, LongTextArea
        public Integer length;     // for Text / LongTextArea
        public Integer precision;  // for Number / Currency / Percent
        public Integer scale;      // for Number / Currency / Percent
        public List<String> picklistValues;
    }

    /** Complete deployment plan — serialised to Deployment_Request__c.Plan_JSON__c. */
    public class DeploymentPlan {
        public String targetObject;
        public String workflowKey;
        public List<FieldSpec> fields;
        public List<String> validationErrors;

        public DeploymentPlan() {
            this.fields = new List<FieldSpec>();
            this.validationErrors = new List<String>();
        }

        public Boolean isValid() {
            return validationErrors == null || validationErrors.isEmpty();
        }
    }

    /** Result of an enqueue or status-check call. */
    public class DeploymentResult {
        public String status;      // Queued, In_Progress, Completed, Failed
        public String message;
        public String deploymentId; // platform-specific async id when available
    }

    // ── Abstract contract ───────────────────────────────────────────────

    /**
     * Build a deployment plan for the given field specs.
     * Validates field budget, collision detection, and type feasibility.
     * Does NOT execute the deployment.
     */
    public abstract DeploymentPlan buildPlan(
        String targetObject,
        String workflowKey,
        List<FieldSpec> requestedFields
    );

    /**
     * Enqueue the plan for asynchronous deployment.
     * Implementation must update the Deployment_Request__c status to Queued
     * and return a result with the async tracking id when available.
     */
    public abstract DeploymentResult enqueue(
        Id deploymentRequestId,
        DeploymentPlan plan
    );

    /**
     * Poll or derive current status of a previously enqueued deployment.
     */
    public abstract DeploymentResult getStatus(Id deploymentRequestId);

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
