# Pulse Core Next: Paste-Ready Claude Session Prompts

This is the exact text to paste into Claude for each session.

## One-Time Setup (run once in terminal)

```bash
sf org display -o pulse-core-next-dev
```

If that fails, fix auth before starting Claude sessions.

## Session 1 (Foundation Metadata)

Paste this entire block:

```text
You are implementing Pulse Core Next in Salesforce with strict packaging discipline.

Project context:
- Project name: pulse-core-next
- Namespace: plse
- Scratch org alias: pulse-core-next-dev
- Dev Hub alias: PulseDevHub
- Package strategy: managed 2GP core + separate add-ons

Hard constraints:
1) Never introduce ple namespace in new code.
2) Do not hardcode namespace prefixes in runtime logic unless unavoidable for metadata identifiers.
3) Keep boundaries modular for 2GP core and add-ons.
4) Bulkification and governor-safety are mandatory for Apex.
5) Use Named Credentials for external callouts.
6) Do not edit unrelated files.
7) Provide tests with each Apex subsystem.

Task:
Implement foundation metadata for Pulse Core Next.

Create or update metadata for:
- Workflow_Definition__c
- Workflow_Instance__c
- Workflow_Step_Result__c
- Workflow_Event__c
- Workflow_Action__c
- Deployment_Request__c
- Conversation__c
- Conversation_Turn__c
- Conversation_Extract__c

Add migration hook fields where relevant:
- External_Source__c
- External_Source_Id__c
- Migration_Batch_Id__c

Create CMDT:
- Workflow_Projection__mdt
- Workflow_Tool_Registration__mdt
- AI_Provider_Registration__mdt
- Conversation_Source_Registration__mdt
- Extraction_Profile__mdt
- Calendar_Auto_Dispatch_Rule__mdt
- Channel_Adapter_Registration__mdt
- Feature_Flag__mdt

Add minimum permission sets:
- Pulse_Core_Admin
- Pulse_Runtime_User

Output format:
1) Files changed
2) Deployment command
3) Any metadata type not yet package-compatible
```

Then run:

```bash
sf project deploy start -o pulse-core-next-dev
```

## Session 2 (Workflow Contract + Runtime)

Paste this entire block:

```text
Continue Pulse Core Next implementation in the same repository.

Hard constraints:
1) Namespace is plse.
2) No ple namespace in new code.
3) Governor-safe and bulk-safe Apex only.
4) Do not edit unrelated files.
5) Add tests.

Task:
Implement core runtime classes with tests.

Create:
- WorkflowContract.cls (parse + validate for pulse.workflow.v1)
- WorkflowAdvanceRequest.cls
- WorkflowRuntime.cls with bulk entry:
  advance(List<WorkflowAdvanceRequest> requests)

Required behavior:
1) Load instances and pinned definitions in bulk.
2) Parse each definition once per transaction.
3) Validate signal transition.
4) Write Workflow_Step_Result__c.
5) Update Workflow_Instance__c current state.
6) Append Workflow_Event__c audit rows.

Requirements:
- Governor-safe for 200 records.
- No callouts in runtime transition path.
- Deterministic error handling.

Tests must include:
- Valid transition.
- Invalid signal.
- Mixed-batch processing.
- Idempotent retry guard.

Output:
1) Files changed
2) Test classes and coverage impact
3) Command to run tests
```

Then run:

```bash
sf apex run test -o pulse-core-next-dev --test-level RunLocalTests --wait 20
```

## Session 3 (Projection + Schema Deployment Abstraction)

Paste this entire block:

```text
Continue Pulse Core Next implementation.

Hard constraints:
1) Namespace is plse.
2) Keep deployment mechanism abstract; do not hardcode one irreversible metadata path.
3) No unrelated file edits.
4) Add tests.

Task:
Implement projection writes and schema deployment abstraction.

Create:
- ProjectionWriteService.cls
- SchemaDeploymentGateway.cls (interface/abstraction)
- SchemaProvisioningService.cls
- Pulse_Deployment_Status__e metadata if not present

Projection behavior:
- Map workflow field keys to parent fields using Workflow_Projection__mdt.
- Validate object + field allowlist.
- Enforce type compatibility.
- Support shared vs workflow-scoped precedence.
- Write success/failure to Workflow_Event__c.

Schema behavior:
- Build deployment plan in Deployment_Request__c.
- Enqueue async execution via gateway.
- Publish status events.

Tests:
- Projection mapping happy path.
- Type mismatch failure.
- Shared precedence behavior.
- Deployment request state transitions.

Output:
1) Files changed
2) What is production-ready vs spike-only
3) Deploy/test commands
```

Then run:

```bash
sf project deploy start -o pulse-core-next-dev
sf apex run test -o pulse-core-next-dev --test-level RunLocalTests --wait 20
```

## Session 4 (AI Provider + Tools + HITL)

Paste this entire block:

