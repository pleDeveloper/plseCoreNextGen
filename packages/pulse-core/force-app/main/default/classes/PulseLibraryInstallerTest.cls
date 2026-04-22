@IsTest
private class PulseLibraryInstallerTest {

    // Same test RSA-2048 key pair as PulseLibraryPublisherTest.
    private static final String TEST_PRIVATE_KEY_PEM =
        '-----BEGIN PRIVATE KEY-----\n'
        + 'MIIEvwIBADANBgkqhkiG9w0BAQEFAASCBKkwggSlAgEAAoIBAQC6RhJ3ihe2SFty\n'
        + '7Hgeg+8+amF5B234F0FnZzS2G23SEZpNl7IrrSo/ApFaKcbRs40lPCXgKy5oFLcz\n'
        + '3LxF+V7fmx5hn8L5awxrt9YQHLHQpeRosphOZDAx6Tq3m4LoaHv/Cj0ql2ukWuGs\n'
        + 'LKIDARfqR4CDWrb9u0pM8WZ8uwEor5nLSOE63ABZvwyjWLZj5RUnwKb2Ba5/Ldo2\n'
        + 'J1t6O160sYSxJhSh9I3JB5SQ1FXta9TJ73ejqXyIM/3XdsmFovW8a1jjLHnKLp5K\n'
        + 'EktQWuGBMl08qlI+iHy8jBtTVg94gV+Zk3Qf+AMliYH/yRbK0RIjHF1HaVKlEzkY\n'
        + 'pIm5RVYdAgMBAAECggEBAKqZ+Nng8Pyy4oasCwuvvFOG7QUDB/XbnrxMqttK3dcy\n'
        + '5gbAs58K9xFEkclpT73J27DJmMrp4ZPTvULTnN/dl8Xl9PpmbxUutO6HLZgOH9E/\n'
        + 'zqURRSsu2XEs8ektlcSzxTT9tK2ohx69WcjuC+gCfVvF5u7nC4fxnAhCY6JDR7lx\n'
        + 'IrzWYH0ch0YMwEVNGjEsTLJG2dazirTilu2iAdGLNVQu0UjMyw7XzrR0CKwgA1GH\n'
        + 'mjO/HjiM6IpzBhE2UWl+pV/8NepltFzhhVd1tMxTuJOGW8n0JxBair+YknHWKWQu\n'
        + 'IO5PXCfubZToeX2bDu4y3XhN3089SrfxuVfceSsxK8UCgYEA3KVCIXDIN/fbycfU\n'
        + 'xR4L+gAMcMQhg3XRas+wLJsW+rqt4CAH34Qh0tz6fUdk8ixNMeTzphI9SxHQcztr\n'
        + '6vMKj5LceXR/RM+o0yEoLLX0rIvAF+CcMwLNiC8GwOXwf1bBras5wBRhTvl2zqSS\n'
        + 'PYDgxgPh45tsvJSfU7M+6TJBWMcCgYEA2B7nPNv9hrLLl9efxQsVFfU0Id6hyREk\n'
        + 'vBFI3Oh+yL6uyKV6mxHCCewRvlsi5yheLqHqKEKwiSMexi2grz14I5DAlzbXJWIW\n'
        + 'LUBZxdBExhEgb7oiK/38s0e6ACf8KiHT31fezNdGjIKcPNbZ1a30W+xXQvoBG3gc\n'
        + 'yBWT48V1XfsCgYBFl/5ey9LrDEuPvm7W6Z4/cUp7OvGTJFM0TGO1/gjmdoEnQxMY\n'
        + 'pfWBK9/6Kc2mMOD8Tsmm5PPePLUx01k7lwMKu/i8ekk2LAWE6l1glNeioMWrAlZi\n'
        + 'JI0tWh/YMe6ES5n1LB+f/Q2gOkEF9pSFv6Ol8U2LW9eVN491eADszsQbuwKBgQCa\n'
        + 'KekvK4n8tLuwE7q/VvlykVfftSzY/aajlPzRv/L4hbSuIgSEazVr2H6Lt/z8wXn1\n'
        + 'b8BVecTt/iRsn42Yk5OIYzBObWspGn/RRa8EAV2doAfwSuknUmUZCdgvVlZ1Q24c\n'
        + 'SlT+760+e8ixSV1YJF9D1yIj/6wciSCWxXWaK3deUwKBgQCTMjCHImt7W61KwP3p\n'
        + '48T69DU+P9Wx+H0ITYkpT8QCsSl6ZNrd2NCzWJklyqgjbRyfe55HMvLsD57YGoqO\n'
        + 'eDhK4BmiizmbyCOreNsuS5Bqs7N0T9vCRNm2kKfYYctz8a6r8VmNMowTm9Dmha8N\n'
        + 'Jf3dEhPTSZAjGfvR2iZbLg2SvA==\n'
        + '-----END PRIVATE KEY-----';

