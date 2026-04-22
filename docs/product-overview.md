# Pulse Core Next — How It Works

A practical narrative for anyone who just installed the package and wants to understand what the pieces do and how they fit together.

## The product in one sentence

Pulse Core Next is a Salesforce-native workflow engine where **admins author workflows as JSON contracts**, **the platform auto-provisions the parent-object fields those workflows need**, **end users advance workflows from the record page**, **AI agents propose tool calls with human-in-the-loop approval**, and **conversations (emails, calls, meetings) get distilled into structured facts that reviewers can promote into the parent record**.

## The five surfaces

| Surface | Who uses it | Where it lives |
|---|---|---|
| **Admin Studio** | Workflow authors, Pulse administrators | Lightning app / tab — SPA |
| **Record Stepper** | End users (reps, case workers, recruiters) | Lightning record page — LWC on any SObject |
| **Action Hub** | Approvers | Lightning record page or Admin Studio tab |
| **Conversation Hub** | Reviewers (ops / triage) | Record page or app-page |
| **SLA Heatmap** | Managers / RevOps | Admin Studio tab |

## The authoring-to-runtime loop

### 1. Author defines the workflow

In the Admin Studio → Workflow Builder, the admin drags states ("Intake", "Qualification", "Tour Scheduled", "Application Received"…), defines transitions between them ("submit" → "Qualification"), and adds fields per state ("applicant_name", "credit_score", "lease_term_months").

For each field, the admin flips a single checkbox:

> ☑ Show on record page & include in reports

- **Checked** → the field's latest value will be projected onto the parent SObject. It becomes a real custom field on e.g. Opportunity, visible on record pages, queryable from reports, editable with standard Salesforce permissions.
- **Unchecked** → the field lives only in the `Workflow_Step_Result__c` history log. It's still queryable, still auditable, but doesn't bloat the parent object's schema.

This is the "one checkbox" principle from v4.1 §3. Admins don't need to know the words "projection" or "step result" — the checkbox does the right thing.

### 2. Publish triggers schema auto-provisioning

When the admin clicks Publish, Pulse:

1. **Validates the JSON contract** via `WorkflowContract.parse()` + `validate()` — catches malformed definitions (missing state keys, unknown transition targets, etc.) before any schema touches the org.
2. **Inserts a `Deployment_Request__c`** record to audit the publish.
3. **Calls `ToolingApiDeploymentGateway.enqueue()`** which uses the Salesforce Tooling API via a Named Credential pointed back at the same org (`callout:Pulse_Self_Org_Tooling`) to `POST /services/data/v62.0/tooling/sobjects/CustomField` — one request per new field.
4. **Updates the `Deployment_Request__c`** with success/partial/failure status.
5. **Publishes a `Pulse_Deployment_Status__e`** platform event so any monitoring surface can react in real time.

The `MetadataApiDeploymentGateway` is _not_ used — we learned empirically that `Metadata.CustomField` isn't exposed in the Apex `Metadata` namespace in managed-package subscriber orgs. The Tooling API path is the load-bearing one.

### 3. End user advances the workflow

A record page for the parent SObject (say an Opportunity with an active leasing workflow) embeds `pulseRecordStepper`. On load:

1. LWC calls `PulseRuntimeController.getInstanceForRecord(recordId)` which finds the active `Workflow_Instance__c` where `Subject_Record_Id__c = recordId`, loads its pinned contract, and returns:
   - `currentStateKey` + label
   - `availableSignals` (transitions valid from the current state)
   - `history` (completed `Workflow_Step_Result__c` rows)
   - `pendingActionCount` (`Workflow_Action__c` rows still awaiting HITL resolution)
2. User sees the current state + branded action buttons for each available signal.
3. User clicks a signal → optional payload textarea in a modal → submit → LWC calls `PulseRuntimeController.advanceInstance(instanceId, signal, payloadJson, idempotencyKey)`.
4. `WorkflowRuntime.advance()` bulk-processes the request: validates the signal against the pinned contract, inserts the `Workflow_Step_Result__c`, inserts a `Workflow_Event__c` audit row, updates the instance's `Current_State__c`, and fires all registered `TransitionHook`s.
5. The LWC wire refreshes; UI shows the new state immediately.

### 4. AI agent proposes tool calls

When a workflow state has AI-driven behavior (e.g., "draft the lease terms based on intake data"), the `PulseAgentRunner` invokes the configured AI provider (e.g., Claude via `AnthropicAdapter`) with tool definitions gathered from `PulseToolRegistry`.

Each tool (`PulseEmailTool`, `PulseRecordUpdateTool`, `PulseExternalApiTool`, or custom extension tools) has a **default HITL policy** in `Workflow_Tool_Registration__mdt`:

- `Autonomous` — execute immediately.
- `Approval_Required` — create a `Workflow_Action__c` in Pending status; wait for a human.
- `Review_After` — execute immediately but log for post-hoc review.
- `Disabled` — refuse to run.

When the AI proposes a tool call with `Approval_Required`:

1. `HitlService.request()` creates a `Workflow_Action__c` with the full tool input JSON.
2. Approver sees it in `pulseActionHub` (either on the record page or the Admin Studio Action Hub panel).
3. Approver clicks **Approve** or **Reject** → `PulseRuntimeController.resolveAction()` → `HitlService.approve()` executes the tool immediately or `HitlService.reject()` records the rejection + audit event.
4. Agent loop continues with the resolved state.

