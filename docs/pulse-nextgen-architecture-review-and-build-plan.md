# Pulse Next-Gen Architecture Review and Build Orchestration Plan

Date: 2026-04-21  
Workspace: `/Users/damianmosiolek/pulse-nextgen`

## 1. Top-Line Verdict

The direction is strong, but the conversation drifted into “magic UI solves platform complexity” more than I would allow in an implementation blueprint. The core idea is sound: portable JSON definitions, native Salesforce runtime state, a record-page workflow stepper, a dedicated admin configuration studio, and AI as a governed workflow actor. The dangerous assumptions are schema auto-provisioning, FLS/page-layout automation, agentic tool execution, Slack ingress security, and Recall/calendar automation.

The build can start, but only if Phase 0 is recast as a proof of the hard platform seams, not as “build the entire app.” The first milestone must prove that a managed package can provision subscriber-org fields, permissions, layouts, and projection mappings in a way that is testable, supportable, and reversible.

## 2. What the Conversation Got Right

### Definition vs. Runtime State

This is the strongest architectural move. The workflow definition should be a portable JSON contract, while runtime execution should live in typed Salesforce objects. That avoids v1’s wide-table failure while keeping admins inside native reports, list views, dashboards, and record pages.

### Admin Studio vs. End-User Runtime

The correction that the SPA is only for admins matters. End users should not live in the workflow configurator. They should work from standard Salesforce records, with a Pulse LWC that shows completed steps, current steps, blocked steps, AI suggestions, and future steps.

### AI as an Actor, Not a Separate System

The AI agent should enter the same state machine as humans and channels. A human form submit, Slack button click, inbound email, Recall transcript extraction, or Claude tool-call result should all produce workflow signals handled by `WorkflowRuntime`.

### OOTB Salesforce Email First

Using Salesforce native outbound email and inbound email services is the correct default. Custom Microsoft Graph/Gmail OAuth should not be Phase 0 unless a customer requirement forces it.

## 3. Hard Corrections to the Current Blueprint

### Correction 1: “Greenfield” Cannot Mean “No Migration Ever”

Greenfield should mean: v2 is optimized for net-new customers and does not carry v1 runtime compatibility in the mainline engine.

It should not mean: migration is impossible or ignored.

Required design rule:

- Add `External_Source__c`, `External_Source_Id__c`, and `Migration_Batch_Id__c` to core runtime objects.
- Keep legacy import tooling out of Phase 0 runtime.
- Create a later “migration pack” that maps v1 records into v2 objects.

### Correction 2: “SPA” Means Admin Studio Only

The Admin Configuration Studio can behave like a single-page application inside Salesforce. The end-user experience should be standard record-page LWCs, utility bar components, console tabs, and optional Slack/Teams surfaces.

Required UI boundary:

- `pulseAdminStudio`: admin-only workflow builder, integrations hub, AI config, publish/deploy flow.
- `pulseWorkflowInstanceViewer`: end-user record-page stepper.
- `pulseActionHub`: global user queue.
- `pulseConversationHub`: inbox and transcript/extraction review.

### Correction 3: Schema Auto-Provisioning Is a Product, Not a Helper Class

The conversation treated auto-field creation as a small Apex service. It is actually one of the hardest products in the system.

It must include:

- Draft schema plan.
- Field limit budget per object.
- Collision detection.
- Type compatibility.
- FLS and permission-set assignment.
- Page layout or dynamic form placement strategy.
- Deployment status tracking.
- Rollback/abandon behavior.
- Subscriber org permission handling.
- Audit trail.

Phase 0 must prove this before the rest of the system depends on it.

### Correction 4: Do Not Assume Native Apex `Metadata.CustomField` Is Enough

The blueprint must explicitly say:

> Field auto-provisioning will use a spike-proven deployment mechanism. Candidate paths are native Apex Metadata API, SOAP Metadata API via Apex wrapper, Tooling/Metadata API through an external deployer service, or a guided setup flow. We do not hard-commit to `Metadata.CustomField` until the 2GP subscriber-org spike passes.

Why: Salesforce metadata deployment is asynchronous, permission-sensitive, and packaging-sensitive. Managed package metadata operations in subscriber orgs have security and namespace implications. The install/subscriber behavior has to be proven in scratch orgs and packaging orgs, not assumed.

