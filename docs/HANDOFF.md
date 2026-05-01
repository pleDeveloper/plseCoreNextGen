# Pulse Core Next — Handoff for Demo Agent

> Self-contained briefing for an AI agent or human engineer continuing the work in a separate session, typically to build a client demo on top of this codebase.

---

## 1. The product in one paragraph

**Pulse Core Next** is a Salesforce-native workflow platform where the workflow definition lives as JSON (a "contract"), runtime state lives in reportable Salesforce objects, and an AI agent (Anthropic Claude) is the orchestrator. The agent reads the conversation history attached to a record (e.g., inbound email threads), decides what to do next, drafts emails or record updates, and asks for human approval where required. The end-user surface is a record page LWC ("journey card" + decision queue + agent status rail). Admins configure workflows in a separate Admin Studio.

**Mental model:** Workflow has phases → each phase has required info (fields) and required actions (tool calls). The AI gets info from the *client* (by drafting emails to them), not from the admin. Admin only approves drafts. When phase requirements are met, the AI proposes `advance_phase`.

---

## 2. Repo layout

```
pulse-nextgen/
├── packages/
│   ├── pulse-core/                  ← main package — 90 classes, 32 LWCs, 25+ SObjects
│   ├── pulse-ai-anthropic/          ← Anthropic adapter (PulseAiProvider impl)
│   ├── pulse-tools-core/            ← tool implementations (PulseEmailTool, PulseRecordUpdateTool, PulseExternalApiTool)
│   ├── pulse-conversations-core/    ← Conversation__c, Conversation_Turn__c, ingestion service
│   ├── pulse-conversations-recall/  ← (extension, not used in demo)
│   └── pulse-channels-slack/        ← (extension, not used in demo)
├── scripts/
│   ├── seed-leasing-e2e-demo.apex   ← end-to-end Real Estate Leasing demo (works on namespaced scratch)
│   ├── seed-tool-registry.apex      ← uses `plse.` prefix — namespaced-only
│   └── seed-action-status-templates.apex
├── docs/                             ← reference docs incl. this file
└── sfdx-project.json                 ← `namespace: "plse"` (managed 2GP packaging)
```

