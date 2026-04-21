# Pulse Core Next: Claude Orchestration Playbook

Use this playbook to drive Claude Code in controlled increments for `Pulse Core Next` on namespace `plse`.

## 0) Runtime Context (fixed for all sessions)

- Project: `pulse-core-next`
- Namespace target: `plse`
- Dev Hub alias: `PulseDevHub`
- Scratch org alias: `pulse-core-next-dev`
- Packaging intent:
  - `core` => managed 2GP (`plse`)
  - `addons/*` => separate packages (managed or namespaced unlocked)

## 1) Golden Rules for Claude

Paste this at the start of every Claude session:

```text
You are implementing Pulse Core Next in Salesforce with strict packaging discipline.

Constraints:
1) Namespace is plse. Never introduce ple namespace in new code.
2) Do not hardcode namespace prefixes in logic unless unavoidable for metadata identifiers.
3) Keep code/package boundaries modular for 2GP core + add-ons.
4) Bulkification and governor-safety are mandatory for all Apex services.
5) Use Named Credentials for all external callouts.
6) For AI execution, Claude proposes tool calls but platform code enforces policy and executes.
7) Do not edit unrelated files.
8) Provide tests with every Apex subsystem.

When uncertain, ask for one focused clarification instead of guessing.
```

## 2) Execution Order (do not reorder)

1. Foundation metadata (objects, fields, CMDT, permissions)
2. Core workflow contract + runtime
3. Projection and schema deployment abstraction
4. AI provider + tool registry + HITL
5. Conversation ingestion + extraction
6. Channel adapters (Slack) and ingress security
7. Admin Studio shell + Stepper + hubs
8. Packaging hardening + version pipeline

## 3) Session-by-Session Claude Prompts

### Session A — Foundation

```text
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

Return:
1) files changed
2) deployment command
3) any metadata type not yet package-compatible
```

Deploy after Session A:

```bash
sf project deploy start -o pulse-core-next-dev
```

### Session B — Contract + Runtime

```text
Implement core runtime classes with tests.

Create:
- WorkflowContract.cls (parse + validate for pulse.workflow.v1)
- WorkflowAdvanceRequest.cls
- WorkflowRuntime.cls with bulk entry:
  advance(List<WorkflowAdvanceRequest> requests)

Behavior:
1) load instances + pinned definitions in bulk
2) parse each definition once per transaction
3) validate signal transition
4) write Workflow_Step_Result__c
5) update Workflow_Instance__c current state
6) append Workflow_Event__c audit rows

Requirements:
- governor-safe for 200 records
- no callouts
- deterministic error handling

Tests:
- valid transition
- invalid signal
- mixed-batch processing
- idempotent retry guard
```

Run tests after Session B:

```bash
sf apex run test -o pulse-core-next-dev --test-level RunLocalTests --wait 15
```

### Session C — Projection + Schema Deployment Gateway

```text
Implement projection writes and schema deployment abstraction.

Create:
- ProjectionWriteService.cls
- SchemaDeploymentGateway.cls (interface/abstraction)
- SchemaProvisioningService.cls
- Pulse_Deployment_Status__e (platform event metadata if not present)

Projection behavior:
- map workflow field keys to parent fields via Workflow_Projection__mdt
- validate object + field allowlist
- enforce type compatibility
- support shared vs workflow-scoped precedence
- write success/failure to Workflow_Event__c

Schema behavior:
- build deployment plan in Deployment_Request__c
- enqueue async execution via gateway
- publish status events

Do not assume one metadata API mechanism only; keep gateway swappable.

Provide tests for projection and deployment-plan state transitions.
```

### Session D — AI + Tools + HITL

```text
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

Behavior:
- model suggests tool calls
- platform validates tool schema + policy
- autonomous tools execute directly
- approval-required tools create Workflow_Action__c and pause
- all actions audited in Workflow_Event__c

Tests:
- valid tool call
- policy block
- approval required flow
- malformed AI output
```

### Session E — Conversation Intelligence

```text
Implement conversation ingestion and extraction.

Create:
- ConversationIngestionService.cls
- PulseConversationExtractor.cls
- RecallAdapter.cls
- PulseRecallDispatcher.cls

Behavior:
- normalize email/call/meeting into Conversation__c + Conversation_Turn__c
- run extraction profile and write Conversation_Extract__c
- store confidence + source references
- do not auto-write projected parent fields from extraction without verification

Tests:
- ingestion create path
- duplicate external-source handling
- extraction success/failure paths
- recall dispatch rule filtering
```

### Session F — Channels + Slack Ingress

```text
Implement omnichannel adapter layer with Slack.

Create:
- PulseChannelAdapter.cls (interface)
- PulseUiPayload.cls
- SlackChannelAdapter.cls
- PulseChannelRouter.cls (REST)

Security requirements:
- verify Slack HMAC signature
- reject replayed timestamp windows
- map authorized action -> WorkflowRuntime.advance

Tests:
- valid signature path
- invalid signature reject
- replay reject
- valid action advances workflow
```

### Session G — UI Layer (Admin + Runtime)

```text
Implement LWC shells and Apex controllers.

Create:
- pulseAdminStudio (navigation shell)
- pulseWorkflowCanvas (builder shell + publish trigger)
- pulseIntegrationsHub
- pulseWorkflowInstanceViewer (record-page stepper)
- pulseConversationHub (inbox + viewer shell)
- pulseActionHub

Also create needed Apex controllers with @AuraEnabled methods.

Constraints:
- preserve existing org UX conventions
- no fake data in final wiring
- stepper must show completed/current/pending/blocked states
- support AI prefill highlighting and human verify-before-advance
```

### Session H — Packaging Hardening

```text
Perform package hardening and CI-readiness pass.

Deliver:
1) package directory layout recommendation (core + addons)
2) any visibility fixes (public/global)
3) namespace safety fixes
4) dependency map
5) package-create and package-version-create command set
6) test gaps and risk register
```

## 4) Commands You Run Between Sessions

Deploy:

```bash
sf project deploy start -o pulse-core-next-dev
```

Run tests:

```bash
sf apex run test -o pulse-core-next-dev --test-level RunLocalTests --wait 20
```

Open org:

```bash
sf org open -o pulse-core-next-dev
```

## 5) Definition of Done for v0 (core slice)

- Workflow definition publish + instance advance works on namespaced org (`plse`).
- Step results/events persisted and reportable.
- Projection writes function with guardrails.
- One AI tool (`send_email`) works through HITL.
- Conversation extract path can prefill step UI (verification required).
- Slack action ingress can securely trigger state advance.
- All implemented Apex has passing local tests.

## 6) Practical Guardrails

- Never create any new package artifact under `ple`.
- Keep all external callouts behind Named Credentials.
- Keep deployment abstractions swappable; do not lock into one metadata deployment mechanism in first pass.
- If a session gets broad, split it and keep each Claude run under one bounded subsystem.