### Correction 5: Tailwind/Custom UI Must Still Respect Salesforce Realities

“No SLDS” is too extreme. The right principle is: use custom composition where needed, but do not fight Lightning accessibility, density, theming, or platform navigation.

Use:

- Tailwind or design-token-driven CSS as a static resource, not CDN.
- Custom form/canvas primitives where SLDS is too rigid.
- Native `lightning-*` selectively where it improves accessibility or platform behavior.
- Clear accessibility requirements: keyboard navigation, focus states, ARIA labels, screen-reader behavior.

## 4. Revised Blueprint: v4.1

### 4.1 Product Surfaces

Pulse has four user-facing surfaces:

1. Admin Studio  
   A Salesforce app/tab for admins and architects to define workflows, projections, integrations, AI tools, HITL policies, and publishing.

2. Record Stepper  
   A Lightning Record Page LWC that displays the workflow journey on the parent record: completed, current, blocked, on-hold, AI-suggested, and future steps.

3. Action Hub  
   A queue for assigned work across records and workflows. It is the heads-down operator experience.

4. Conversation Hub  
   A review surface for ingested emails, call transcripts, meetings, AI summaries, extracted facts, suggested actions, and source evidence.

### 4.2 Core Runtime Objects

Required objects:

- `Workflow_Definition__c`: published JSON definition, key, version, status, checksum.
- `Workflow_Instance__c`: active workflow on a parent record, current state, pinned definition version, context JSON.
- `Workflow_Step_Result__c`: one row per step execution, values JSON, actor, timestamps, outcome.
- `Workflow_Event__c`: append-only audit/event stream for transitions, tool calls, signals, failures.
- `Workflow_Action__c`: assigned human/AI/channel work item and HITL approval record.
- `Conversation__c`: one ingested email thread, phone call, meeting, or transcript source.
- `Conversation_Turn__c`: speaker/message-level transcript rows.
- `Conversation_Extract__c`: AI extracted facts, confidence, source turn references.
- `Integration_Connection__c`: non-secret runtime status for providers and customer setup.
- `Deployment_Request__c`: schema deployment request and status tracker.

Migration hooks:

- `External_Source__c`
- `External_Source_Id__c`
- `Migration_Batch_Id__c`

### 4.3 Core Metadata

Required CMDT:

- `Workflow_Projection__mdt`: field key to parent field mapping.
- `Workflow_Tool_Registration__mdt`: available AI tools and policy defaults.
- `AI_Provider_Registration__mdt`: provider, named credential name, priority, enabled flag.
- `Conversation_Source_Registration__mdt`: adapter class, named credential name, enabled flag.
- `Extraction_Profile__mdt`: transcript/email extraction schema.
- `Calendar_Auto_Dispatch_Rule__mdt`: Recall bot dispatch criteria.
- `Channel_Adapter_Registration__mdt`: Slack/Teams/email adapter classes.
- `Feature_Flag__mdt`: rollout controls.

Use custom objects, not CMDT, when admins need frequent runtime edits or wizard-managed mutable state.

### 4.4 Workflow JSON Contract

The contract should be versioned as `pulse.workflow.v1`.

Minimum shape:

```json
{
  "schema": "pulse.workflow.v1",
  "workflowKey": "healthcare_intake",
  "version": 1,
  "subjectKinds": ["Referral__c", "Opportunity"],
  "states": [
    {
      "key": "clinical_intake",
      "label": "Clinical Intake",
      "type": "form",
      "fields": [
        {
          "key": "referring_physician",
          "label": "Referring Physician",
          "type": "Text",
          "required": true,
          "projection": {
            "enabled": true,
            "scope": "WorkflowScoped"
          },
          "extractionHints": [
            "referring doctor",
            "clinic contact"
          ]
        }
      ],
      "transitions": [
        {
          "signal": "submit",
          "to": "benefit_verification"
        }
      ]
    }
  ]
}
```

Required contract rules:

- Never mutate a published definition in place.
- Instances pin a definition version.
- Published field keys are immutable. Rename means new label, not new key.
- Remove means mark retired, not delete.
- Type changes require a migration/conversion strategy.

