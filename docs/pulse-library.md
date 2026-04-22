# Pulse Library — Distribution

Pulse Library lets organisations share workflow definitions as **signed bundles**.
A publisher signs a bundle with an RSA key; a subscriber verifies the signature
against a trusted-publisher list before installing the workflow.

## What is a bundle?

A bundle is a JSON document (`pulse.bundle.v1`) containing:

- A single `workflowDefinitionJson` (the `pulse.workflow.v1` contract).
- Metadata: `bundleKey`, `version`, `publisherId`, `displayName`, `dependencies`.
- Audit fields: `publishedAt`, `publishedBy`, `publishedByName`.

The bundle is paired with a **detached RSA-SHA256 signature** (base64-encoded).
Together they prove who published the bundle and that it hasn't been tampered with.

## Publisher workflow

### 1. Generate an RSA-2048 key pair

```bash
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out publisher_private.pem
openssl rsa -in publisher_private.pem -pubout -out publisher_public.pem
```

Keep `publisher_private.pem` secret (password manager, secrets vault).
Distribute `publisher_public.pem` to subscribers.

### 2. Publish a bundle

From Execute Anonymous or a CLI wrapper:

```apex
PulseLibraryPublisher.PublishRequest req = new PulseLibraryPublisher.PublishRequest();
req.workflowDefinitionId = '<Workflow_Definition__c Id>';
req.bundleKey            = 'healthcare-intake-v3';
req.displayName          = 'Healthcare Intake';
req.publisherId          = 'acme_health';
req.version              = '1.2.0';
req.privateKeyPem        = '<contents of publisher_private.pem>';
req.publicKeyPem         = '<contents of publisher_public.pem>';

PulseLibraryPublisher.PublishResult res = PulseLibraryPublisher.publish(req);
System.debug(res.bundleJson);
System.debug(res.signatureB64);
```

The private key is provided per-invocation and is **never persisted** by the
platform. It is the admin's responsibility to keep it safe.

### 3. Distribute

Send the `bundleJson` and `signatureB64` to the subscriber (email, file share,
internal portal — whatever your org uses). There is no central registry in v1.

## Subscriber workflow

### 1. Configure a trusted publisher

Create a `Trusted_Publisher__mdt` record:

| Field             | Value                                          |
|-------------------|------------------------------------------------|
| DeveloperName     | `acme_health` (must match `publisherId`)       |
| Display Name      | Acme Health Publishing                         |
| Public Key PEM    | Contents of `publisher_public.pem`             |
| Active            | `true`                                         |

Setting `Active` to `false` revokes trust — installs will be rejected even if
the signature is cryptographically valid.

### 2. Install via the Library Browser UI

1. Open **Admin Studio → Library**.
2. Click **Paste bundle**.
3. Paste the bundle JSON and signature into the two fields.
4. Click **Install**.

The installer validates trust, signature, dependencies, and the workflow
contract before creating a `Workflow_Definition__c` and recording the install in
`Pulse_Library_Bundle__c`.

### 3. Install via Apex

```apex
PulseLibraryInstaller.InstallResult res = PulseLibraryInstaller.installBundle(
    bundleJson, signatureB64
);
System.debug(res.success);
System.debug(res.workflowDefinitionId);
```

## Versioning and supersession

Each install of the same `bundleKey` supersedes the previous one:

- The new bundle's `Previous_Bundle__c` points to the old row.
- The old bundle's `Status__c` changes from `Installed` to `Superseded`.

## Rollback

Roll back reverts to the immediately previous version:

1. The current bundle is marked `Rolled_Back`.
2. The previous bundle is re-activated (`Installed`).
3. Active `Workflow_Instance__c` records are re-pointed to the previous
   definition.

### Rollback safety constraint

**Rollback is rejected when any active workflow instance is in a state that does
not exist in the target (previous) version's contract.**

For example: if v2 added a `review` state and an instance is currently in
`review`, rolling back to v1 (which has no `review` state) would leave that
instance in an invalid state. The rollback will fail and list the blocking
instance IDs so the admin can resolve them first (e.g., advance or suspend those
instances).

This is a deliberate safety measure — automatic state migration is out of scope
for v1.

## Dependencies

Bundles can declare dependencies on other bundles:

```json
"dependencies": [
  { "bundleKey": "base-forms", "minVersion": "2.0.0" }
]
```

The installer checks that each dependency is satisfied (an `Installed` bundle
with `Version >= minVersion`) before proceeding.

## Data model

| Object                      | Purpose                                       |
|-----------------------------|-----------------------------------------------|
| `Pulse_Library_Bundle__c`   | Record-per-install; drives versioning/rollback |
| `Trusted_Publisher__mdt`    | Org-level trust list (CMDT)                   |

## Limitations (v1)

- **No pre-release semver tags** — versions are three-component numeric only
  (`1.2.3`).
- **Single workflow per bundle** — multi-workflow bundles are not supported.
- **No central registry** — bundles are distributed manually (paste, file share).
- **No auto-update** — subscribers pull new versions explicitly.
- **No audit export** — install history is queryable via SOQL but there is no
  built-in reporting dashboard.