    private static final String TEST_PUBLIC_KEY_PEM =
        '-----BEGIN PUBLIC KEY-----\n'
        + 'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAukYSd4oXtkhbcux4HoPv\n'
        + 'PmpheQdt+BdBZ2c0thtt0hGaTZeyK60qPwKRWinG0bONJTwl4CsuaBS3M9y8Rfle\n'
        + '35seYZ/C+WsMa7fWEByx0KXkaLKYTmQwMek6t5uC6Gh7/wo9KpdrpFrhrCyiAwEX\n'
        + '6keAg1q2/btKTPFmfLsBKK+Zy0jhOtwAWb8Mo1i2Y+UVJ8Cm9gWufy3aNidbejte\n'
        + 'tLGEsSYUofSNyQeUkNRV7WvUye93o6l8iDP913bJhaL1vGtY4yx5yi6eShJLUFrh\n'
        + 'gTJdPKpSPoh8vIwbU1YPeIFfmZN0H/gDJYmB/8kWytESIxxdR2lSpRM5GKSJuUVW\n'
        + 'HQIDAQAB\n'
        + '-----END PUBLIC KEY-----';

    private static final String VALID_DEFINITION_JSON =
        '{"schema":"pulse.workflow.v1","workflowKey":"test-wf","version":1,'
        + '"subjectKinds":["Case"],"states":[{"key":"open","label":"Open","type":"task",'
        + '"transitions":[{"signal":"close","to":"closed"}]},'
        + '{"key":"closed","label":"Closed","type":"terminal"}]}';

    // V2 definition has an extra 'review' state
    private static final String V2_DEFINITION_JSON =
        '{"schema":"pulse.workflow.v1","workflowKey":"test-wf","version":2,'
        + '"subjectKinds":["Case"],"states":[{"key":"open","label":"Open","type":"task",'
        + '"transitions":[{"signal":"review","to":"review"}]},'
        + '{"key":"review","label":"Review","type":"task",'
        + '"transitions":[{"signal":"close","to":"closed"}]},'
        + '{"key":"closed","label":"Closed","type":"terminal"}]}';

    // ── Helpers ────────────────────────────────────────────────────

    private static void stubTrustedPublisher() {
        Trusted_Publisher__mdt pub = new Trusted_Publisher__mdt(
            DeveloperName  = 'test_publisher',
            Display_Name__c = 'Test Publisher',
            Public_Key_PEM__c = TEST_PUBLIC_KEY_PEM,
            Active__c      = true
        );
        PulseLibraryInstaller.trustedPublisherOverride =
            new List<Trusted_Publisher__mdt>{ pub };
    }

    private static void stubInactivePublisher() {
        Trusted_Publisher__mdt pub = new Trusted_Publisher__mdt(
            DeveloperName  = 'test_publisher',
            Display_Name__c = 'Test Publisher',
            Public_Key_PEM__c = TEST_PUBLIC_KEY_PEM,
            Active__c      = false
        );
        PulseLibraryInstaller.trustedPublisherOverride =
            new List<Trusted_Publisher__mdt>{ pub };
    }