### 4.5 Projection Contract

Projection is not just “show on record page.” It is a governed data-promotion decision.

Rules:

- Projection writes only happen through `ProjectionWriteService`.
- Every projection write is idempotent with a `Step_Result__c` source and field hash.
- Shared fields require explicit semantic ownership: source workflow, field meaning, write precedence.
- Workflow-scoped fields get predictable generated names but still pass collision checks.
- The admin UI must show field budget and warnings before publish.

Required projection statuses:

- `Draft`
- `Provisioning`
- `Active`
- `Failed`
- `Retired`

### 4.6 Schema Provisioning

The publish flow creates a deployment plan:

1. Validate workflow JSON.
2. Validate projection plan.
3. Validate object field budget.
4. Validate collisions.
5. Validate permission set and FLS strategy.
6. Enqueue metadata deployment.
7. Track status in `Deployment_Request__c`.
8. Publish `Pulse_Deployment_Status__e`.
9. Activate workflow only after deployment succeeds.

Phase 0 spike must prove:

- Create text/date/number/picklist fields on a subscriber object.
- Grant FLS through a packaged permission set or generated permission set.
- Add fields to a layout or document the Dynamic Forms strategy.
- Deploy from an installed managed 2GP package.
- Handle failure without leaving active broken projections.

Fallback if Apex deployment is not viable:

- External deployment service using Metadata API.
- Guided setup that generates an SFDX package/change set.
- “Projection to generic reportable fact object” for customers who reject auto-schema.

### 4.7 AI and Agentic Execution

AI must be tool-governed. Claude does not execute directly. Claude proposes tool calls; Pulse validates, executes, and audits.

Required services:

- `PulseAiProvider`: interface for Claude/OpenAI/Einstein.
- `AnthropicAdapter`: Claude Messages API adapter through Named Credential.
- `PulseAiFacade`: prompt assembly, tool list, model routing, response parsing.
- `PulseTool`: interface for executable tools.
- `PulseToolRegistry`: loads available tools and policies.
- `PulseAgentRunner`: runs AI step loop.
- `HitlService`: creates and resolves approvals.

Initial tools:

- `send_email`: Salesforce OOTB email.
- `update_record`: controlled Salesforce DML.
- `create_calendar_event`: Salesforce Event creation.
- `call_external_api`: Named Credential-backed HTTP callout.
- `summarize_conversation`: non-mutating AI summarization.
- `extract_conversation_facts`: structured extraction.

HITL policies:

- `Autonomous`
- `Approval_Required`
- `Review_After`
- `Disabled`

### 4.8 Salesforce OOTB Email

Phase 0/1 email should use Salesforce-native primitives:

- Outbound: Apex email service around `Messaging.SingleEmailMessage`.
- Inbound: Salesforce Email Service and Apex inbound handler.
- Logging: Email/Activity timeline strategy must be explicitly tested per target object.

Do not start with Gmail/Microsoft Graph unless native Salesforce email fails a customer requirement.

### 4.9 Conversation Hub

Conversation Hub is not optional if AI extraction is a core promise. Users need source evidence and correction loops.

Objects:

- `Conversation__c`
- `Conversation_Turn__c`
- `Conversation_Extract__c`
- `Conversation_Source_Link__c`

Flows:

- Inbound email creates `Conversation__c`.
- Recall transcript webhook creates `Conversation__c` and `Conversation_Turn__c`.
- Extractor creates `Conversation_Extract__c`.
- Stepper loads pending extracts and pre-fills fields with AI glow.
- Human verifies/corrects.
- Corrections are saved as audit data for prompt/evaluation improvement.

### 4.10 Recall.ai Integration

Recall should be an adapter, not hardwired into the runtime.

Required services:

- `PulseConversationAdapter`
- `RecallAdapter`
- `PulseRecallDispatcher`
- `RecallWebhookRouter`
- `ConversationIngestionService`

Admin config:

- Named Credential for Recall.
- Bot name/persona.
- Calendar auto-dispatch rules.
- Consent/retention settings.
- Transcript storage mode.

Important product rule:

- Do not auto-dispatch bots to meetings without clear customer-configured rules and consent posture.

### 4.11 Slack and Omnichannel

