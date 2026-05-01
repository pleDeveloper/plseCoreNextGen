# Agentforce Adapter — Status & Validation Notes

This document tracks the verification status of `AgentforceAdapter`
(`packages/pulse-core/force-app/main/default/classes/AgentforceAdapter.cls`).

## Current status: SKELETON

The adapter is built mirroring `AnthropicAdapter`'s structure, against
the **publicly documented** shape of Salesforce's Einstein / Agentforce
Models API. It has **not yet been validated against a live Agentforce
org**. It compiles, tests pass against mocked HTTP, and it is wired into
`PulseAiFacade.PROVIDER_CLASS_MAP`.

The next engineer with access to a real org should walk through the
"Verification checklist" below and remove the `// TODO(agentforce):`
markers as each item is confirmed.

## Why it lives in pulse-core

Unlike `AnthropicAdapter` (which is an optional add-on package because
not every customer wants to send data to Anthropic), Agentforce is
Salesforce-native. Any org that installs pulse-core already has the
Einstein platform available, so the adapter ships in the core package
to guarantee a working out-of-the-box AI provider.

## Assumed API endpoint shape

```
POST callout:<Named_Credential>/services/data/v60.0/einstein/llm/generations
Content-Type: application/json
x-sfdc-app-context: EinsteinGPT
x-client-feature-id: ai-platform-models-connected-app
```

Request body (assumed):

```json
{
  "model": "<Model_Id__c>",
  "prompt": "<flattened system + tools + messages>",
  "locale": "en_US",
  "num_generations": 1,
  "max_tokens": 4096
}
```

Response body (assumed):

```json
{
  "id": "gen_...",
  "generations": [{ "text": "...", "tokenCount": 42 }],
  "parameters": { "usage": { "promptTokens": 120, "completionTokens": 42 } }
}
```

The parser also tolerates a flat top-level `usage` map and a singular
`generation` object, which are the two other shapes seen in different
Salesforce sources.

## Tool calling

The Models API does **not** (at the time of writing) support a
structured `tool_use` schema equivalent to Anthropic's. The skeleton
adapter therefore:

1. Inlines tool descriptors into the prompt under a `[TOOLS]` block.
2. Instructs the model to emit a fenced ```json``` block of the form
   `{"tool":"<name>","input":{...}}` when it wants to call a tool.
3. In `parseResponse()`, scans the text for that block and synthesises
   a `PulseAiModels.ToolCall`.

When Salesforce ships first-class tool calling on the Models API, swap
the prompt assembly and `parseResponse()` to the structured shape and
delete `extractToolCall()` / `parseToolCallPayload()`.

## How to swap to a different endpoint shape

Two endpoint shapes are commonly documented:

- **Shape 1** (current): `/einstein/llm/generations` with `model` in body.
- **Shape 2**: `/einstein/llm/models/{model}/generations` with `model`
  in the path.

To switch, edit `buildHttpRequest()`:

```apex
httpReq.setEndpoint('callout:' + this.namedCredential
    + '/services/data/' + API_VERSION + '/einstein/llm/models/'
    + EncodingUtil.urlEncode(modelId, 'UTF-8') + '/generations');
// and remove body.put('model', modelId);
```

`API_VERSION` is a `@TestVisible` constant at the top of the class so
it can be bumped without a wider refactor.

## CMDT setup for admins

Create an `AI_Provider_Registration__mdt` record with:

| Field | Value |
|-------|-------|
| `Provider_Name__c`   | `Agentforce` |
| `Named_Credential__c`| Name of an Agentforce-scoped Named Credential. Salesforce ships `sfdc_ai__DefaultLLM` for the default Einstein endpoint in many orgs; otherwise create a Named Credential pointing at `https://api.salesforce.com` with appropriate auth. |
| `Model_Id__c`        | A model identifier valid in your org, e.g. `sfdc_ai__DefaultGPT4Omni`, `sfdc_ai__DefaultGPT35Turbo`, or your custom `<MyModelProvider>__<ModelName>`. |
| `Active__c`          | `true` |
| `Priority__c`        | `1` (lower = preferred) |

A specific `Agent_Role__mdt` can pin itself to this provider via
`Provider_Name__c = 'Agentforce'`, regardless of the org-default
priority order.

## Verification checklist

Each item maps to a `// TODO(agentforce):` marker in the source.

- [ ] Confirm `API_VERSION` (`v60.0`) is current; bump if needed.
- [ ] Confirm endpoint path (shape 1 vs shape 2 above).
- [ ] Confirm required headers (`x-sfdc-app-context`, `x-client-feature-id`)
      against your Named Credential setup.
- [ ] Confirm response field names: `generations` vs `generation`,
      `tokenCount` vs `generationTokenCount`, `promptTokens` vs
      `promptTokenCount` vs `input_tokens`.
- [ ] When/if structured tool calling lands, replace the prompt-based
      tool encoding with the official schema.

## Related files

- `packages/pulse-core/force-app/main/default/classes/AgentforceAdapter.cls`
- `packages/pulse-core/force-app/main/default/classes/AgentforceAdapterTest.cls`
- `packages/pulse-core/force-app/main/default/classes/PulseAiFacade.cls` (registration)
- `packages/pulse-ai-anthropic/force-app/main/default/classes/AnthropicAdapter.cls` (reference)