    private static PulseLibraryPublisher.PublishResult signBundle(
        String definitionJson, String bundleKey, String version
    ) {
        Workflow_Definition__c wd = new Workflow_Definition__c(
            Name               = 'Test',
            Workflow_Key__c    = bundleKey + '-def-' + Crypto.getRandomInteger(),
            Version__c         = 1,
            Status__c          = 'Draft',
            Definition_JSON__c = definitionJson,
            Subject_Kinds__c   = 'Case'
        );
        insert wd;

        PulseLibraryPublisher.PublishRequest req =
            new PulseLibraryPublisher.PublishRequest();
        req.workflowDefinitionId = wd.Id;
        req.bundleKey            = bundleKey;
        req.displayName          = 'Test Bundle';
        req.publisherId          = 'test_publisher';
        req.version              = version;
        req.privateKeyPem        = TEST_PRIVATE_KEY_PEM;
        req.publicKeyPem         = TEST_PUBLIC_KEY_PEM;
        return PulseLibraryPublisher.publish(req);
    }

    // ── Tests ─────────────────────────────────────────────────────

    @IsTest
    static void installBundle_trustedPublisher_succeeds() {
        stubTrustedPublisher();
        PulseLibraryPublisher.PublishResult pub =
            signBundle(VALID_DEFINITION_JSON, 'intake-v1', '1.0.0');
        System.assertEquals(true, pub.success, 'Signing should succeed');

        Test.startTest();
        PulseLibraryInstaller.InstallResult res =
            PulseLibraryInstaller.installBundle(pub.bundleJson, pub.signatureB64);
        Test.stopTest();

        System.assertEquals(true, res.success, res.message);
        System.assertNotEquals(null, res.bundleRecordId);
        System.assertNotEquals(null, res.workflowDefinitionId);

        // Verify bundle record
        Pulse_Library_Bundle__c rec = [
            SELECT Bundle_Key__c, Version__c, Status__c, Publisher_Id__c
            FROM   Pulse_Library_Bundle__c
            WHERE  Id = :res.bundleRecordId
        ];
        System.assertEquals('intake-v1', rec.Bundle_Key__c);
        System.assertEquals('1.0.0', rec.Version__c);
        System.assertEquals('Installed', rec.Status__c);

        // Verify workflow definition was created
        Workflow_Definition__c wd = [
            SELECT Definition_JSON__c FROM Workflow_Definition__c
            WHERE  Id = :res.workflowDefinitionId
        ];
        System.assertNotEquals(null, wd.Definition_JSON__c);
    }

    @IsTest
    static void installBundle_untrustedPublisher_rejects() {
        // No CMDT row
        PulseLibraryInstaller.trustedPublisherOverride =
            new List<Trusted_Publisher__mdt>();

        PulseLibraryPublisher.PublishResult pub =
            signBundle(VALID_DEFINITION_JSON, 'untrusted', '1.0.0');

        Test.startTest();
        PulseLibraryInstaller.InstallResult res =
            PulseLibraryInstaller.installBundle(pub.bundleJson, pub.signatureB64);
        Test.stopTest();

        System.assertEquals(false, res.success);
        System.assert(res.message.contains('Publisher not trusted'));
    }

    @IsTest
    static void installBundle_inactivePublisher_rejects() {
        stubInactivePublisher();

        PulseLibraryPublisher.PublishResult pub =
            signBundle(VALID_DEFINITION_JSON, 'inactive', '1.0.0');

        Test.startTest();
        PulseLibraryInstaller.InstallResult res =
            PulseLibraryInstaller.installBundle(pub.bundleJson, pub.signatureB64);
        Test.stopTest();

        System.assertEquals(false, res.success);
        System.assert(res.message.contains('Publisher not trusted'));
    }

    @IsTest
    static void installBundle_badSignature_rejects() {
        stubTrustedPublisher();
        PulseLibraryPublisher.PublishResult pub =
            signBundle(VALID_DEFINITION_JSON, 'tampered', '1.0.0');

        // Tamper with the bundle payload after signing
        String tampered = pub.bundleJson.replace('"1.0.0"', '"9.9.9"');

        Test.startTest();
        PulseLibraryInstaller.InstallResult res =
            PulseLibraryInstaller.installBundle(tampered, pub.signatureB64);
        Test.stopTest();

        System.assertEquals(false, res.success);
        System.assert(
            res.message.contains('signature verification failed'),
            'Should reject tampered payload: ' + res.message
        );
    }

