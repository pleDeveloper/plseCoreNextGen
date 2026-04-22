/**
 * Publisher service for Pulse Library bundles.
 *
 * Signs a workflow definition as a distributable bundle. The private key is
 * provided per-invocation and is NEVER persisted — the admin is responsible
 * for storing it securely (e.g., in a password manager or secrets vault).
 */
global with sharing class PulseLibraryPublisher {

    global class PublishRequest {
        @AuraEnabled public Id     workflowDefinitionId;
        @AuraEnabled public String bundleKey;
        @AuraEnabled public String displayName;
        @AuraEnabled public String publisherId;
        @AuraEnabled public String version;
        @AuraEnabled public List<DependencySpec> dependencies;
        @AuraEnabled public String privateKeyPem;
        @AuraEnabled public String publicKeyPem;
    }

    global class DependencySpec {
        @AuraEnabled public String bundleKey;
        @AuraEnabled public String minVersion;
    }

    global class PublishResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String  bundleJson;
        @AuraEnabled public String  signatureB64;
        @AuraEnabled public String  publicKeyFingerprint;
        @AuraEnabled public String  error;
    }

    @AuraEnabled
    global static PublishResult publish(PublishRequest req) {
        PublishResult result = new PublishResult();
        result.success = false;

        // Validate required inputs
        if (req.workflowDefinitionId == null) {
            result.error = 'workflowDefinitionId is required';
            return result;
        }
        if (String.isBlank(req.bundleKey)) {
            result.error = 'bundleKey is required';
            return result;
        }
        if (String.isBlank(req.version)) {
            result.error = 'version is required';
            return result;
        }
        if (String.isBlank(req.privateKeyPem)) {
            result.error = 'privateKeyPem is required';
            return result;
        }

        // 1. Load and validate the workflow definition
        List<Workflow_Definition__c> defs = [
            SELECT Id, Name, Definition_JSON__c, Workflow_Key__c
            FROM   Workflow_Definition__c
            WHERE  Id = :req.workflowDefinitionId
            LIMIT  1
        ];
        if (defs.isEmpty()) {
            result.error = 'Workflow definition not found: ' + req.workflowDefinitionId;
            return result;
        }
        Workflow_Definition__c wd = defs[0];

        if (String.isBlank(wd.Definition_JSON__c)) {
            result.error = 'Workflow definition has no Definition_JSON__c';
            return result;
        }

        // Parse + validate contract
        WorkflowContract.Workflow wf;
        try {
            wf = WorkflowContract.parse(wd.Definition_JSON__c);
        } catch (WorkflowContract.ContractParseException e) {
            result.error = 'Invalid workflow contract: ' + e.getMessage();
            return result;
        }
        List<String> validationErrors = WorkflowContract.validate(wf);
        if (!validationErrors.isEmpty()) {
            result.error = 'Contract validation failed: ' + String.join(validationErrors, '; ');
            return result;
        }

        // 2. Build bundle payload with deterministic key ordering
        Map<String, Object> payload = new Map<String, Object>();
        payload.put('schema', 'pulse.bundle.v1');
        payload.put('bundleKey', req.bundleKey);
        payload.put('displayName', String.isNotBlank(req.displayName) ? req.displayName : wd.Name);
        payload.put('publisherId', req.publisherId);
        payload.put('version', req.version);

        List<Object> depsOut = new List<Object>();
        if (req.dependencies != null) {
            for (DependencySpec dep : req.dependencies) {
                Map<String, Object> depMap = new Map<String, Object>();
                depMap.put('bundleKey', dep.bundleKey);
                depMap.put('minVersion', dep.minVersion);
                depsOut.add(depMap);
            }
        }
        payload.put('dependencies', depsOut);
        payload.put('workflowDefinitionJson', wd.Definition_JSON__c);
        payload.put('publishedAt', Datetime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss.SSS\'Z\''));
        payload.put('publishedBy', UserInfo.getUserId());
        payload.put('publishedByName', UserInfo.getName());

        // 3. Serialize
        String bundleJson = JSON.serialize(payload);

        // 4. Sign
        try {
            Blob payloadBytes = Blob.valueOf(bundleJson);
            String keyBody = PulseCrypto.stripPemHeaders(req.privateKeyPem);
            Blob privateKeyBlob = EncodingUtil.base64Decode(keyBody);
            Blob sig = Crypto.sign('RSA-SHA256', payloadBytes, privateKeyBlob);
            result.signatureB64 = EncodingUtil.base64Encode(sig);
        } catch (Exception e) {
            result.error = 'Signing failed: ' + e.getMessage();
            return result;
        }

        // 5. Compute fingerprint
        if (String.isNotBlank(req.publicKeyPem)) {
            result.publicKeyFingerprint = PulseCrypto.sha256Fingerprint(
                PulseCrypto.stripPemHeaders(req.publicKeyPem)
            );
        } else {
            result.publicKeyFingerprint = PulseCrypto.sha256Fingerprint(result.signatureB64);
        }

        result.bundleJson = bundleJson;
        result.success = true;
        return result;
    }
}