Slack should be added after the runtime and HITL path are stable.

Required services:

- `PulseChannelAdapter`
- `SlackChannelAdapter`
- `PulseChannelRouter` REST endpoint.
- `Pulse_UI_Payload` neutral payload.
- `Pulse_Channel_In__e` and `Pulse_Channel_Out__e`.

Security requirements:

- Verify Slack HMAC signatures.
- Validate timestamp replay window.
- Map Slack user to Salesforce user.
- Enforce workflow/action authorization before calling `WorkflowRuntime.advance`.

### 4.12 Security Model

This needs to be first-class, not an afterthought.

Required decisions:

- Projection writes should run in system mode but enforce package-defined authorization and field allowlists.
- User-visible UI must respect object/field read permissions.
- Tool execution must check policy, user approval authority, and object CRUD/FLS where appropriate.
- AI prompts must minimize PHI and support redaction policies.
- All AI/tool calls must write `Workflow_Event__c`.
- Named Credentials and External Credentials must store secrets; never CMDT/custom settings.

## 5. Phase Plan

### Phase 0A: Platform Feasibility Spikes, 2 Weeks

Goal: prove the load-bearing Salesforce assumptions.

Deliverables:

- Scratch org project scaffold.
- 2GP packaging scaffold.
- Managed-package install into test subscriber org.
- Schema auto-provisioning spike.
- Named Credential callout spike for Claude.
- Recall create-bot/webhook spike.
- Slack signed request verification spike.
- Record-page Stepper shell.

Exit criteria:

- Field creation/FLS/layout strategy is proven or replaced with fallback.
- Claude callout works via Named Credential.
- Recall bot can be scheduled and webhook can be received.
- Slack request verification works.

Kill criteria:

- Auto-schema cannot be made reliable in subscriber orgs and no acceptable fallback exists.
- AI provider credentials cannot be packaged/configured cleanly.
- The record-page runtime cannot meet acceptable UX without fighting Salesforce constraints.

### Phase 0B: Minimal Vertical Slice, 4-6 Weeks

Goal: one workflow, one object, one AI extraction, one AI action.

Build:

- `Workflow_Definition__c`
- `Workflow_Instance__c`
- `Workflow_Step_Result__c`
- `Workflow_Event__c`
- JSON parser.
- Runtime transition service.
- Projection write service.
- Admin workflow publish MVP.
- Record Stepper MVP.
- Salesforce OOTB email tool.
- Claude extraction from a pasted transcript.
- HITL approval for drafted email.

Exit criteria:

- Admin creates and publishes a workflow.
- Publish provisions or maps fields.
- End user completes a multi-field step.
- AI pre-fills fields from transcript and human verifies.
- AI drafts email and waits for approval.
- Runtime writes audit events.

### Phase 1: Admin Studio and Integrations Hub, 6-8 Weeks

Build:

- Full Admin Studio navigation.
- Workflow canvas.
- Field editor.
- Projection budget panel.
- Deployment request monitor.
- Integrations Hub.
- AI provider management.
- Recall calendar rules.
- Conversation Hub MVP.

Exit criteria:

- Admin can configure the system without Setup except Named Credential secret entry.
- Conversation Hub shows transcript, summary, facts, and source references.
- Extraction corrections round-trip to step data.

### Phase 2: Omnichannel and Queue Operations, 6-8 Weeks

Build:

- Slack outbound notifications.
- Slack inbound actions.
- Global Action Hub.
- Assignment and SLA views.
- More tool types.

Exit criteria:

- User can approve/reject from Salesforce and Slack with identical audit trail.
- Action Hub can drive daily operator work.

### Phase 3: Packaging, Compliance, and Scale, 8-12 Weeks

Build:

- 2GP package hardening.
- Install/setup wizard.
- Permission set model.
- Data retention/archive jobs.
- Performance tests.
- AI evaluation tests.
- Security review readiness.

Exit criteria:

- Package install succeeds cleanly.
- Post-install setup is deterministic.
- Bulk runtime tests pass.
- Security posture is documented.

## 6. Claude Build Orchestration

### Claude Operating Rules

Use Claude as a bounded implementer, not as the architect of the whole system.

Rules:

