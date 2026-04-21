/**
 * Request DTO for WorkflowRuntime.advance().
 * Each instance represents a single signal to advance one workflow instance.
 */
public class WorkflowAdvanceRequest {

    public Id instanceId;
    public String signal;
    public String payloadJson;
    public String actorType;
    public Id actorUserId;
    public String idempotencyKey;

    public WorkflowAdvanceRequest() {}

    public WorkflowAdvanceRequest(Id instanceId, String signal) {
        this.instanceId = instanceId;
        this.signal = signal;
    }
}
