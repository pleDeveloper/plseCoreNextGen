/**
 * Installer service for Pulse Library bundles.
 *
 * Validates trust, verifies signature, checks dependencies, creates a
 * Workflow_Definition__c, records the install in Pulse_Library_Bundle__c,
 * and supports single-step rollback to the previous version.
 */
global with sharing class PulseLibraryInstaller {

    // ── Testability seam (same pattern as ProjectionWriteService) ────

    @TestVisible
    private static List<Trusted_Publisher__mdt> trustedPublisherOverride;

    // ── DTOs ─────────────────────────────────────────────────────────

    global class InstallResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public Id      bundleRecordId;
        @AuraEnabled public Id      workflowDefinitionId;
        @AuraEnabled public String  message;
        @AuraEnabled public List<String> validationErrors;
    }

    global class BundleView {
        @AuraEnabled public Id       bundleId;
        @AuraEnabled public String   bundleKey;
        @AuraEnabled public String   displayName;
        @AuraEnabled public String   version;
        @AuraEnabled public String   publisherId;
        @AuraEnabled public String   status;
        @AuraEnabled public Datetime installedDate;
        @AuraEnabled public String   installedByName;
        @AuraEnabled public Id       workflowDefinitionId;
        @AuraEnabled public Id       previousBundleId;
    }

    // ── Install ──────────────────────────────────────────────────────

    @AuraEnabled
    global static InstallResult installBundle(
        String bundleJson,
        String signatureB64
    ) {
        InstallResult result = new InstallResult();
        result.success = false;
        result.validationErrors = new List<String>();

        // 1. Parse bundle JSON
        Map<String, Object> bundle;
        try {
            bundle = (Map<String, Object>) JSON.deserializeUntyped(bundleJson);
        } catch (Exception e) {
            result.message = 'Invalid bundle JSON: ' + e.getMessage();
            return result;
        }

        String schemaVer   = (String) bundle.get('schema');
        String bundleKey   = (String) bundle.get('bundleKey');
        String version     = (String) bundle.get('version');
        String publisherId = (String) bundle.get('publisherId');
        String displayName = (String) bundle.get('displayName');
        String wfJson      = (String) bundle.get('workflowDefinitionJson');

        // 2. Validate schema version
        if (schemaVer != 'pulse.bundle.v1') {
            result.message = 'Unsupported bundle schema: ' + schemaVer;
            return result;
        }

        // 3. Verify publisher trust
        Trusted_Publisher__mdt pub = lookupPublisher(publisherId);
        if (pub == null) {
            result.message = 'Publisher not trusted: ' + publisherId;
            return result;
        }
        if (pub.Active__c != true) {
            result.message = 'Publisher not trusted: ' + publisherId;
            return result;
        }

        // 4. Verify signature
        try {
            Blob payloadBytes   = Blob.valueOf(bundleJson);
            Blob signatureBytes = EncodingUtil.base64Decode(signatureB64);
            String pubKeyBody   = PulseCrypto.stripPemHeaders(pub.Public_Key_PEM__c);
            Blob pubKeyBlob     = EncodingUtil.base64Decode(pubKeyBody);
            Boolean verified    = Crypto.verify(
                'RSA-SHA256', payloadBytes, signatureBytes, pubKeyBlob
            );
            if (!verified) {
                result.message = 'Bundle signature verification failed';
                return result;
            }
        } catch (Exception e) {
            result.message = 'Signature verification error: ' + e.getMessage();
            return result;
        }

        // 5. Validate dependencies
        Object depsObj = bundle.get('dependencies');
        if (depsObj instanceof List<Object>) {
            List<String> unsatisfied = checkDependencies((List<Object>) depsObj);
            if (!unsatisfied.isEmpty()) {
                result.message = 'Unsatisfied dependencies';
                result.validationErrors = unsatisfied;
                return result;
            }
        }

        // 6. Validate contained workflow contract
        if (String.isBlank(wfJson)) {
            result.message = 'Bundle contains no workflowDefinitionJson';
            return result;
        }
        WorkflowContract.Workflow wf;
        try {
            wf = WorkflowContract.parse(wfJson);
        } catch (WorkflowContract.ContractParseException e) {
            result.message = 'Invalid workflow contract in bundle: ' + e.getMessage();
            return result;
        }
        List<String> contractErrors = WorkflowContract.validate(wf);
        if (!contractErrors.isEmpty()) {
            result.message = 'Workflow contract validation failed';
            result.validationErrors = contractErrors;
            return result;
        }

        // 7. Create Workflow_Definition__c
        String defName = wf.workflowKey;
        String defKey  = wf.workflowKey;
        // Check for key collision — append bundle key suffix
        List<Workflow_Definition__c> existing = [
            SELECT Id FROM Workflow_Definition__c
            WHERE  Workflow_Key__c = :defKey
            LIMIT  1
        ];
        if (!existing.isEmpty()) {
            defKey  = defKey + '-' + bundleKey;
            defName = defName + '-' + bundleKey;
        }

        Workflow_Definition__c newDef = new Workflow_Definition__c(
            Name               = defName,
            Workflow_Key__c    = defKey,
            Version__c         = wf.version,
            Status__c          = 'Draft',
            Definition_JSON__c = wfJson,
            Subject_Kinds__c   = wf.subjectKinds != null
                ? String.join(wf.subjectKinds, ';')
                : null
        );
        insert newDef;

        // 8. Find previous installed bundle with same key
        String fingerprint = PulseCrypto.sha256Fingerprint(
            PulseCrypto.stripPemHeaders(pub.Public_Key_PEM__c)
        );

        List<Pulse_Library_Bundle__c> previousBundles = [
            SELECT Id
            FROM   Pulse_Library_Bundle__c
            WHERE  Bundle_Key__c = :bundleKey
            AND    Status__c = 'Installed'
            ORDER BY Installed_Date__c DESC
            LIMIT  1
        ];

        Id previousBundleId = null;
        if (!previousBundles.isEmpty()) {
            previousBundleId = previousBundles[0].Id;
            previousBundles[0].Status__c = 'Superseded';
            update previousBundles[0];
        }

        // Serialize dependencies for storage
        String depsJson = '[]';
        if (depsObj instanceof List<Object>) {
            depsJson = JSON.serialize(depsObj);
        }

        Pulse_Library_Bundle__c bundleRec = new Pulse_Library_Bundle__c(
            Name                     = displayName != null ? displayName : bundleKey,
            Bundle_Key__c            = bundleKey,
            Display_Name__c          = displayName,
            Publisher_Id__c          = publisherId,
            Version__c               = version,
            Status__c                = 'Installed',
            Bundle_JSON__c           = bundleJson,
            Signature_B64__c         = signatureB64,
            Public_Key_Fingerprint__c = fingerprint,
            Installed_Date__c        = Datetime.now(),
            Installed_By__c          = UserInfo.getUserId(),
            Workflow_Definition__c   = newDef.Id,
            Previous_Bundle__c       = previousBundleId,
            Dependencies_JSON__c     = depsJson
        );
        insert bundleRec;

        // 9. Return success
        result.success              = true;
        result.bundleRecordId       = bundleRec.Id;
        result.workflowDefinitionId = newDef.Id;
        result.message              = 'Bundle installed successfully';
        return result;
    }

    // ── Rollback ─────────────────────────────────────────────────────

    @AuraEnabled
    global static InstallResult rollback(Id bundleRecordId) {
        InstallResult result = new InstallResult();
        result.success = false;
        result.validationErrors = new List<String>();

        // 1. Load the bundle
        List<Pulse_Library_Bundle__c> bundles = [
            SELECT Id, Status__c, Previous_Bundle__c,
                   Workflow_Definition__c, Bundle_Key__c, Bundle_JSON__c
            FROM   Pulse_Library_Bundle__c
            WHERE  Id = :bundleRecordId
            LIMIT  1
        ];
        if (bundles.isEmpty()) {
            result.message = 'Bundle record not found';
            return result;
        }
        Pulse_Library_Bundle__c current = bundles[0];

        if (current.Status__c != 'Installed') {
            result.message = 'Only bundles with status Installed can be rolled back';
            return result;
        }

        // 2. Must have a previous bundle
        if (current.Previous_Bundle__c == null) {
            result.message = 'No previous version to roll back to.';
            return result;
        }

        // Load previous bundle
        Pulse_Library_Bundle__c previous = [
            SELECT Id, Status__c, Workflow_Definition__c, Bundle_JSON__c
            FROM   Pulse_Library_Bundle__c
            WHERE  Id = :current.Previous_Bundle__c
            LIMIT  1
        ];

        // 3. Pre-check: validate that every active instance's Current_State__c
        //    is present in the previous bundle's contract states
        if (previous.Bundle_JSON__c != null) {
            Map<String, Object> prevPayload =
                (Map<String, Object>) JSON.deserializeUntyped(previous.Bundle_JSON__c);
            String prevWfJson = (String) prevPayload.get('workflowDefinitionJson');
            if (String.isNotBlank(prevWfJson)) {
                WorkflowContract.Workflow prevWf = WorkflowContract.parse(prevWfJson);
                Set<String> prevStateKeys = new Set<String>();
                if (prevWf.states != null) {
                    for (WorkflowContract.State s : prevWf.states) {
                        prevStateKeys.add(s.key);
                    }
                }

                // Find active instances pointing at the current bundle's definition
                List<Workflow_Instance__c> activeInstances = [
                    SELECT Id, Current_State__c
                    FROM   Workflow_Instance__c
                    WHERE  Workflow_Definition__c = :current.Workflow_Definition__c
                    AND    Status__c = 'Active'
                ];

                List<String> blocking = new List<String>();
                for (Workflow_Instance__c inst : activeInstances) {
                    if (String.isNotBlank(inst.Current_State__c)
                            && !prevStateKeys.contains(inst.Current_State__c)) {
                        blocking.add(inst.Id + ' (state: ' + inst.Current_State__c + ')');
                    }
                }
                if (!blocking.isEmpty()) {
                    result.message = 'Rollback blocked: active instances are in states '
                        + 'not present in the target version';
                    result.validationErrors = blocking;
                    return result;
                }

                // Re-point active instances to the previous definition
                if (!activeInstances.isEmpty()) {
                    for (Workflow_Instance__c inst : activeInstances) {
                        inst.Workflow_Definition__c = previous.Workflow_Definition__c;
                    }
                    update activeInstances;
                }
            }
        }

        // 4. Mark current as Rolled_Back
        current.Status__c = 'Rolled_Back';
        update current;

        // 5. Re-activate previous
        previous.Status__c = 'Installed';
        update previous;

        result.success        = true;
        result.bundleRecordId = previous.Id;
        result.workflowDefinitionId = previous.Workflow_Definition__c;
        result.message        = 'Rolled back successfully';
        return result;
    }

    // ── List ─────────────────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    global static List<BundleView> listInstalledBundles() {
        List<BundleView> views = new List<BundleView>();
        for (Pulse_Library_Bundle__c b : [
            SELECT Id, Bundle_Key__c, Display_Name__c, Version__c,
                   Publisher_Id__c, Status__c, Installed_Date__c,
                   Installed_By__r.Name, Workflow_Definition__c,
                   Previous_Bundle__c
            FROM   Pulse_Library_Bundle__c
            WHERE  Status__c IN ('Installed', 'Superseded', 'Rolled_Back')
            ORDER BY Installed_Date__c DESC
        ]) {
            BundleView v    = new BundleView();
            v.bundleId      = b.Id;
            v.bundleKey     = b.Bundle_Key__c;
            v.displayName   = b.Display_Name__c;
            v.version       = b.Version__c;
            v.publisherId   = b.Publisher_Id__c;
            v.status        = b.Status__c;
            v.installedDate = b.Installed_Date__c;
            v.installedByName = b.Installed_By__r.Name;
            v.workflowDefinitionId = b.Workflow_Definition__c;
            v.previousBundleId     = b.Previous_Bundle__c;
            views.add(v);
        }
        return views;
    }

    // ── Private helpers ──────────────────────────────────────────────

    private static Trusted_Publisher__mdt lookupPublisher(String publisherId) {
        if (trustedPublisherOverride != null) {
            for (Trusted_Publisher__mdt p : trustedPublisherOverride) {
                if (p.DeveloperName == publisherId) {
                    return p;
                }
            }
            return null;
        }
        List<Trusted_Publisher__mdt> pubs = [
            SELECT DeveloperName, Display_Name__c, Public_Key_PEM__c, Active__c
            FROM   Trusted_Publisher__mdt
            WHERE  DeveloperName = :publisherId
            LIMIT  1
        ];
        return pubs.isEmpty() ? null : pubs[0];
    }

    @TestVisible
    private static List<String> checkDependencies(List<Object> deps) {
        List<String> unsatisfied = new List<String>();
        for (Object depObj : deps) {
            Map<String, Object> dep = (Map<String, Object>) depObj;
            String depKey    = (String) dep.get('bundleKey');
            String minVer    = (String) dep.get('minVersion');

            List<Pulse_Library_Bundle__c> installed = [
                SELECT Version__c
                FROM   Pulse_Library_Bundle__c
                WHERE  Bundle_Key__c = :depKey
                AND    Status__c = 'Installed'
                ORDER BY Installed_Date__c DESC
                LIMIT  1
            ];
            if (installed.isEmpty()) {
                unsatisfied.add('Missing dependency: ' + depKey + ' >= ' + minVer);
            } else if (!semverGte(installed[0].Version__c, minVer)) {
                unsatisfied.add('Dependency version too low: ' + depKey
                    + ' installed=' + installed[0].Version__c
                    + ' required>=' + minVer);
            }
        }
        return unsatisfied;
    }

    /**
     * Minimal semver comparator: returns true if a >= b.
     * Handles three-component numeric versions (e.g., 1.2.3).
     */
    @TestVisible
    private static Boolean semverGte(String a, String b) {
        if (String.isBlank(a) || String.isBlank(b)) {
            return false;
        }
        List<String> aParts = a.split('\\.');
        List<String> bParts = b.split('\\.');
        for (Integer i = 0; i < 3; i++) {
            Integer aNum = i < aParts.size() ? Integer.valueOf(aParts[i]) : 0;
            Integer bNum = i < bParts.size() ? Integer.valueOf(bParts[i]) : 0;
            if (aNum > bNum) {
                return true;
            }
            if (aNum < bNum) {
                return false;
            }
        }
        return true; // equal
    }
}