    @IsTest
    static void installBundle_missingDependency_rejects() {
        stubTrustedPublisher();

        // Create a bundle that declares a dependency on a non-existent bundle
        Workflow_Definition__c wd = new Workflow_Definition__c(
            Name               = 'Dep Test',
            Workflow_Key__c    = 'dep-test-' + Crypto.getRandomInteger(),
            Version__c         = 1,
            Status__c          = 'Draft',
            Definition_JSON__c = VALID_DEFINITION_JSON,
            Subject_Kinds__c   = 'Case'
        );
        insert wd;

        PulseLibraryPublisher.PublishRequest req =
            new PulseLibraryPublisher.PublishRequest();
        req.workflowDefinitionId = wd.Id;
        req.bundleKey            = 'needs-dep';
        req.displayName          = 'Dep Bundle';
        req.publisherId          = 'test_publisher';
        req.version              = '1.0.0';
        req.privateKeyPem        = TEST_PRIVATE_KEY_PEM;
        req.publicKeyPem         = TEST_PUBLIC_KEY_PEM;

        PulseLibraryPublisher.DependencySpec dep =
            new PulseLibraryPublisher.DependencySpec();
        dep.bundleKey  = 'nonexistent-base';
        dep.minVersion = '1.0.0';
        req.dependencies = new List<PulseLibraryPublisher.DependencySpec>{ dep };

        PulseLibraryPublisher.PublishResult pub =
            PulseLibraryPublisher.publish(req);
        System.assertEquals(true, pub.success);

        Test.startTest();
        PulseLibraryInstaller.InstallResult res =
            PulseLibraryInstaller.installBundle(pub.bundleJson, pub.signatureB64);
        Test.stopTest();

        System.assertEquals(false, res.success);
        System.assert(res.message.contains('Unsatisfied dependencies'));
        System.assertEquals(1, res.validationErrors.size());
    }

    @IsTest
    static void installBundle_supersedesPrevious() {
        stubTrustedPublisher();

        // Install v1
        PulseLibraryPublisher.PublishResult pubV1 =
            signBundle(VALID_DEFINITION_JSON, 'versioned', '1.0.0');
        PulseLibraryInstaller.InstallResult resV1 =
            PulseLibraryInstaller.installBundle(pubV1.bundleJson, pubV1.signatureB64);
        System.assertEquals(true, resV1.success, resV1.message);

        // Install v2
        PulseLibraryPublisher.PublishResult pubV2 =
            signBundle(VALID_DEFINITION_JSON, 'versioned', '2.0.0');

        Test.startTest();
        PulseLibraryInstaller.InstallResult resV2 =
            PulseLibraryInstaller.installBundle(pubV2.bundleJson, pubV2.signatureB64);
        Test.stopTest();

        System.assertEquals(true, resV2.success, resV2.message);

        // v1 should be Superseded
        Pulse_Library_Bundle__c v1Rec = [
            SELECT Status__c FROM Pulse_Library_Bundle__c
            WHERE  Id = :resV1.bundleRecordId
        ];
        System.assertEquals('Superseded', v1Rec.Status__c);

        // v2 should link to v1
        Pulse_Library_Bundle__c v2Rec = [
            SELECT Status__c, Previous_Bundle__c FROM Pulse_Library_Bundle__c
            WHERE  Id = :resV2.bundleRecordId
        ];
        System.assertEquals('Installed', v2Rec.Status__c);
        System.assertEquals(resV1.bundleRecordId, v2Rec.Previous_Bundle__c);
    }

    @IsTest
    static void rollback_supersededBundle_reactivates() {
        stubTrustedPublisher();

        // Install v1 then v2
        PulseLibraryPublisher.PublishResult pubV1 =
            signBundle(VALID_DEFINITION_JSON, 'rb-test', '1.0.0');
        PulseLibraryInstaller.InstallResult resV1 =
            PulseLibraryInstaller.installBundle(pubV1.bundleJson, pubV1.signatureB64);

        PulseLibraryPublisher.PublishResult pubV2 =
            signBundle(VALID_DEFINITION_JSON, 'rb-test', '2.0.0');
        PulseLibraryInstaller.InstallResult resV2 =
            PulseLibraryInstaller.installBundle(pubV2.bundleJson, pubV2.signatureB64);

        Test.startTest();
        PulseLibraryInstaller.InstallResult rbRes =
            PulseLibraryInstaller.rollback(resV2.bundleRecordId);
        Test.stopTest();

        System.assertEquals(true, rbRes.success, rbRes.message);

        // v2 → Rolled_Back
        Pulse_Library_Bundle__c v2 = [
            SELECT Status__c FROM Pulse_Library_Bundle__c
            WHERE  Id = :resV2.bundleRecordId
        ];
        System.assertEquals('Rolled_Back', v2.Status__c);

        // v1 → re-Installed
        Pulse_Library_Bundle__c v1 = [
            SELECT Status__c FROM Pulse_Library_Bundle__c
            WHERE  Id = :resV1.bundleRecordId
        ];
        System.assertEquals('Installed', v1.Status__c);
    }