- One Claude chat per bounded subsystem.
- Give Claude the current blueprint excerpt, current file tree, and exact interfaces.
- Never ask for “the whole app.”
- Ask for tests with each unit.
- Require Salesforce governor-limit reasoning in every Apex prompt.
- Require package/namespace awareness.
- Paste compile errors back into the same subsystem chat.

### Chat 0: Scratch Org and Project Setup

Prompt:

```text
Act as my Salesforce DX setup assistant for Pulse Next-Gen. Generate the commands and files to initialize an SFDX project for a managed 2GP package. Include config/project-scratch-def.json for Enterprise Edition with Platform Cache and Lightning enabled. Include package directory structure for force-app/main/default. Do not generate business logic yet.
```

You run:

```bash
sf project generate -n pulse-core-next
sf org login web -d -a MyDevHub
sf org create scratch -f config/project-scratch-def.json -a PulseDev -y 30
```

### Chat 1: Data Model

Prompt:

```text
Using the Pulse v4.1 blueprint, generate Salesforce DX metadata XML for the core objects:
Workflow_Definition__c, Workflow_Instance__c, Workflow_Step_Result__c, Workflow_Event__c,
Workflow_Action__c, Conversation__c, Conversation_Turn__c, Conversation_Extract__c,
Integration_Connection__c, and Deployment_Request__c.

Include External_Source__c, External_Source_Id__c, and Migration_Batch_Id__c where useful.
Use Master-Detail only where cascade delete is truly desired. Prefer Lookup for audit/event records
that must survive operational cleanup.
Also generate permission sets for Admin and Runtime User.
```

Validation:

```bash
sf project deploy start -o PulseDev
sf org open -o PulseDev
```

### Chat 2: Custom Metadata and Config Cache

Prompt:

```text
Generate CMDT metadata for:
Workflow_Projection__mdt, Workflow_Tool_Registration__mdt,
AI_Provider_Registration__mdt, Conversation_Source_Registration__mdt,
Extraction_Profile__mdt, Calendar_Auto_Dispatch_Rule__mdt,
Channel_Adapter_Registration__mdt, and Feature_Flag__mdt.

Then write PulseConfigCache.cls. It must use static per-transaction cache first.
Use Platform Cache only behind an interface so tests do not depend on org cache availability.
Use getAll()/getInstance() where available for CMDT.
```

### Chat 3: Workflow JSON Contract

Prompt:

```text
Write WorkflowContract.cls for pulse.workflow.v1.
Include strongly typed inner classes for Workflow, State, FieldDef, Transition, Projection,
ToolConfig, ExtractionHint, and UiConfig.
Include parse(), validate(), getState(key), and getCurrentState(instance).
Do not execute workflow logic in this class.
Write tests covering valid JSON, missing state, duplicate field key, invalid transition target,
and published-version immutability rules.
```

### Chat 4: Runtime Engine

Prompt:

```text
Write WorkflowRuntime.cls and WorkflowAdvanceRequest.cls.
The bulk entry point is advance(List<WorkflowAdvanceRequest> requests).
It must:
1. Query instances and pinned definitions in bulk.
2. Parse each definition once per transaction.
3. Validate signal against current state.
4. Insert Workflow_Step_Result__c.
5. Update Workflow_Instance__c.
6. Insert Workflow_Event__c.
7. Call ProjectionWriteService with values from payloadJson.

Make it governor-limit aware for 200 records.
Do not perform callouts.
Write tests for bulk transition, invalid signal, idempotent retry, and projection dispatch.
```

### Chat 5: Projection Service

Prompt:

```text
Write ProjectionWriteService.cls.
It maps workflow field keys to parent fields using Workflow_Projection__mdt.
It must validate target object, allowed field API names, type compatibility, null handling,
and shared-field write precedence.
It must perform one bulk DML per parent object type.
It must write Workflow_Event__c entries for projection success/failure.
Include tests using Account or a test custom object.
```

### Chat 6: Schema Provisioning Spike

Prompt:

