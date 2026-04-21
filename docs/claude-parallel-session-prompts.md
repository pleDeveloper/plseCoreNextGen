# Pulse Core Next: Parallel Claude Session Prompts

This file is optimized for running Claude sessions in parallel with minimal merge pain.

## Important first

Not everything should run in parallel. Use **waves**:

1. Wave 0: serial bootstrap
2. Wave 1: parallel backend lanes
3. Wave 2: serial integration
4. Wave 3: parallel UI lanes
5. Wave 4: serial packaging hardening

Run Wave 0 context lock first:
- `docs/claude-wave0-context-lock.md`

## Recommended workspace layout for parallel runs

Use separate folder copies for each lane:

```bash
mkdir -p /tmp/pulse-core-next-lanes
rsync -a --delete /Users/damianmosiolek/pulse-nextgen/ /tmp/pulse-core-next-lanes/lane-a/
rsync -a --delete /Users/damianmosiolek/pulse-nextgen/ /tmp/pulse-core-next-lanes/lane-b/
rsync -a --delete /Users/damianmosiolek/pulse-nextgen/ /tmp/pulse-core-next-lanes/lane-c/
rsync -a --delete /Users/damianmosiolek/pulse-nextgen/ /tmp/pulse-core-next-lanes/lane-d/
```

Use one Claude terminal per lane in that lane folder.

## Global preamble (paste at top of every Claude lane)

```text
You are implementing Pulse Core Next.

Project context:
- Namespace: plse
- Scratch org alias: pulse-core-next-dev
- Dev Hub alias: PulseDevHub

Hard constraints:
1) Never introduce ple namespace in new code.
2) Do not edit files outside your lane ownership list.
3) Use Named Credentials for external callouts.
4) Apex must be bulk-safe and governor-safe.
5) Return only: files changed, tests added, deploy/test commands.
```

## Wave 0 (serial) — Bootstrap foundation

Paste:

```text
Implement foundation metadata only.

Create or update:
- Workflow_Definition__c
- Workflow_Instance__c
- Workflow_Step_Result__c
- Workflow_Event__c
- Workflow_Action__c
- Deployment_Request__c
- Conversation__c
- Conversation_Turn__c
- Conversation_Extract__c

Add migration hooks where relevant:
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

Add permission sets:
- Pulse_Core_Admin
- Pulse_Runtime_User

Do not implement business logic classes in this step.
```

Then:

```bash
sf project deploy start -o pulse-core-next-dev
```

## Wave 1 (parallel backend lanes)

Run all four lanes at once after Wave 0 completes.

### Lane A prompt — Contract + Runtime core

Paste:

```text
Lane ownership:
- WorkflowContract.cls
- WorkflowAdvanceRequest.cls
- WorkflowRuntime.cls
- tests for the above

Do not edit:
- ProjectionWriteService
- SchemaProvisioningService
- AI/Tool classes
- Conversation classes
- LWC files

Task:
Implement core runtime transition engine.

Required behavior:
1) Parse and validate pulse.workflow.v1 contract.
2) Bulk entry: advance(List<WorkflowAdvanceRequest> requests).
3) Bulk load instances/definitions.
4) Validate transitions and signals.
5) Persist Workflow_Step_Result__c and Workflow_Event__c.
6) Update Workflow_Instance__c current state.

Add a clear extension point method in WorkflowRuntime for projection and AI hooks, but do not implement those hooks.

Tests:
- valid transition
- invalid signal
- mixed batch
- idempotent retry guard
```

### Lane B prompt — Projection + schema deployment plan

Paste:

```text
Lane ownership:
- ProjectionWriteService.cls
- SchemaDeploymentGateway.cls
- SchemaProvisioningService.cls
- deployment status event metadata
- tests for these classes

Do not edit:
- WorkflowRuntime.cls
- AI/Tool classes
- Conversation classes
- LWC files

Task:
Implement projection and schema provisioning services.

Projection behavior:
- map field keys to parent fields via Workflow_Projection__mdt
- type compatibility checks
- object/field allowlist checks
- shared vs workflow-scoped precedence
- audit to Workflow_Event__c

Schema behavior:
- plan + enqueue model via Deployment_Request__c
- status publication
- swappable gateway abstraction

Do not wire into WorkflowRuntime in this lane.
```

### Lane C prompt — AI + tools + HITL

