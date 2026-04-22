# Agentic Loop

How Pulse Core Next closes the AI-driven workflow loop: a conversation lands,
the agent wakes, proposes an action, and a human approves it.

## Flow

1. **Inbound signal** — An email arrives (via `PulseInboundEmailHandler`) or a
   Recall.ai bot transcript lands via `ConversationIngestionService`. Both
   produce `Conversation__c` + `Conversation_Turn__c` records.

2. **Trigger fires** — `ConversationTurnAgentTrigger` (after insert on
   `Conversation_Turn__c`) checks whether the conversation's linked
   `Workflow_Instance__c` is in an AI-driven state (a state whose contract
   definition has a non-blank `toolConfig.toolKey`). If yes, it enqueues
   `PulseAgentInvokerQueueable`.

3. **Agent runs** — The queueable calls `PulseAgentRunner.run(instanceId)`,
   which builds a prompt from the instance context, invokes the configured AI
   provider, and processes any returned tool calls.

4. **HITL gate** — When the tool's `hitlPolicy` is `Approval_Required`, the
   runner creates a `Workflow_Action__c` with `Status='Pending'` instead of
   executing immediately. The Action Hub LWC surfaces this to the approver.

5. **Approval + execution** — The approver calls `HitlService.resolveApproval`
   (approve or reject). On approval the tool executes (e.g., `PulseEmailTool`
   sends the email) and the action moves to `Status='Executed'`.

## Configuring Inbound Email

1. In Salesforce Setup, navigate to **Email Services** and create a new service:
   - **Apex Class**: `PulseInboundEmailHandler`
   - **Accept Email From**: configure as needed (or leave blank for all)
   - **Active**: checked

2. Copy the generated email address (e.g., `handler@1abc.in.salesforce.com`).

3. To route replies back to a specific workflow instance, include the tag
   `[Pulse:<instanceId>]` in the subject line of outbound emails. When the
   recipient replies, the handler extracts the instance ID and links the
   conversation automatically.

4. If no tag is present, the handler falls back to contact-based routing:
   it matches the sender's email address against Contact records linked to
   Opportunities via `OpportunityContactRole`, then finds the most recent
   active `Workflow_Instance__c` on that Opportunity.

5. If neither routing method resolves, the conversation is created without a
   workflow link and appears in the Conversation Hub as unattached.

## AI-Driven State Configuration

In the workflow contract JSON, mark a state as AI-driven by adding `toolConfig`:

```json
{
  "key": "intake_qualification",
  "label": "Intake Qualification",
  "type": "ai_driven",
  "toolConfig": {
    "toolKey": "send_email",
    "hitlPolicy": "Approval_Required",
    "parameters": {
      "systemPrompt": "Draft a follow-up email asking for missing qualifying info."
    }
  },
  "transitions": [
    { "signal": "qualified", "to": "credit_review" },
    { "signal": "disqualified", "to": "declined" }
  ]
}
```

The `toolKey` must match a registered `Workflow_Tool_Registration__mdt` record
(or a tool registered via `PulseToolRegistry`). The `hitlPolicy` controls
whether the tool executes autonomously or requires approval.

## Testing Without a Real LLM

Use the test-visible provider override on `PulseAiFacade`:

```apex
// In your @IsTest class:
PulseAiFacade.setProviderForTest(new MyMockProvider());

private class MyMockProvider implements PulseAiProvider {
    public void configure(String nc, String modelId) {}
    public PulseAiModels.Response chat(PulseAiModels.Request req) {
        PulseAiModels.Response resp = new PulseAiModels.Response();
        resp.providerRequestId = 'mock_001';
        resp.usage = new PulseAiModels.Usage();
        resp.usage.inputTokens = 10;
        resp.usage.outputTokens = 5;

        // Return a tool call
        PulseAiModels.ToolCall tc = new PulseAiModels.ToolCall();
        tc.id = 'toolu_mock';
        tc.toolKey = 'send_email';
        tc.inputJson = '{"toAddress":"test@test.com","subject":"Test","body":"Hello"}';
        resp.toolCalls.add(tc);
        return resp;
    }
}
```

Register a stub tool via `PulseToolRegistry.registerToolForTest(key, tool)` to
avoid real side effects.

## Recall.ai Integration

Recall.ai meeting transcripts follow the same path:

1. The Recall webhook delivers a payload to `PulseRecallDispatcher`.
2. `RecallAdapter.normalizePayload()` converts it into
   `PulseConversationModels.ConversationInput`.
3. `ConversationIngestionService.ingest()` creates the `Conversation__c` and
   `Conversation_Turn__c` records.
4. `ConversationTurnAgentTrigger` fires and the agent loop proceeds identically
   to the email path.

No additional configuration is needed beyond the existing Recall adapter setup
documented in `docs/recall-integration-setup.md`.

## Observability

Every agent invocation produces `Workflow_Event__c` audit rows:

| Event Type | Meaning |
|---|---|
| `AI_CALL` | Provider was invoked successfully |
| `AI_ERROR` | Provider returned an error |
| `TOOL_APPROVAL_REQUESTED` | Tool call queued for HITL |
| `TOOL_EXECUTED` | Tool ran successfully |
| `TOOL_REJECTED` | Approver rejected the action |
| `AGENT_COMPLETED` | Queueable finished successfully |
| `AGENT_FAILED` | Queueable caught an exception |
