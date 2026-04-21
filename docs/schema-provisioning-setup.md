# Schema Provisioning — Named Credential Setup

## Why This Is Needed

Pulse Core Next auto-provisions custom fields on subscriber objects when a
workflow is published (see architecture doc §4.6).

The Apex `Metadata.CustomField` type is **not available** in this org (and
many subscriber-org editions). We verified empirically:

```apex
Metadata.CustomField cf = new Metadata.CustomField();
// → executeCompileFailure: Invalid type: Metadata.CustomField
```

Instead, the `ToolingApiDeploymentGateway` creates fields via the **Tooling
API REST endpoint** (`/services/data/v62.0/tooling/sobjects/CustomField`).
Because Apex cannot call its own org's REST API directly, we use a Named
Credential that points back at the same org — the *self-org callout* pattern.

## Setup Steps

### Option A — Legacy Named Credential (simplest)

1. **Setup → Named Credentials → New Legacy**
2. Fill in:
   | Field | Value |
   |-------|-------|
   | Label | `Pulse Self Org Tooling` |
   | Name | `Pulse_Self_Org_Tooling` |
   | URL | `https://<your-org-mydomain>.my.salesforce.com` |
   | Identity Type | Named Principal |
   | Authentication Protocol | Password Authentication |
   | Username | The integration user's username (or `{!$Credential.Username}`) |
   | Password | `{!$Api.Session_ID}` |
   | Generate Authorization Header | **checked** |
   | Allow Merge Fields in HTTP Body | **checked** |
3. Click **Save**.

### Option B — External Credential + Named Credential (preferred for production)

1. **Setup → External Credentials → New**
   - Label: `Pulse Self Org`
   - Authentication Protocol: Custom
   - Add a Principal: Name = `PulseSelfOrg`, Sequence = 1
2. **Setup → Named Credentials → New**
   - Label: `Pulse Self Org Tooling`
   - Name: `Pulse_Self_Org_Tooling`
   - URL: `https://<your-org-mydomain>.my.salesforce.com`
   - External Credential: `Pulse Self Org`
   - Authentication Flow: Browser Flow or Per-User Session
3. Map the session to the calling user's session token.

> For most scratch-org and sandbox setups, **Option A** is sufficient.

## Required User Permissions

The user whose credentials are used by the Named Credential needs:

| Permission | Why |
|------------|-----|
| `Modify Metadata Through Metadata API Functions` | Required by the Tooling API to create `CustomField` records |
| `Customize Application` | Allows field creation on standard and custom objects |

Both permissions are available via a Permission Set or Profile assignment.

## Error Codes and Admin-Facing Messages

If the Named Credential is misconfigured, the gateway surfaces these errors:

| HTTP Status | Likely Cause | Admin Action |
|-------------|-------------|--------------|
| `401 Unauthorized` | Named Credential auth failed — bad password/session or NC name mismatch | Verify the NC name is exactly `Pulse_Self_Org_Tooling` and the URL matches the org's My Domain |
| `403 Forbidden` | User lacks `Customize Application` or Metadata API permission | Grant the required permissions to the NC user |
| `404 Not Found` | Wrong URL or API version | Verify NC URL is `https://<mydomain>.my.salesforce.com` with no trailing path |
| `400 Bad Request` with `DUPLICATE_VALUE` | Field already exists on the target object | Safe to ignore — the gateway reports this as a partial success |
| `400 Bad Request` with `INVALID_FIELD` | Malformed field metadata (bad type, missing required attribute) | Check the field spec in the deployment plan JSON |

## Verification

After configuring the Named Credential, run this anonymous Apex to confirm
the self-org callout works:

```apex
HttpRequest req = new HttpRequest();
req.setEndpoint('callout:Pulse_Self_Org_Tooling/services/data/v62.0/tooling/sobjects');
req.setMethod('GET');
req.setHeader('Content-Type', 'application/json');
HttpResponse resp = new Http().send(req);
System.debug('Status: ' + resp.getStatusCode());
System.debug('Body: ' + resp.getBody().substring(0, Math.min(200, resp.getBody().length())));
// Expected: Status 200, body contains a JSON array of Tooling API sobjects
```

Run via: `sf apex run -f verify-nc.apex -o <org-alias>`

A `200` response confirms the Named Credential is working. If you get `401`,
`403`, or `404`, consult the error table above.

## What This Does NOT Do

- **Does not deploy the Named Credential automatically.** This is a manual,
  per-org admin step. The NC configuration depends on the org's My Domain and
  cannot be packaged.
- **Does not grant FLS or add fields to page layouts.** That is a follow-on
  wave (permission-set auto-grant and layout placement).
- **Does not handle Picklist fields.** Picklist creation requires a `valueSet`
  payload and is deferred to a later wave. The gateway throws
  `UnsupportedOperationException` if a Picklist field is requested.