    @IsTest
    static void rollback_noPrevious_rejects() {
        stubTrustedPublisher();

        PulseLibraryPublisher.PublishResult pub =
            signBundle(VALID_DEFINITION_JSON, 'no-prev', '1.0.0');
        PulseLibraryInstaller.InstallResult res =
            PulseLibraryInstaller.installBundle(pub.bundleJson, pub.signatureB64);

        Test.startTest();
        PulseLibraryInstaller.InstallResult rbRes =
            PulseLibraryInstaller.rollback(res.bundleRecordId);
        Test.stopTest();

        System.assertEquals(false, rbRes.success);
        System.assert(rbRes.message.contains('No previous version'));
    }

    @IsTest
    static void rollback_instanceStateMissing_rejects() {
        stubTrustedPublisher();

        // Install v1 (has open + closed states)
        PulseLibraryPublisher.PublishResult pubV1 =
            signBundle(VALID_DEFINITION_JSON, 'state-check', '1.0.0');
        PulseLibraryInstaller.InstallResult resV1 =
            PulseLibraryInstaller.installBundle(pubV1.bundleJson, pubV1.signatureB64);

        // Install v2 (has open + review + closed states)
        PulseLibraryPublisher.PublishResult pubV2 =
            signBundle(V2_DEFINITION_JSON, 'state-check', '2.0.0');
        PulseLibraryInstaller.InstallResult resV2 =
            PulseLibraryInstaller.installBundle(pubV2.bundleJson, pubV2.signatureB64);

        // Create an active instance at state 'review' under v2's definition
        Workflow_Instance__c inst = new Workflow_Instance__c(
            Workflow_Definition__c = resV2.workflowDefinitionId,
            Current_State__c       = 'review',
            Status__c              = 'Active'
        );
        insert inst;

        Test.startTest();
        PulseLibraryInstaller.InstallResult rbRes =
            PulseLibraryInstaller.rollback(resV2.bundleRecordId);
        Test.stopTest();

        // 'review' doesn't exist in v1 contract → rollback should be blocked
        System.assertEquals(false, rbRes.success);
        System.assert(
            rbRes.message.contains('Rollback blocked'),
            'Should block rollback: ' + rbRes.message
        );
        System.assertEquals(1, rbRes.validationErrors.size());
    }

    @IsTest
    static void listInstalledBundles_returnsViews() {
        stubTrustedPublisher();

        PulseLibraryPublisher.PublishResult pub =
            signBundle(VALID_DEFINITION_JSON, 'list-test', '1.0.0');
        PulseLibraryInstaller.installBundle(pub.bundleJson, pub.signatureB64);

        Test.startTest();
        List<PulseLibraryInstaller.BundleView> views =
            PulseLibraryInstaller.listInstalledBundles();
        Test.stopTest();

        System.assert(!views.isEmpty(), 'Should return at least one bundle');
        PulseLibraryInstaller.BundleView v = views[0];
        System.assertNotEquals(null, v.bundleId);
        System.assertNotEquals(null, v.bundleKey);
    }

    @IsTest
    static void semverGte_comparisons() {
        System.assertEquals(true, PulseLibraryInstaller.semverGte('1.2.3', '1.2.3'));
        System.assertEquals(true, PulseLibraryInstaller.semverGte('2.0.0', '1.9.9'));
        System.assertEquals(false, PulseLibraryInstaller.semverGte('1.0.0', '1.0.1'));
        System.assertEquals(true, PulseLibraryInstaller.semverGte('1.1.0', '1.0.9'));
        System.assertEquals(false, PulseLibraryInstaller.semverGte('0.9.0', '1.0.0'));
    }
}