```text
Continue Pulse Core Next implementation.

Hard constraints:
1) Namespace is plse.
2) Use Named Credentials for external calls.
3) AI proposes tool calls; platform validates and executes.
4) No unrelated edits.
5) Add tests.

Task:
Implement AI execution plane.

Create:
- PulseAiProvider.cls (interface)
- AnthropicAdapter.cls (Named Credential based)
- PulseTool.cls (interface)
- PulseToolRegistry.cls
- PulseEmailTool.cls (Salesforce native email)
- PulseRecordUpdateTool.cls
- PulseExternalApiTool.cls
- HitlService.cls
- PulseAgentRunner.cls
- PulseAiFacade.cls

Required behavior:
- Model suggests tool calls.
- Platform validates tool schema and policy.
- Autonomous tools execute directly.
- Approval-required tools create Workflow_Action__c and pause.
- All actions audited in Workflow_Event__c.

Tests:
- Valid tool call execution.
- Policy-blocked tool call.
- Approval-required flow.
- Malformed AI output handling.

Output:
1) Files changed
2) Required Named Credentials and metadata
3) Test command
```

Then run:

```bash
sf project deploy start -o pulse-core-next-dev
sf apex run test -o pulse-core-next-dev --test-level RunLocalTests --wait 20
```

## Session 5 (Conversation Intelligence)

Paste this entire block:

```text
Continue Pulse Core Next implementation.

Hard constraints:
1) Namespace is plse.
2) No direct projection writes from extraction without human verification.
3) No unrelated edits.
4) Add tests.

Task:
Implement conversation ingestion and extraction.

Create:
- ConversationIngestionService.cls
- PulseConversationExtractor.cls
- RecallAdapter.cls
- PulseRecallDispatcher.cls

Required behavior:
- Normalize email/call/meeting into Conversation__c and Conversation_Turn__c.
- Run extraction profile and write Conversation_Extract__c.
- Store confidence and source references.
- Keep extracted values as reviewable suggestions, not auto-committed parent fields.

Tests:
- Ingestion create path.
- Duplicate external-source handling.
- Extraction success/failure paths.
- Recall dispatch rule filtering.

Output:
1) Files changed
2) Any missing source adapter metadata
3) Test command
```

Then run:

```bash
sf project deploy start -o pulse-core-next-dev
sf apex run test -o pulse-core-next-dev --test-level RunLocalTests --wait 20
```

## Session 6 (Slack Channels + Secure Ingress)

Paste this entire block:

```text
Continue Pulse Core Next implementation.

Hard constraints:
1) Namespace is plse.
2) Verify Slack signature and replay window.
3) No unrelated edits.
4) Add tests.

Task:
Implement omnichannel adapter layer with Slack.

Create:
- PulseChannelAdapter.cls (interface)
- PulseUiPayload.cls
- SlackChannelAdapter.cls
- PulseChannelRouter.cls (REST ingress)

Security requirements:
- Verify Slack HMAC signature.
- Reject replayed timestamps.
- Map authorized action to WorkflowRuntime.advance.

Tests:
- Valid signature accepted.
- Invalid signature rejected.
- Replay attempt rejected.
- Valid action advances workflow.

Output:
1) Files changed
2) Required org config for Slack secret storage
3) Test command
```

Then run:

```bash
sf project deploy start -o pulse-core-next-dev
sf apex run test -o pulse-core-next-dev --test-level RunLocalTests --wait 20
```

## Session 7 (UI Shells + Controllers)

Paste this entire block:

```text
Continue Pulse Core Next implementation.

Hard constraints:
1) Namespace is plse.
2) Wire real Apex data paths; no fake hardcoded production data.
3) Do not break existing metadata.
4) No unrelated edits.

Task:
Implement LWC shells and Apex controllers.

Create:
- pulseAdminStudio (navigation shell)
- pulseWorkflowCanvas (builder shell + publish trigger)
- pulseIntegrationsHub
- pulseWorkflowInstanceViewer (record-page stepper)
- pulseConversationHub (inbox + viewer shell)
- pulseActionHub

Create required Apex controllers with @AuraEnabled methods.

Required UI behavior:
- Stepper shows completed/current/pending/blocked states.
- AI prefill highlighting exists.
- Human verify-before-advance path exists.

Output:
1) Files changed
2) Wiring map: each LWC -> controller methods
3) Deploy command
```

Then run:

```bash
sf project deploy start -o pulse-core-next-dev
```

## Session 8 (Packaging Hardening + CI Commands)

Paste this entire block:

```text
Perform package hardening and CI-readiness pass for Pulse Core Next.

Provide:
1) Package directory layout recommendation for core + addons.
2) Visibility fixes required (public/global).
3) Namespace safety fixes required.
4) Dependency map.
5) Exact package create + package version create commands.
6) Test and release risk register with top blockers first.

Constraints:
- Do not create package artifacts under ple.
- Keep core packaging intent as managed 2GP under plse.
- Keep output concise and actionable.
```

## Final Validation Commands (after Session 8)

```bash
sf project deploy start -o pulse-core-next-dev
sf apex run test -o pulse-core-next-dev --test-level RunLocalTests --wait 30
sf org open -o pulse-core-next-dev
```

## Optional Claude CLI Form (single-turn execution per session)

If you prefer non-interactive runs:

```bash
~/.local/bin/claude -p "<PASTE_SESSION_PROMPT_HERE>"
```

For interactive:

```bash
~/.local/bin/claude
```