### 5. Conversations → structured facts

Separately from the workflow-driven AI, Pulse ingests conversations from multiple channels:

- **Email** (send-to-address routed via Email-to-Apex)
- **Call transcripts** (uploaded manually or via a telephony integration)
- **Meeting recordings** (Recall.ai — invited bot captures transcript)
- **Chat** (Slack / Teams)

Each channel has a `PulseConversationAdapter` implementation that normalizes the raw payload into `Conversation__c` + `Conversation_Turn__c` rows.

Once the conversation is stored, `PulseConversationExtractor` runs as a Queueable:

1. Loads the conversation's turns into a single transcript.
2. Invokes an `ExtractionCallable` provider (Anthropic, OpenAI, or Einstein) with the prompt defined in `Extraction_Profile__mdt.Schema_JSON__c`.
3. Parses the LLM response into a `Conversation_Extract__c` with:
   - `Facts_JSON__c` — the proposed field-key → value map
   - `Confidence_JSON__c` — per-field confidence score 0..1
   - `Source_Turn_References__c` — which turns backed each fact
   - `Status__c = 'Pending'`

Reviewers open `pulseConversationHub` (on the record page or the Admin Studio Conversations panel):

- See each conversation with its turns + one or more pending extracts.
- Each fact renders with a confidence bar (green ≥0.8, amber ≥0.5, red below).
- Checkbox per fact — reviewer picks which to accept.
- Click **Accept selected** → `PulseConversationHubController.acceptExtract()` → `ProjectionWriteService.project()` promotes the accepted facts onto the parent SObject exactly the same way the workflow runtime does. Extract marked `Accepted` (or `Partial` if some facts failed).
- Click **Reject** → marks the extract `Rejected`.
- Click **Request re-extraction** → re-enqueues the extractor (e.g., after the profile or model changes).

### 6. SLA tracking accrues automatically

`StageDwellHook` is auto-registered in `WorkflowRuntime.advance()`. Every transition:

- Closes the prior state's `Stage_Dwell__c` row (sets `Exited_At__c`, computes `Duration_Seconds__c`, records which signal exited and who the actor was).
- Opens a new `Stage_Dwell__c` row for the entering state.

Managers open the Admin Studio SLA panel to see the heatmap:

- Rows = states
- Columns = median dwell time, p90 dwell time, sample count
- Color bucket per state based on relative p90 (quartile across all states in scope)
- `StageDwellPredictor.predictExitFor(instanceId)` can project when a mid-flight instance is likely to exit its current state based on historical medians, flagged `isOverdue` when the current instance has already passed the p90.

No manual logging. The SLA signal is a byproduct of the runtime doing its normal job.

## Why the managed-package layout matters

Six 2GP managed packages, all in the `plse` namespace:

| Package | Role |
|---|---|
| **Pulse Core** | Runtime, contracts, schema provisioning, AI facade + HITL, projection, SLA, Admin Studio shell, Pulse primitives (LWC library). |
| **Pulse AI – Anthropic** | Anthropic provider for `PulseAiProvider`. Swap for OpenAI or Einstein by installing a different provider package. |
| **Pulse Tools – Core** | Built-in tools (send_email, update_record, external HTTP). Third parties can ship more tools without touching Core. |
| **Pulse Conversations – Core** | Conversation ingestion + extractor. |
| **Pulse Conversations – Recall** | Recall.ai channel adapter. |
| **Pulse Channels – Slack** | (reserved — populated in a later wave) |

Because they're all managed, subscribers can't read or modify the Apex source. Because they share one namespace, cross-package Apex references don't need `plse.` prefixing internally. Because they're separately installable, customers who don't need Recall don't install Pulse Conversations – Recall.

## Where to look for specific concepts

| Concept | Key classes / objects |
|---|---|
| Contract schema | `WorkflowContract.cls`, sample JSON in `docs/demo-real-estate-leasing.md` |
| Authoring state management | `pulseStore.js`, `pulseWorkflowBuilder` LWC |
| Schema provisioning | `SchemaProvisioningService.cls` + `ToolingApiDeploymentGateway.cls` |
| Named Credential setup | `docs/schema-provisioning-setup.md` |
| Runtime bulk transition | `WorkflowRuntime.advance()` |
| HITL policy resolution | `PulseToolRegistry.getEffectiveHitlPolicy()`, `HitlService.cls` |
| Projection semantics | `ProjectionWriteService.cls`, `Workflow_Projection__mdt` |
| Conversation ingestion | `ConversationIngestionService.cls`, `PulseConversationAdapter` interface |
| Extraction | `PulseConversationExtractor.cls` (Queueable) |
| SLA | `StageDwellHook.cls`, `StageDwellPredictor.cls` |
| Brand tokens | `force-app/…/staticresources/pulse_brand_tokens.css` (after Wave 2b split: `packages/pulse-core/…`) + `docs/brand-kit/README.md` |

## What's not in the product yet (at the time of writing)

- **Slack/Teams channel adapters** — objects and interfaces exist; the concrete Slack adapter is reserved for a future wave.
- **Pulse Library distribution** — signed bundle format for sharing workflows across orgs (Wave 7).
- **Real managed-beta package versions** — the `sf package create` one-time setup hasn't been run yet; placeholder `0Ho…` aliases live in `sfdx-project.json` until then. See `docs/packaging-notes.md`.

The rest works today.
