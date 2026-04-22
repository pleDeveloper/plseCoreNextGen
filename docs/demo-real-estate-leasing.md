# Demo — Real Estate Leasing on Opportunity

A concrete end-to-end scenario you can run in the scratch org to see every piece of Pulse Core Next doing its job. Pairs with `docs/product-overview.md` (read that first for the model) and `docs/recall-integration-setup.md` (for live transcription).

## The scenario

A commercial real-estate brokerage manages leasing deals in Salesforce. Each deal is an Opportunity. The leasing process has these states:

| State | Type | What happens |
|---|---|---|
| `intake` | form | Agent captures the prospective tenant's basic info + space requirements |
| `tour_scheduled` | form | Tour date + property confirmed |
| `application_submitted` | approval | Tenant submits application + documents |
| `credit_review` | approval | Underwriting reviews credit + references |
| `lease_drafted` | form | AI drafts initial terms based on intake + credit output |
| `signed` | terminal | Executed lease + confirmation |
| `declined` | terminal | Deal lost |

Fields that project onto the Opportunity (the "Show on record page & include in reports" toggle):
- `applicant_name` (Text) → `plse__Applicant_Name__c`
- `requested_sqft` (Number) → `plse__Requested_Sqft__c`
- `credit_score` (Number) → `plse__Credit_Score__c`
- `lease_term_months` (Number) → `plse__Lease_Term_Months__c`
- `monthly_rent` (Currency) → `plse__Monthly_Rent__c`

Fields that stay in step history (toggle off):
- `intake_notes` (LongTextArea) — conversational context for the rep
- `credit_review_comments` (LongTextArea) — underwriter's rationale
- `tour_host_name` (Text) — internal record of who showed the property

## Seeding the demo in your scratch org

Run the anonymous Apex seed script:

```
sf apex run -o pulse-core-next-dev -f scripts/seed-real-estate-demo.apex
```

This creates:
- A `Workflow_Definition__c` with the leasing contract (status = `Published`).
- Six `Workflow_Projection__mdt` records mapping the projected fields to Opportunity.
- A sample `Opportunity` named "Downtown Law Firm — 8,500 sqft lease".
- A `Workflow_Instance__c` on that Opportunity at state `credit_review`.
- Three completed `Workflow_Step_Result__c` history rows (`intake`, `tour_scheduled`, `application_submitted`).
- Three `Stage_Dwell__c` rows from the three completed states (so the SLA heatmap has data).
- One `Conversation__c` with three turns representing the tenant's initial email inquiry.
- One `Conversation_Extract__c` with `Status='Pending'`, proposing `applicant_name`, `requested_sqft`, and `lease_term_months` facts.
- One `Workflow_Action__c` with `Status='Pending'` representing an AI-proposed credit report fetch that needs approval.

The seed is idempotent — running it twice does not duplicate rows. Safe to re-run after clearing the scratch or mid-demo to reset.

## The demo flow (what to click)

### 1. See the Admin Studio

Open the **Pulse Admin Studio** tab (or app).

- **Workflow Builder** panel: select "Real Estate Leasing". See states, transitions, per-state fields. Toggle a field's "Show on record page" checkbox to see the live preview panel update.
- **Action Hub** panel: one pending HITL approval — the AI's proposed credit report fetch. Click **Approve** or **Reject** to resolve.
- **Conversations** panel: one pending extract with 3 facts. Check one or two, click **Accept selected** → the facts promote onto the seeded Opportunity. Open the Opportunity to verify.
- **SLA** panel: heatmap with three states showing median/p90 dwell times from the seeded history.
- **AI Config** / **Integrations Hub** / **Settings** panels (after Wave 6 merges): read-only views of providers, credentials, tools, feature flags, deployment history.

### 2. See the record-page experience

Open the seeded Opportunity ("Downtown Law Firm — 8,500 sqft lease"):

