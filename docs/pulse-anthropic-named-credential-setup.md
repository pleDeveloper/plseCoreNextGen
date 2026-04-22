# Pulse Anthropic Named Credential Setup

This is the admin-facing walkthrough for wiring the `Pulse_Anthropic` Named
Credential that Pulse Core Next uses to call Anthropic's Claude Messages API.

## 1. What this is for

Pulse Core Next drives AI-driven workflow states (drafting, extraction,
tool-calling) through `plse.PulseAiFacade`, which delegates to a configured
provider adapter. The Anthropic adapter calls `https://api.anthropic.com/v1/messages`
and needs the `x-api-key` header set to your org's Anthropic key.

Per Pulse security posture: no secrets live in code or Custom Metadata.
Everything routes through a Named Credential + External Credential.

## 2. What you need before you start

- **System Administrator** profile (or equivalent Setup + Named Credential
  permissions) in the target Salesforce org
- **Anthropic API key**: generate one at <https://console.anthropic.com/>
  → Settings → API Keys. Copy it once — Anthropic does not show it again
- **Pulse Core Next** package installed and the `Pulse_Core_Admin` permission
  set available (ships with the managed package)

## 3. Preferred path: External Credential + Named Credential

This is the modern (Winter '23+) path. Use it unless your org has Legacy
Named Credentials only — in that case, jump to section 4.

### 3.1 Create the External Credential

1. Setup → **Named Credentials** → **External Credentials** tab → **New**
2. Fill in:
   - **Label**: `Pulse Anthropic EC`
   - **Name**: `Pulse_Anthropic_EC`
   - **Authentication Protocol**: `Custom`
3. Save

### 3.2 Create a Principal

1. Still on the External Credential detail page, scroll to **Principals** →
   **New**
2. Fill in:
   - **Parameter Name**: `PulseAnthropicPrincipal`
   - **Sequence Number**: `1`
   - **Identity Type**: `Named Principal`
   - **Authentication Parameters**: add one row
     - **Name**: `ApiKey`
     - **Value**: paste your Anthropic API key (the `sk-ant-...` string)
3. Save

### 3.3 Add the custom auth header

1. Still on the External Credential detail page, go to **Custom Headers** →
   **New**
2. Fill in:
   - **Name**: `x-api-key`
   - **Value**: `{!$Credential.Pulse_Anthropic_EC.ApiKey}`
   - **Sequence Number**: `1`
3. Save

Header name is case-sensitive for Anthropic. Use lower-case `x-api-key`.

### 3.4 Create the Named Credential

1. Setup → **Named Credentials** → **Named Credentials** tab → **New**
2. Fill in:
   - **Label**: `Pulse Anthropic`
   - **Name**: `Pulse_Anthropic` (must match exactly — the CMDT points here)
   - **URL**: `https://api.anthropic.com`
   - **External Credential**: `Pulse_Anthropic_EC`
   - **Client Certificate**: leave blank
   - **Generate Authorization Header**: **unchecked** (we supply headers
     via the External Credential's Custom Headers; leaving this on will
     cause Salesforce to inject an Authorization header Anthropic rejects)
   - **Allow Formulas in HTTP Header**: **checked**
   - **Allow Formulas in HTTP Body**: **checked** (optional, harmless)
   - **Callout Options → Allowed Namespaces**: leave blank unless you
     package Pulse yourself; the managed `plse` namespace is granted via
     permset
3. Save

### 3.5 Grant the permset access to the Principal

The header formula only resolves if the running user has access to the
External Credential Principal.

1. Setup → **Permission Sets** → `Pulse_Core_Admin` → **External
   Credential Principal Access** → **Edit**
2. Move `Pulse_Anthropic_EC - PulseAnthropicPrincipal` to **Enabled**
3. Save
4. Assign `Pulse_Core_Admin` to yourself (and any user who will run
   AI-driven workflow states) if not already

If you have a separate runtime-user permset (e.g. `Pulse_Workflow_User`),
grant it the Principal too — the running user of any queueable or async
job that invokes the adapter needs it.

## 4. Fallback: Legacy Named Credential

Only if your org has Legacy Named Credentials UI and you cannot create
External Credentials.

1. Setup → **Named Credentials** → **New Legacy**
2. Fill in:
   - **Label**: `Pulse Anthropic`
   - **Name**: `Pulse_Anthropic`
   - **URL**: `https://api.anthropic.com`
   - **Identity Type**: `Named Principal`
   - **Authentication Protocol**: `Password Authentication`
   - **Username**: `apikey` (ignored, but required)
   - **Password**: paste your Anthropic API key
   - **Generate Authorization Header**: **unchecked**
   - **Allow Merge Fields in HTTP Header**: **checked**
3. Save
4. Open the Named Credential → **Custom Headers** (on some orgs this is
   not available on Legacy NCs; if missing, you must migrate to the
   modern path — Anthropic requires the `x-api-key` header and Legacy
   NCs cannot supply it without the modern header UI)
   - **Name**: `x-api-key`
   - **Value**: `{!$Credential.Password}`

## 5. Verify with anonymous Apex

Once the NC is saved and the CMDT `AI_Provider_Registration.Anthropic`
record is deployed (ships with the `Pulse AI - Anthropic` package and
sets `Named_Credential__c = Pulse_Anthropic`, `Active__c = true`), run:

```apex
plse.PulseAiModels.Request req = new plse.PulseAiModels.Request();
req.systemPrompt = 'You are a terse assistant.';
req.messages.add(new plse.PulseAiModels.Message('user',
    'Say the word "hello" and nothing else.'));
req.maxTokens = 64;

plse.PulseAiModels.Response resp = plse.PulseAiFacade.invoke(req);
System.debug('isError: ' + resp.isError);
System.debug('error:   ' + resp.errorMessage);
System.debug('text:    ' + resp.text);
System.debug('tokens:  in=' + (resp.usage == null ? null : resp.usage.inputTokens)
    + ' out=' + (resp.usage == null ? null : resp.usage.outputTokens));
```

Or run the packaged smoke test:

```bash
sf apex run -o <your-org-alias> -f scripts/smoke-test-anthropic.apex
```

Expected: `isError: false`, `text: hello` (or `Hello.` etc).

## 6. Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `API error 401 [authentication_error]: invalid x-api-key` | Header name wrong, key expired, or running user lacks Principal access | Confirm header is `x-api-key` (lower-case), regenerate key in Anthropic console, verify permset has Principal access (section 3.5) |
| `API error 401: {"error": ...}` but header looks right | Salesforce auto-injected an `Authorization` header | Uncheck **Generate Authorization Header** on the Named Credential |
| `API error 404` | Endpoint path typo | Adapter hits `callout:Pulse_Anthropic/v1/messages`. Confirm NC URL is `https://api.anthropic.com` with no trailing path |
| `API error 400 [invalid_request_error]: messages ... must be non-empty` | Request shape bug upstream | Not an NC issue — file under Pulse adapter |
| `Callout failed: Unauthorized endpoint` | NC name mismatch | CMDT `Named_Credential__c` must equal the NC **Name** exactly (`Pulse_Anthropic`) |
| `No active AI provider configured` | CMDT record missing or `Active__c = false` | Deploy `AI_Provider_Registration.Anthropic` from `pulse-ai-anthropic` package, or flip the record active in Setup → Custom Metadata Types |
| `Provider class not found: AnthropicAdapter` | `pulse-ai-anthropic` package not installed | Install the Pulse AI - Anthropic add-on package |
| Runs fine as admin, fails as end user | End user missing Principal access | Grant the end user's permset access to the External Credential Principal (section 3.5) |

## 7. Rotating the key

1. Generate a new key at <https://console.anthropic.com/>
2. Setup → External Credentials → `Pulse_Anthropic_EC` → Principals →
   `PulseAnthropicPrincipal` → **Edit**
3. Replace the `ApiKey` parameter value, save
4. Revoke the old key in the Anthropic console
5. Re-run the smoke test to confirm