Paste:

```text
Lane ownership:
- PulseAiProvider.cls
- AnthropicAdapter.cls
- PulseTool.cls
- PulseToolRegistry.cls
- PulseEmailTool.cls
- PulseRecordUpdateTool.cls
- PulseExternalApiTool.cls
- HitlService.cls
- PulseAgentRunner.cls
- PulseAiFacade.cls
- tests for these classes

Do not edit:
- WorkflowRuntime.cls
- ProjectionWriteService.cls
- Conversation classes
- LWC files

Task:
Implement AI execution plane.

Behavior:
- AI suggests tool calls
- platform validates schema + policy
- autonomous executes
- approval-required creates Workflow_Action__c and pauses
- audit to Workflow_Event__c

Use Named Credentials for Anthropic and external tools.

Do not wire runtime callbacks in this lane.
```

### Lane D prompt — Conversation ingestion + extraction

Paste:

```text
Lane ownership:
- ConversationIngestionService.cls
- PulseConversationExtractor.cls
- RecallAdapter.cls
- PulseRecallDispatcher.cls
- tests for these classes

Do not edit:
- WorkflowRuntime.cls
- ProjectionWriteService.cls
- AI/Tool core classes
- LWC files

Task:
Implement conversation ingestion and extraction services.

Behavior:
- normalize inbound email/call/meeting into Conversation__c + Conversation_Turn__c
- extraction profile execution into Conversation_Extract__c
- confidence and source-reference persistence
- no direct parent field writes from extraction
```

## Wave 2 (serial) — Integrate backend lanes

After copying lane results back into main workspace, run this single integration prompt:

```text
Integrate previously implemented backend lanes.

Task:
1) Wire WorkflowRuntime extension points to:
   - ProjectionWriteService
   - optional AI/HITL trigger path (where applicable)
2) Ensure Conversation extraction outputs are consumable by runtime/UI verification flow.
3) Resolve compile/runtime conflicts across runtime, projection, AI, and conversation services.
4) Keep separation of concerns intact.

Add integration-focused tests for:
- runtime + projection interaction
- runtime + HITL action creation path
- extraction output handoff contract
```

Then:

```bash
sf project deploy start -o pulse-core-next-dev
sf apex run test -o pulse-core-next-dev --test-level RunLocalTests --wait 30
```

## Wave 3 (parallel UI lanes)

### Lane E prompt — Admin UI

Paste:

```text
Lane ownership:
- pulseAdminStudio
- pulseWorkflowCanvas
- pulseIntegrationsHub
- supporting Apex controllers for these components

Do not edit:
- pulseWorkflowInstanceViewer
- pulseConversationHub
- pulseActionHub

Task:
Build admin-side shells and controller wiring with real Apex methods.
No fake production data.
```

### Lane F prompt — Runtime UI

Paste:

```text
Lane ownership:
- pulseWorkflowInstanceViewer
- pulseActionHub
- supporting Apex controllers for these components

Do not edit:
- pulseAdminStudio
- pulseWorkflowCanvas
- pulseIntegrationsHub
- pulseConversationHub

Task:
Build runtime-side UI.
Stepper must render completed/current/pending/blocked states and support verify-before-advance.
```

### Lane G prompt — Conversation UI

Paste:

```text
Lane ownership:
- pulseConversationHub
- supporting Apex controllers for conversation inbox/viewer

Do not edit:
- pulseWorkflowInstanceViewer
- pulseActionHub
- admin studio components

Task:
Build conversation inbox/viewer shell with transcript + extraction display and action hooks.
No direct field commits from extraction without verification flow.
```

## Wave 4 (serial) — Packaging hardening

Paste:

```text
Perform package hardening for Pulse Core Next.

Deliver:
1) package directory split recommendation (core + addons)
2) visibility fixes (public/global)
3) namespace safety fixes
4) dependency map
5) exact package create + package version create command set
6) release risk register (top blockers first)

Never create artifacts under ple.
```

## Validation after each wave

```bash
sf project deploy start -o pulse-core-next-dev
sf apex run test -o pulse-core-next-dev --test-level RunLocalTests --wait 30
```

## Merge note (important)

Since this repo is not currently git-initialized, parallel lane integration is manual file copy/compare.
For safer parallel execution, initialize git before lane work and merge lane outputs with branches.
