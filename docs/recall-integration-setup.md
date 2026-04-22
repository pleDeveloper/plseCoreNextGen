# Recall.ai Integration Setup

How to connect Pulse Core Next to Recall.ai so meeting transcripts automatically become `Conversation__c` records with AI-extracted facts.

The `RecallAdapter` class is already in `packages/pulse-conversations-recall/`. What's missing from your scratch org is the external setup (Recall account, API key, Named Credential). This doc walks through that one-time configuration.

## What you'll need

- A Recall.ai account — sign up at [recall.ai](https://www.recall.ai/). Their free tier supports basic bot-in-meeting transcription for evaluation.
- An API key from Recall's dashboard → Settings → API Keys.
- Access to Salesforce Setup in the scratch org (you already have this as admin).
- 15 minutes for the one-time configuration.

## Step 1 — Create the Named Credential

In Setup → Security → Named Credentials → New (use the Legacy flow for simplicity in a scratch org):

| Field | Value |
|---|---|
| Label | Pulse Recall API |
| Name | `Pulse_Recall_Api` |
| URL | `https://us-west-2.recall.ai` (or the region of your Recall account) |
| Identity Type | Named Principal |
| Authentication Protocol | Password Authentication |
| Username | `api` (Recall accepts any value; the API key goes in the password field) |
| Password | *your Recall API key* |
| Generate Authorization Header | ✅ checked |
| Allow Merge Fields in HTTP Header | ✅ checked |
| Allow Merge Fields in HTTP Body | ✅ checked |

**Custom headers** (Named Credential → Custom Headers section — add one):

| Name | Value |
|---|---|
| `Authorization` | `Token {!$Credential.Password}` |

Recall uses `Authorization: Token <api_key>` instead of the standard Basic auth the Named Credential generates by default; the custom header overrides it with the correct shape.

Save.

## Step 2 — Register the adapter in `Conversation_Source_Registration__mdt`

The Pulse Conversations Core package queries `Conversation_Source_Registration__mdt` to know which adapter handles which incoming channel. Seed a row via Setup → Custom Metadata Types → Conversation Source Registration → New:

| Field | Value |
|---|---|
| Label | Recall Meetings |
| Source Registration Name | `Recall_Meetings` |
| Source Key | `recall` |
| Adapter Class | `plse.RecallAdapter` |
| Active | ✅ checked |

Save. This tells `ConversationIngestionService` that inbound payloads tagged `recall` should be normalized by `RecallAdapter.normalizePayload()`.

## Step 3 — Expose the webhook endpoint

Recall needs somewhere to POST transcript-ready events. Pulse Core Next ships a platform event — `Pulse_Deployment_Status__e` — but that's for deploys; there's not yet a dedicated `Pulse_Conversation_Ingest__e`. For a scratch-org demo, the simplest path is an Apex REST endpoint:

```apex
@RestResource(urlMapping='/pulse/recall/webhook/*')
global class PulseRecallWebhook {
    @HttpPost
    global static String handle() {
        RestRequest req = RestContext.request;
        String bodyJson = req.requestBody.toString();

        // Delegate to the adapter for normalization, then ingest.
        Map<String, Object> payload =
            (Map<String, Object>) JSON.deserializeUntyped(bodyJson);

        PulseConversationAdapter adapter = new RecallAdapter();
        ConversationIngestionService.ConversationInput input =
            adapter.normalizePayload(payload);

        ConversationIngestionService.ingest(new List<ConversationIngestionService.ConversationInput>{ input });

        return 'ok';
    }
}
```

(This class is not in the core package — you'd deploy it as a one-off Apex class in your scratch. A production deploy would promote it into `pulse-conversations-recall` with proper tests, which is deferred to a later wave because webhook endpoints need signature verification done right.)

Expose the REST endpoint for guest / Recall user access — in Setup → Apex Classes → `PulseRecallWebhook` → Security → enable the class for the profile that will call it.

The public URL of your scratch org's REST endpoint is something like:

```
https://<your-scratch-org-mydomain>.my.salesforce.com/services/apexrest/pulse/recall/webhook
```

## Step 4 — Register the webhook in Recall

In Recall's dashboard → Webhooks → Add Webhook:

- **URL**: the Apex REST endpoint from Step 3
- **Events**: select `bot.transcription.ready` (at minimum)
- **Secret**: generate and save one; production-grade code should verify the signature, but for the scratch-org demo we skip verification.

Save.

## Step 5 — Invite the Recall bot to a meeting

From anonymous Apex (or eventually from the Pulse Integrations Hub):

```apex
String meetingUrl = 'https://us02web.zoom.us/j/1234567890'; // your Zoom/Meet/Teams URL
Id workflowInstanceId = '<plse__Workflow_Instance__c id to link the conversation to>';
Id parentRecordId = '<Opportunity id or whichever SObject>';

RecallAdapter.BotCreateResult result =
    RecallAdapter.createBot(meetingUrl, workflowInstanceId, parentRecordId);

System.debug('Recall bot Id: ' + result.botId);
System.debug('Bot join URL: ' + result.joinUrl);
```

Recall's bot joins the meeting as a participant and starts recording + transcribing.

## Step 6 — Join the meeting and talk

Have a 2–5 minute conversation. Example script for the real-estate-leasing scenario:

> "Hi, this is Jordan from AB Properties. I'm calling about the 8,500 square foot space on Lexington Ave. I'm looking for a five-year lease, starting around $42 per square foot. Can we schedule a tour for next Tuesday?"

Hang up. Leave the bot in the meeting for ~30 seconds — Recall needs a beat to finalize the transcript.

## Step 7 — Watch the pipeline

Within about a minute of the meeting ending:

1. Recall's backend transcribes → fires `bot.transcription.ready` → POSTs to your webhook.
2. `PulseRecallWebhook` receives the payload.
3. `RecallAdapter.normalizePayload()` turns it into a `ConversationInput`.
4. `ConversationIngestionService.ingest()` creates:
   - A `Conversation__c` record linked to the Opportunity and workflow instance.
   - One `Conversation_Turn__c` per distinct speaker turn.
5. The ingestion service enqueues `PulseConversationExtractor` as a Queueable.
6. Extractor loads the transcript + the matching `Extraction_Profile__mdt.Schema_JSON__c`, calls the configured AI provider, and creates a `Conversation_Extract__c` with proposed facts.

## Step 8 — Review the extract in the Conversation Hub

Open the Opportunity → scroll to the `pulseConversationHub` LWC on the page (or open Admin Studio → Conversations):

- The new conversation appears at the top of the list, collapsed.
- Expand it — see the turn transcript (speaker + content) and the pending extract.
- Proposed facts might include: `applicant_name = "Jordan (AB Properties)"`, `requested_sqft = 8500`, `lease_term_months = 60`, `monthly_rent = 42` (depending on your extraction schema), each with a confidence bar.
- Click the fields you want to commit → **Accept selected**.
- Those fields project onto the Opportunity via `ProjectionWriteService`.
- The extract is marked `Accepted`.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Recall bot never joins | Wrong meeting URL format or Recall account lacks that platform | Verify URL with Recall's supported-platforms list; check Recall account quotas |
| Webhook 401/403 from Salesforce | Apex class not exposed to the profile calling it | Setup → Apex Classes → PulseRecallWebhook → Security |
| Conversation record appears but no extract follows | Queueable didn't fire or extractor threw | Check `AsyncApexJob` for the extractor's recent runs; look at debug logs |
| Extract has empty `Facts_JSON` | Extraction profile's `Schema_JSON` is missing or too vague | Edit the profile — the schema tells the LLM what to pull |
| Facts have low confidence everywhere | Model too weak or prompt too loose | Switch `AI_Provider_Registration__mdt` to Claude Sonnet or GPT-4-class; refine the profile schema |
| "Accept selected" produces "Target field is not updateable" | FLS on the projected Opportunity field is not granted | Assign `Pulse_Core_Admin` permset to the reviewer |

## What Recall integration does NOT do (yet)

- **No real-time streaming.** Pulse gets the transcript after the meeting ends, not during. Live-streaming transcripts would require a different Recall API tier + websocket handling — deferred.
- **No speaker identification beyond Recall's defaults.** If Recall can't tell who's talking, turns land with `Speaker__c = null` — reviewers see "unknown speaker" in the UI.
- **No automatic meeting invite.** You (or a separate scheduling tool) have to invite Recall's bot URL to the meeting; Pulse doesn't yet auto-schedule that from a workflow state.
- **No webhook signature verification.** The demo webhook accepts any POST. Production needs HMAC verification against Recall's signing secret.

These are each small features we can ship later; they're not blockers for the core extract-and-review loop.

## Cost expectations for evaluation

- Recall.ai free tier typically gives you ~60 bot-minutes / month.
- Each extract costs one LLM call — in the Anthropic Sonnet range that's roughly $0.01–0.05 per conversation depending on transcript length.
- Salesforce-side: no additional licensing; all this is standard Apex + Named Credential + managed package install.