```text
Design and implement a spike for SchemaProvisioningService.
Do not assume Metadata.CustomField is available unless proven.
Create an abstraction:
SchemaDeploymentGateway with methods buildPlan(), enqueue(), getStatus().

Implement a first candidate using the Salesforce-supported Apex/Metadata deployment mechanism.
Track all requests in Deployment_Request__c and publish Pulse_Deployment_Status__e.
Include explicit comments where subscriber-org/2GP behavior must be manually verified.
```

Manual validation:

- Create field on target object.
- Grant permission.
- Confirm target user can read/write.
- Confirm projection write works after deployment.
- Confirm failure state is visible in Admin Studio.

### Chat 7: AI Provider

Prompt:

```text
Write PulseAiProvider.cls interface and AnthropicAdapter.cls.
Use Named Credentials/External Credentials. Never store API keys in CMDT.
Use the Claude Messages API with tools support.
Represent tool definitions as JSON Schema from Workflow_Tool_Registration__mdt.
Return a normalized PulseAiResponse with text, tool_use blocks, usage, provider request id, and raw JSON.
Write mock-based tests for success, API error, timeout, and malformed tool call.
```

### Chat 8: Tool Registry and Tools

Prompt:

```text
Write PulseTool interface, PulseToolRegistry, and initial tools:
PulseEmailTool, PulseRecordUpdateTool, PulseCalendarEventTool, PulseExternalApiTool.

Each tool must declare:
key, description, input schema, required permissions, default HITL policy, and execute().

PulseEmailTool must use Salesforce native email, not Gmail/Graph.
Record updates must go through an allowlist and audit event.
External API calls must use Named Credentials.
Write unit tests for HITL required vs autonomous execution.
```

### Chat 9: Agent Runner and HITL

Prompt:

```text
Write PulseAgentRunner.cls and HitlService.cls.
Given a Workflow_Instance__c and current state, the runner gathers context,
loads tools, calls PulseAiProvider, validates tool calls, and either:
1. executes autonomous tools,
2. creates Workflow_Action__c approval records for Approval_Required,
3. records failures in Workflow_Event__c.

Tool execution success must send a workflow signal back into WorkflowRuntime.
Write tests for autonomous email blocked by policy, approval creation, approval execution,
and AI malformed output.
```

### Chat 10: Conversation Ingestion

Prompt:

```text
Write ConversationIngestionService.cls.
It accepts normalized inputs for email, meeting transcript, and phone call.
It creates Conversation__c and Conversation_Turn__c rows.
It links the conversation to a parent record and optional workflow instance.
It enqueues extraction using Queueable Apex.
Write tests for email ingestion, transcript ingestion, duplicate external source id,
and source linkage.
```

### Chat 11: Extraction

Prompt:

```text
Write PulseConversationExtractor.cls.
It loads Extraction_Profile__mdt, calls PulseAiProvider with a JSON-schema extraction prompt,
stores Conversation_Extract__c with Facts_JSON__c, Confidence_JSON__c, and source turn references.
Do not write projected Salesforce fields directly. The Stepper/Human verification flow must approve values first.
Write mock tests for extracted facts, missing required facts, and correction persistence.
```

### Chat 12: Recall Adapter

Prompt:

```text
Write PulseConversationAdapter interface and RecallAdapter.cls.
RecallAdapter must:
1. Create/schedule a bot for a meeting URL.
2. Handle webhook payloads.
3. Normalize transcript data into ConversationIngestionService input.
Use Named Credentials.
Also write PulseRecallDispatcher Queueable and Event trigger handler that evaluates
Calendar_Auto_Dispatch_Rule__mdt before scheduling a bot.
Write tests with HTTP callout mocks and no real Recall calls.
```

### Chat 13: Slack Adapter

Prompt:

```text
Write PulseChannelAdapter interface, PulseUiPayload classes, SlackChannelAdapter,
and PulseChannelRouter REST endpoint.
The router must verify Slack signatures using timestamp + raw body + signing secret.
It must reject replayed timestamps and unauthorized users.
Slack button clicks must map to WorkflowRuntime.advance().
Write tests for valid signature, invalid signature, replay timestamp, and workflow approval click.
```

### Chat 14: Admin Studio Shell

Prompt:

```text
Write LWC admin shell pulseAdminStudio with navigation for:
Workflows, Integrations, Conversations, Deployments, Feature Flags.
Use standard HTML/CSS with a local static-resource design system.
Do not use CDN Tailwind.
Generate Apex controller methods needed for initial shell data.
```