**Namespace:** the package is registered as `plse` on `PulseDevHub`. Source code uses **bare names** everywhere (e.g., `Workflow_Instance__c`, not `plse__Workflow_Instance__c`). The `plse__` prefix only appears in:
- Anonymous Apex scripts (because they run outside the package's namespace context)
- CMDT XML records that reference fields by full API name

When deploying to an **unnamespaced** dev org for unmanaged use, set `"namespace": ""` in `sfdx-project.json` and the bare names land as-is. Restore `"namespace": "plse"` before any deploy back to a namespaced org.

---

## 3. Architecture non-negotiables (from CLAUDE.md)

1. **JSON definition + native runtime state split** — workflow contract is JSON (`pulse.workflow.v1`); runtime state lives in `Workflow_Instance__c`, `Workflow_Action__c`, `Workflow_Step_Result__c`, etc., so it's queryable and reportable.
2. **Strict surface boundary** — admin configuration UI (`pulseAdminStudio`, `pulseWorkflowBuilder`) is separate from end-user runtime UI (`pulseRecordStepper`, `pulseAgentDecisionQueue`).
3. **AI execution model** — AI proposes tool calls → platform validates HITL policy → executes (or queues for human approval). All approvals audited.
4. **Security** — Named Credentials for external calls (no secrets in code/CMDT). External Credentials must be set up manually in each org (they can't be source-deployed cleanly).
5. **Extraction safety** — conversation extraction = suggestions; never directly commit to parent fields without verification.

---

## 4. The agent model — read this carefully

The agent (`PulseAgentOrchestrator`) is a **per-instance loop** with these top-level decision types:

| Decision type | When to use | Side effect |
|---|---|---|
| `propose_action` | The agent wants the platform to call a registered tool (`send_email`, `update_record`, `external_api`) | Creates / fills a `Workflow_Action__c` row that goes to the approval queue |
| `ask_user` | A fact only the **internal team** knows (tour host assignment, internal credit policy) | Renders as a field-question pill on the form |
| `advance_phase` | All required info captured + actions complete; ready to move to next phase | Fires the workflow transition |
| `observe` | Genuinely nothing to do (waiting on external callback / client reply) | No-op, logged for audit |

### Autonomy levels (`Agent_Thread__c.Autonomy_Level__c`)

- `Propose_Only` — every decision becomes Pending_User
- `Act_With_Approval` (default) — `Ask_User` and `Propose_Action` go pending; `Advance_Phase` fires immediately
- `Autonomous_Safe` — auto-executes tools listed in `PulseAgentOrchestrator.AUTONOMOUS_SAFE_TOOLS` (currently empty by default; opt-in)

### Critical grounding rules baked into the system prompt

1. **Read conversations FIRST.** `context.conversations[*].turns[*].content` is included in the prompt — the agent must scan this for facts before concluding info is missing.
2. **If info is in context (already captured), call `propose_action(update_record)` — do NOT re-ask.**
3. **If info is missing and the client would know it** (move-in date, sqft, headcount, budget) → draft a `send_email` to the client. NOT `ask_user`.
4. **If a phase has a pending ai_tool placeholder action with no `Request_JSON__c`** → the agent FILLS that placeholder via `propose_action`. The orchestrator's `reusePlaceholderOrCreate` helper writes the agent's draft into the existing row instead of creating a parallel action.
5. **Tool argument keys are exact:** `send_email` requires `toAddress` (NOT `to`), `subject`, `body`. `update_record` requires `recordId`, `objectType`, `fields`. The prompt spells these out.
6. **After a `send_email` action_key has Executed, do NOT re-draft for the same action_key.** Propose `advance_phase` or `observe` instead. `context.recentlyResolvedActions[]` shows the agent what's been done.

These rules are enforced in `PulseAgentOrchestrator.buildSystemPrompt` ([packages/pulse-core/.../PulseAgentOrchestrator.cls](packages/pulse-core/force-app/main/default/classes/PulseAgentOrchestrator.cls)). If the agent misbehaves, that method is where to tune.

---

## 5. Workflow contract schema (`pulse.workflow.v1`)

Top-level shape:

```json
{
  "schema": "pulse.workflow.v1",
  "workflowKey": "real_estate_leasing_v1",
  "version": 1,                                  ← REQUIRED, positive integer
  "name": "Commercial Lease Application",
  "subjectKinds": ["Opportunity"],
  "agent": {
    "enabled": true,
    "persona": "Harper",
    "autonomy": "Act_With_Approval",
    "systemPrompt": "..."
  },
  "states": [ ... 8 phases ... ]
}
```

Each `state` (phase):

```json
{
  "key": "qualification",
  "label": "Qualification",
  "type": "form" | "ai_driven" | "approval" | "terminal",
  "advancement": "auto" | "manual_decision",
  "agent": { ... per-phase override of contract-level agent ... },
  "fields": [
    {
      "key": "applicant_name",
      "label": "Primary Contact",
      "type": "Text" | "Number" | "Date" | "DateTime" | "Currency" | "Checkbox" | "LongTextArea",
      "required": true,
      "projection": { "enabled": true, "scope": "WorkflowScoped" }
    }
  ],
  "actions": [
    {
      "key": "send_tour_invite_email",
      "label": "Send tour invitation email",
      "type": "ai_tool" | "manual",
      "required": true,
      "sequence": 0,
      "dependsOn": [],                           ← other action keys this waits on
      "statuses": [ ... StatusDef[] ... ],       ← optional per-action status machine
      "initialStatusKey": "Drafting",
      "config": {
        "toolKey": "send_email",
        "hitlPolicy": "Approval_Required" | "Autonomous" | "Review_After",
        "parameters": { "systemPrompt": "..." }  ← tool-specific guidance
      }
    }
  ],
  "transitions": [
    { "signal": "schedule_tour", "to": "tour_scheduled" }
  ]
}
```

**Validation** lives in `WorkflowContract.validate(Workflow wf)`. The most common failure to watch for: missing `version` field (silent failure → instance can't advance — ate hours of debug time during the build).

---

## 6. Status machines (the "all in" feature)

Every action can have its own status machine. Four canonical templates ship as `Action_Status_Template__mdt`:

| Template | Statuses | Use for |
|---|---|---|
| `Basic_Approval` | Pending → Approved \| Rejected | manual approval steps |
| `Email_Send` | Drafting → Pending_Approval → Sent → Complete \| Bounced | every send_email action |
| `Task` | Not_Started → In_Progress → On_Hold \| Complete | long-running work |
| `Field_Capture` | Empty → Partial → Complete | form-fill phases |

Status categories: `open`, `blocked`, `terminal_success`, `terminal_failure`. The record-page badge ([pulseBadge](packages/pulse-core/force-app/main/default/lwc/pulseBadge/)) renders status-aware colors via `Stage_Status__c` derived by `StageProgressionService`.

Admin Studio editor: `pulseActionStatusEditor` LWC — pick a template, customize, attach to action.

Status engine: `PulseActionStatusEngine.cls` reevaluates on every action lifecycle event. Cross-action dependencies via `entryConditions` rules referencing sibling action keys (`type: action_status`).

---

## 7. Key SObjects (cheat sheet)

| Object | Purpose | Key fields |
|---|---|---|
| `Workflow_Definition__c` | The published contract | `Workflow_Key__c`, `Version__c`, `Definition_JSON__c`, `Status__c` (Draft/Published) |
| `Workflow_Instance__c` | One running instance bound to a parent record | `Workflow_Definition__c`, `Parent_Record_Id__c` (Text(18)), `Parent_Object_Type__c`, `Current_State__c`, `Status__c` (Active/Completed), `Context_JSON__c`, `Stage_Status__c` |
| `Workflow_Action__c` | Tool-call rows (pending approvals, executed, refined drafts) | `Tool_Key__c`, `Action_Key__c`, `Phase_Key__c`, `Status__c` (Pending/Executed/Failed/Rejected/Cancelled), `Request_JSON__c`, `Response_JSON__c`, `HITL_Policy__c`, `Status_Key__c` (status machine), `Status_Category__c` |
| `Workflow_Event__c` | Audit log | `Event_Type__c` (Text — TOOL_EXECUTED, TOOL_REFINED, TOOL_REJECTED, AI_CALL, Transition, etc.), `Detail_JSON__c` |
| `Workflow_Step_Result__c` | History of completed phase transitions | timing data for the SLA heatmap |
| `Workflow_Trigger__c` | Auto-start rules (record-triggered workflow start) | `Condition_JSON__c` evaluated by `PulseWorkflowTriggerEvaluator` |
| `Agent_Thread__c` | One per workflow instance with agent enabled | `Persona_Name__c`, `Autonomy_Level__c`, `System_Prompt__c`, `Rolling_Summary__c`, `Status__c`, `Last_Error__c` |
| `Agent_Decision__c` | Each AI turn produces one | `Decision_Type__c` (Propose_Action/Ask_User/Advance_Phase/Observe/Error), `Status__c` (Pending_User/Approved/Rejected/Auto_Executed/Skipped/Answered), `Proposal_JSON__c`, `Question_JSON__c`, `Related_Action__c` |
| `Conversation__c` | Thread bound to a parent record | `Subject__c`, `Participants__c` (Text), `Source_Adapter__c`, `Workflow_Instance__c`, `Parent_Record_Id__c` |
| `Conversation_Turn__c` | Single message in a conversation | `Role__c`, `Speaker__c`, `Content__c` (LongTextArea), `Timestamp__c`, `Turn_Index__c` |
| `Conversation_Routing_Rule__mdt` | CMDT — declarative inbound-email → record routing | `Rule_Key__c`, `Match_Strategy__c`, `Target_Object__c`, `Create_Defaults_JSON__c`, `Trigger_Workflow_Key__c` |

---

## 8. The Real Estate Leasing demo

Live in `scripts/seed-leasing-e2e-demo.apex`. Flow:

1. Tear down prior demo data (idempotent).
2. Publish the contract under `Workflow_Key__c = real_estate_leasing_v1` (8 phases: inquiry → qualification → tour_scheduled → application_submitted → credit_review → lease_drafted → signed/declined).
3. Create demo Account `Hawthorne & Sterling LLP` and Contact `Marcus Chen <marcus.chen@hawthorne-sterling-demo.example>`.
4. Simulate inbound email via `new PulseInboundEmailHandler().handleInboundEmail(email, env)` — `InboundRecordRouter` matches the contact, creates a fresh Opportunity, starts the workflow instance.
5. Auto-advance from `inquiry` → `qualification` (the agent-enabled phase) so admin can immediately see Harper at work.
6. Create the `Agent_Thread__c` record so the rail renders.

**Agent kick is intentionally NOT in the seed script** — anonymous-Apex DML blocks the Anthropic callout in the same transaction (the "callout after uncommitted DML" platform rule). Admin clicks **Kick agent** in the UI to trigger the first turn.

---

## 9. Where things are deployed

### Namespaced scratch (`pulse-core-next-dev`)
- Org ID: `00DE200000RDF9mMAH`
- User: `test-reo4idr9fhai@example.com`
- Has `plse` namespace
- Used for development against the "real" managed-package shape
- Demo seed lives here

### Unnamespaced dev org (`pulse-clientdemo`) — **THIS IS WHERE THE DEMO AGENT WORKS**
- Org ID: `00DgL00000QL8YHUA1`
- User: `pulse+gg.18d385109fb7@agentforce.com`
- URL: `https://orgfarm-591eb7125f-dev-ed.develop.lightning.force.com`
- All source deployed (objects, classes, LWCs, triggers, tabs, app, permsets, static resources)
- All 11 CMDT records seeded via `Metadata.Operations.enqueueDeployment` (3 tools, 4 status templates, AI provider registration, routing rule, 2 column configs)
- **NOT YET DONE on this org** (manual setup steps, see Section 10):
  - External Credential `Pulse_Anthropic` + Named Credential of same name + API key
  - `Pulse_Core_Admin` permset assignment
  - Anthropic principal access grant via `SetupEntityAccess`

---

## 10. Setup procedure for a fresh org (manual steps)

After source deploy + CMDT bootstrap, every org needs:

### A. External Credential + Named Credential (UI, 5 min)

Setup → Named Credentials → External Credentials → New:
- Label: `Pulse Anthropic` | Name: **`Pulse_Anthropic`** | Auth Protocol: `Custom`

On detail page:
- **Custom Headers** → `x-api-key` = `{!$Credential.Pulse_Anthropic.ApiKey}`, sequence 1
- **Principals** → New: Parameter Name **`PulseAnthropicPrincipal`**, Identity Type `Named Principal`, Auth Protocol `Custom`. Authentication Parameter: Name `ApiKey`, Value `<real Anthropic API key>`

Setup → Named Credentials → Named Credentials → New:
- Label/Name: `Pulse Anthropic` / `Pulse_Anthropic`
- URL: `https://api.anthropic.com`
- External Credential: select the one above
- **Allow Formulas in HTTP Header: ✓ ← REQUIRED, easy to miss.** Without this, the External Credential's `x-api-key: {!$Credential.Pulse_Anthropic.ApiKey}` header is sent as the LITERAL string instead of the resolved API key, and Anthropic returns `401 invalid x-api-key`. Toggle is in the Callout Options section of the Named Credential edit page.
- Allow Formulas in HTTP Body: ✓ | Generate Authorization Header: ✗
- Custom Header on the Named Credential: `anthropic-version` = `2023-06-01`

### B. Permset + principal access (Apex)

```apex
// Assign Pulse_Core_Admin to current user
Id permSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Pulse_Core_Admin' LIMIT 1].Id;
insert new PermissionSetAssignment(
    PermissionSetId = permSetId,
    AssigneeId = UserInfo.getUserId()
);

// Grant External Credential Principal access (Pulse_Anthropic-PulseAnthropicPrincipal)
// The principal name format `Pulse_Anthropic-PulseAnthropicPrincipal` does NOT
// resolve in declarative permset XML — must be granted via SetupEntityAccess.
Id principalId = [
    SELECT Id FROM ExternalCredentialParameter
    WHERE ParameterName = 'PulseAnthropicPrincipal'
      AND ExternalCredential.DeveloperName = 'Pulse_Anthropic'
    LIMIT 1
].Id;
insert new SetupEntityAccess(
    SetupEntityId = principalId,
    ParentId = permSetId
);
```

### C. Smoke test the AI callout

```apex
PulseAiModels.Request req = new PulseAiModels.Request();
req.messages.add(new PulseAiModels.Message('user', 'Say hello in 5 words.'));
PulseAiModels.Response resp = PulseAiFacade.invoke(req);
System.debug(resp.text);
```

If this throws "callout failed: We couldn't access the credential" → step B's principal grant didn't land.

---

## 11. Critical platform constraints (gotchas the build hit)

These are not bugs — they're Salesforce platform rules that bit us during the build. **Read these before changing the agent code.**

### Callout-after-DML
You **cannot** make an HTTP callout (Anthropic) after any uncommitted DML in the same transaction. This bit us 4 times:
- `kickAgent` did `update thread` then `PulseAiFacade.invoke(req)` → fixed by deferring all thread DML to AFTER the callout.
- `approveDecision` / `rejectDecision` / `answerQuestion` did DML and then re-kicked the agent loop → fixed by **`PulseAgentAdvanceQueueable`** (a `Queueable` that runs in a fresh transaction). When you write code that re-kicks the agent after DML, use that pattern.
- Anonymous Apex seed scripts that set up data and then call `PulseAgentOrchestrator.advance(instanceId)` → still fail. The seed leaves agent kicking to the UI button.

### CMDT source deploy fails with UNKNOWN_EXCEPTION
On both the namespaced scratch and the unnamespaced dev org, `sf project deploy start` of NEW Custom Metadata records hits a generic UNKNOWN_EXCEPTION. The proven workaround is `Metadata.Operations.enqueueDeployment(container, null)` from anonymous Apex (see `/tmp/bootstrap-unmanaged.apex` or `scripts/seed-tool-registry.apex`).

### Aura DTO deserialization bug
Aura cannot deserialize typed inner-class DTO inputs to `@AuraEnabled` methods — fields drop silently. **Always accept `Map<String, Object>` payloads and coerce internally.** This is a project-wide convention enforced in `PulseAgentController.approveDecision`, `PulseEmailRouterController.upsertRoutingRule`, `PulseWorkflowTriggerController.upsertTrigger`, `PulseActionStatusTemplateController.upsertTemplate`. **Do not regress this.**

### Phase-initial action placeholders
When a phase entered, `PulseActionInstantiationService` creates `Workflow_Action__c` rows for each declared action. For `ai_tool` actions, these have `Status__c = Pending` but `Request_JSON__c = null` — they're placeholders waiting for the agent to fill them. Two important downstream rules:
- `PulseRuntimeController.getPendingActions` filters out blank-`Request_JSON__c` rows (in-memory because the field is LongTextArea and not SOQL-filterable). Without this, the approval queue shows empty cards.
- `PulseAgentOrchestrator.reusePlaceholderOrCreate` writes the agent's draft INTO the existing placeholder when toolKey matches. Without this, the agent stacks parallel actions and loops.

### Hard-delete is not supported for Custom Metadata
`Metadata.Operations.enqueueDeployment` cannot delete CMDT records. The routing-rule editor (`pulseEmailRouter`) implements **soft delete** by setting `Active__c = false` — the confirm modal explicitly tells admins this.

### Outbound email on scratch / fresh dev orgs
Email deliverability isn't enabled on most scratch orgs. `PulseEmailTool` has a Task fallback — when `Messaging.SingleEmailMessage` throws `INSUFFICIENT_ACCESS_OR_READONLY`, it logs the email as a Task activity on the parent record and returns `status=deferred`. Demo viewers should look at the Activity timeline if they expect an email.

### `Status__c` is a restricted picklist
`Workflow_Action__c.Status__c` values are restricted: `Pending | Approved | Rejected | Executed | Failed | Cancelled`. You cannot add a custom "Draft" or "Awaiting_Agent" — that's why placeholder filtering uses Request_JSON__c blank, not a status flag.

### `Pulse_Core_Admin` permset cannot reference External Credential Principal in XML
The declarative `<externalCredentialPrincipalAccesses>` block fails with "invalid cross reference id" when the External Credential is org-created (not in source). Grant programmatically via `SetupEntityAccess` (see Section 10B).

---

## 12. Recent significant commits

```
7bb1d8d  fix(agent): reuse placeholder instead of stacking parallel actions; use toAddress
3549331  fix(agent+demo): empty approval cards, junk ask_user action, leftover pill
be4ee05  fix(demo+agent): seed contract missing version:1; agent biased toward Observe
c1f8ffe  fix(agent): approve/reject/answer DML-before-callout + ground in conversations
238eb78  feat(demo): full inbound-email → workflow → agent demo seed
4aa3026  fix(agent): kickAgent fails with callout-after-DML error
3d9f435  merge: routing — Metadata API CRUD for Conversation_Routing_Rule
190031c  merge: Agent Mode — field-question pills + workflow builder agent panel
56fc7cc  merge: Stage_Status__c badge in record-page header
55eb4b3  feat(action-status): configurable per-action status machine editor
03e1dc8  merge: lane-I runtime — action status evaluator + engine + hooks
27fbdbd  feat(agent-mode): finish Agent Mode — decision log + record-page integration + tests
```

GitHub: `https://github.com/pleDeveloper/plseCoreNextGen` (107 commits on `main`).

---

## 13. Files most worth reading

For a demo agent that needs to understand the runtime fast, read these in order:

| Order | File | What you learn |
|---|---|---|
| 1 | [packages/pulse-core/.../classes/PulseAgentOrchestrator.cls](packages/pulse-core/force-app/main/default/classes/PulseAgentOrchestrator.cls) | The agent loop, autonomy logic, system prompt, context payload shape, placeholder reuse |
| 2 | [packages/pulse-core/.../classes/WorkflowContract.cls](packages/pulse-core/force-app/main/default/classes/WorkflowContract.cls) | Contract schema, parser, validation |
| 3 | [scripts/seed-leasing-e2e-demo.apex](scripts/seed-leasing-e2e-demo.apex) | A complete contract example with actions + status machines |
| 4 | [packages/pulse-core/.../classes/PulseInboundEmailHandler.cls](packages/pulse-core/force-app/main/default/classes/PulseInboundEmailHandler.cls) | Email → routing rule → record → workflow start |
| 5 | [packages/pulse-core/.../classes/HitlService.cls](packages/pulse-core/force-app/main/default/classes/HitlService.cls) | Tool resolution, refined-payload flow, audit events, post-execute lifecycle |
| 6 | [packages/pulse-core/.../classes/PulseRuntimeController.cls](packages/pulse-core/force-app/main/default/classes/PulseRuntimeController.cls) | Aura surface — `getInstanceForRecord`, `advanceInstance`, `resolveAction` |
| 7 | [packages/pulse-core/.../lwc/pulseRecordStepper/](packages/pulse-core/force-app/main/default/lwc/pulseRecordStepper/) | The journey-card record page UI |
| 8 | [packages/pulse-core/.../lwc/pulseAgentDecisionQueue/](packages/pulse-core/force-app/main/default/lwc/pulseAgentDecisionQueue/) | Agent decision card rendering, refine flow |
| 9 | [packages/pulse-tools-core/.../classes/PulseEmailTool.cls](packages/pulse-tools-core/force-app/main/default/classes/PulseEmailTool.cls) | Tool input schema (`toAddress`/`subject`/`body`), Task fallback |
| 10 | [docs/pulse-nextgen-architecture-review-and-build-plan.md](docs/pulse-nextgen-architecture-review-and-build-plan.md) | The original architectural blueprint |

---

## 14. Open follow-ups + known limitations

- **Outbound email** falls back to Task activity on scratch/dev orgs without verified email deliverability.
- **External Credential is manual.** No source-deployable artifact exists for it. Each new org needs the 5-step UI walkthrough in Section 10A.
- **CMDT hard-delete** is not supported by the platform Metadata API. Routing rules and similar admin-managed CMDT use soft-delete (`Active__c = false`).
- **Action_Hub_Column_Config** field is `Target_Object__c` (not `Object_Api_Name__c` — earlier bootstrap script had this wrong; current scripts are correct).
- **The agent currently runs synchronously inside `Kick agent`.** For long-form drafting it can hit Aura timeouts. If a user reports "spinning forever," check `Agent_Thread__c.Last_Error__c` — most likely a credential or callout issue.
- **`WorkflowInstanceActionTrigger` only fires on insert.** Re-instantiating placeholders after manual phase reset requires deleting and recreating the instance, or calling `PulseActionInstantiationService.instantiateForPhase(instanceId)` from anonymous Apex.
- **Stage_Status__c** values render with a fixed mapping in `pulseRecordStepper.stageStatusVariant`: `Escalated → error`, `On_Hold | Paused → warning`, `Waiting_External → purple`, blank → no badge. To add new stage statuses, update both the picklist (if you're using one) and the mapping.

---

## 15. Quick-start for the demo agent

You're operating in **`pulse-clientdemo`** (`00DgL00000QL8YHUA1`). Source is deployed; CMDT is bootstrapped.

```bash
# Verify org connection
sf org display -o pulse-clientdemo

# Confirm CMDT records exist (should return rows)
sf data query -q "SELECT DeveloperName FROM Workflow_Tool_Registration__mdt" -o pulse-clientdemo

# After Section 10 (External Credential + permset) is done, smoke-test:
sf apex run -o pulse-clientdemo <<< 'PulseAiModels.Request req = new PulseAiModels.Request(); req.messages.add(new PulseAiModels.Message("user","ping")); System.debug(PulseAiFacade.invoke(req).text);'
```

To build a new client demo:
1. Author the contract JSON (Section 5) — you can do it by editing `seed-leasing-e2e-demo.apex` for a similar shape, or build a new seed script.
2. Publish via `Workflow_Definition__c` (insert with `Definition_JSON__c`, `Workflow_Key__c`, `Status__c='Published'`, `Version__c=1`).
3. Either: add a `Conversation_Routing_Rule__mdt` so inbound emails create records + start the workflow automatically, OR have the demo seed simulate inbound via `new PulseInboundEmailHandler().handleInboundEmail(email, env)`.
4. Bind the workflow to a parent record by creating a `Workflow_Instance__c` referencing the published definition + the parent record id + initial `Current_State__c`.
5. Pin the record page → drop in `pulseRecordStepper` LWC, click **Kick agent**.

When in doubt about agent behavior, **read the rationale field on the latest `Agent_Decision__c`** — Harper explains every choice. If a decision goes wrong, that text tells you whether to tune the system prompt, the context payload, or the contract.