- The `pulseRecordStepper` LWC on the page shows the workflow at **Credit Review** with available signals: `approve_credit`, `decline_credit`, `request_more_info`.
- Click **Approve credit** → runtime advances → state becomes `lease_drafted` → history entry appears.
- The `pulseActionHub` LWC on the same page shows the pending credit-report approval (if you haven't resolved it yet in Admin Studio).
- The `pulseConversationHub` LWC on the same page shows the tenant's inquiry email + pending extract.

### 3. See the schema-provisioning flow

In Admin Studio → Workflow Builder → Publish the leasing workflow.

- The deploy dialog opens.
- It calls `SchemaProvisioningService.provision()` with the five projected field specs.
- Because `callout:Pulse_Self_Org_Tooling` Named Credential hasn't been configured yet (that's a one-time admin step — see `docs/schema-provisioning-setup.md`), the callouts will fail with a useful error message.
- If you configure the Named Credential first, the Publish call creates real custom fields on the Opportunity schema via the Tooling API, and the new Opportunity layout picks them up.

### 4. See the AI extraction loop (without Recall)

Using the seed data:

- Admin Studio → Conversations panel → view the email inquiry.
- The pending extract shows three proposed facts with confidence bars.
- Accept two of them.
- Open the Opportunity — those fields are populated, and the extract is marked `Accepted` (or `Partial` if a confidence fell below your threshold for your configured profile).
- Click **Request re-extraction** to re-enqueue `PulseConversationExtractor` for the same conversation. This re-runs the LLM against the transcript and may produce new facts.

### 5. See the AI extraction loop WITH Recall live transcription

See `docs/recall-integration-setup.md` for the end-to-end setup. Summary:

1. Create a Recall.ai account, get an API key.
2. Configure the `Pulse_Recall_Api` Named Credential in your scratch org pointing at `https://api.recall.ai` with the API key as Authorization.
3. Seed a `Conversation_Source_Registration__mdt` row for the Recall adapter (`Adapter_Class__c = plse.RecallAdapter`).
4. Invite Recall's bot to a Zoom/Google Meet/Teams call by calling `RecallAdapter.createBot(meetingUrl)` from the Admin Studio Integrations Hub or via anonymous Apex.
5. Have a 5-minute conversation about a deal.
6. When Recall finishes transcription, it hits your webhook (configured in Recall's dashboard → Salesforce Apex REST endpoint or your custom platform event path). `RecallAdapter.normalizePayload()` converts the transcript into `Conversation__c` + turns.
7. `ConversationIngestionService` auto-enqueues `PulseConversationExtractor` as a Queueable.
8. A `Conversation_Extract__c` appears with proposed facts.
9. Open the Conversation Hub → review → accept.

## What to tell non-engineers

Pitch the demo this way:

> "Pulse is three things at once: a workflow engine that runs on any Salesforce record, an AI layer that proposes actions with human approval, and an intelligence layer that turns conversations into structured data your CRM can actually use. Every field the admin configures is a real Salesforce field — reportable, queryable, governed by standard permissions. Every AI action is audited and approvable. Every conversation becomes a row your reps can act on."

## What breaks the demo

- **Named Credential missing** → Publish flow can't create fields. Configure `Pulse_Self_Org_Tooling` first.
- **No Pulse_Core_Admin permset assigned** → the current user can't read the `plse__` namespace fields. Run `sf org assign permset -o pulse-core-next-dev -n Pulse_Core_Admin`.
- **Seed script run on a non-namespaced scratch** → field references fail because the scratch doesn't have the `plse` namespace installed. Scratch org must be created with `"namespace": "plse"` in the scratch-def.
- **Recall bot can't join** → Recall's dashboard has per-workspace limits; check your plan's concurrency.
- **Extract returns empty facts** → check the Extraction_Profile__mdt.Schema_JSON__c — the LLM needs a schema telling it what facts to extract. The seed uses a minimal example profile.

## Variations to try

- **Add a new state to the workflow mid-flight** — the builder's live preview updates instantly; Publish re-runs schema provisioning only for the deltas.
- **Change a field's projection toggle** — watch the live preview move the field between "Referral page" and "Step history" columns.
- **Reject an AI tool proposal** — see the `Workflow_Action__c` history + the agent loop continuing with the rejection recorded.
- **Let an instance idle past its p90 dwell** — the SLA heatmap colors it red and `StageDwellPredictor.predictExitFor()` flags `isOverdue = true`.