### Chat 15: Workflow Builder

Prompt:

```text
Write pulseWorkflowCanvas LWC.
It edits a workflow JSON draft in browser state.
Include:
step list, field editor, transitions editor, projection toggle, field budget panel,
JSON validation panel, and publish button.
Publish creates Deployment_Request__c and calls SchemaProvisioningService.
Listen to Pulse_Deployment_Status__e via lightning-emp-api.
```

### Chat 16: Integrations Hub

Prompt:

```text
Write pulseIntegrationsHub LWC and PulseIntegrationsHubCtrl.cls.
Show:
1. Salesforce native email status and inbound email address instructions.
2. AI provider registrations and Named Credential setup status.
3. Recall connection status and calendar auto-dispatch rules.
4. Slack channel adapter setup status.
Do not display secrets.
Include empty/error/loading states.
```

### Chat 17: Record Stepper

Prompt:

```text
Write pulseWorkflowInstanceViewer LWC and PulseInstanceViewerCtrl.cls.
It targets lightning__RecordPage and receives recordId.
It must load active workflow instances for the parent record.
Render a vertical stepper:
completed steps, current form, blocked/on-hold steps, future path, and AI/HITL states.
It must pre-fill fields from pending Conversation_Extract__c values with an AI-glow style
and require human verification before calling WorkflowRuntime.advance().
```

### Chat 18: Conversation Hub

Prompt:

```text
Write pulseConversationHub composed of pulseConversationInbox and pulseConversationViewer.
Inbox shows Conversation__c records with medium, participants, summary, linked parent, status.
Viewer shows transcript turns, AI summary, extracted facts, confidence/source evidence,
and suggested workflow actions with Accept/Dismiss.
Accepting extracted facts should create a verified payload for the Stepper, not directly update parent fields.
```

### Chat 19: Action Hub

Prompt:

```text
Write pulseActionHub LWC and PulseActionHubCtrl.cls.
Show assigned Workflow_Action__c records grouped by due date, SLA risk, workflow, and parent.
Support approve/reject HITL actions and opening parent records.
All actions must call server-side services, not client-side DML.
```

### Chat 20: Packaging and Test Hardening

Prompt:

```text
Review the Pulse codebase for 2GP managed package readiness.
Check namespace issues, global/public visibility, permission sets, Named Credential packaging,
custom metadata subscriber editability, test isolation, callout mocks, platform cache fallback,
and Metadata API deployment test limitations.
Produce a punch list and patches.
```

## 7. First 10 Concrete Build Tasks

1. Initialize SFDX project and scratch org.
2. Create 2GP package scaffold.
3. Build core objects and permission sets.
4. Build CMDT and config cache.
5. Build workflow JSON parser with tests.
6. Build bulk runtime engine with tests.
7. Build projection write service with tests.
8. Run schema provisioning spike.
9. Build Claude Named Credential callout spike.
10. Build record Stepper shell.

Do not build Slack, Recall, or full Admin Studio until tasks 1-8 are proven.

## 8. Sources Checked

- Salesforce Named Credentials and External Credentials: https://developer.salesforce.com/docs/platform/named-credentials/guide/get-started.html
- Salesforce Named Credential packaging guidance: https://developer.salesforce.com/docs/platform/named-credentials/guide/nc-package-credentials.html
- Salesforce Apex Metadata API security and subscriber-org behavior: https://developer.salesforce.com/blogs/engineering/2017/06/apex-metadata-api-security
- Salesforce Metadata API deployment behavior: https://developer.salesforce.com/blogs/2025/09/take-a-deep-dive-into-metadata-api-deployments
- Salesforce LWC `lightning-emp-api`/Streaming API reference: https://developer.salesforce.com/docs/component-library/bundle/lightning%3AempApi/documentation
- Anthropic Messages API and tool use: https://docs.anthropic.com/en/docs/agents-and-tools/tool-use/overview
- Slack request signature verification: https://api.slack.com/docs/verifying-requests-from-slack
- Recall.ai bot and calendar integration docs: https://docs.recall.ai/docs/bot-overview and https://www.recall.ai/product/calendar-integration-api
