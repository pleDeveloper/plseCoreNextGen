@IsTest
private class PulseLibraryPublisherTest {

    // Test RSA-2048 key pair — ephemeral, used only for unit tests.
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

    // ── Helpers ────────────────────────────────────────────────────

    private static Workflow_Definition__c createDefinition(String json) {
        Workflow_Definition__c wd = new Workflow_Definition__c(
            Name               = 'Test Workflow',
            Workflow_Key__c    = 'test-wf-pub-' + Crypto.getRandomInteger(),
            Version__c         = 1,
            Status__c          = 'Draft',
            Definition_JSON__c = json,
            Subject_Kinds__c   = 'Case'
        );
        insert wd;
        return wd;
    }

    private static PulseLibraryPublisher.PublishRequest buildRequest(
        Id defId, String privKey
    ) {
        PulseLibraryPublisher.PublishRequest req =
            new PulseLibraryPublisher.PublishRequest();
        req.workflowDefinitionId = defId;
        req.bundleKey            = 'test-bundle';
        req.displayName          = 'Test Bundle';
        req.publisherId          = 'test_publisher';
        req.version              = '1.0.0';
        req.privateKeyPem        = privKey;
        req.publicKeyPem         = TEST_PUBLIC_KEY_PEM;
        return req;
    }

    // ── Tests ─────────────────────────────────────────────────────

    @IsTest
    static void publish_validDefinition_returnsSignedBundle() {
        Workflow_Definition__c wd = createDefinition(VALID_DEFINITION_JSON);
        PulseLibraryPublisher.PublishRequest req =
            buildRequest(wd.Id, TEST_PRIVATE_KEY_PEM);

        Test.startTest();
        PulseLibraryPublisher.PublishResult res =
            PulseLibraryPublisher.publish(req);
        Test.stopTest();

        System.assertEquals(true, res.success, 'Publish should succeed');
        System.assertNotEquals(null, res.bundleJson, 'bundleJson should be set');
        System.assertNotEquals(null, res.signatureB64, 'signatureB64 should be set');
        System.assertNotEquals(null, res.publicKeyFingerprint, 'fingerprint should be set');

        // Verify the signature with the matching public key
        Blob payload = Blob.valueOf(res.bundleJson);
        Blob sig     = EncodingUtil.base64Decode(res.signatureB64);
        Blob pubKey  = EncodingUtil.base64Decode(
            PulseCrypto.stripPemHeaders(TEST_PUBLIC_KEY_PEM)
        );
        System.assertEquals(
            true,
            Crypto.verify('RSA-SHA256', payload, sig, pubKey),
            'Signature should verify with paired public key'
        );

        // Verify bundle payload structure
        Map<String, Object> bundle =
            (Map<String, Object>) JSON.deserializeUntyped(res.bundleJson);
        System.assertEquals('pulse.bundle.v1', bundle.get('schema'));
        System.assertEquals('test-bundle', bundle.get('bundleKey'));
        System.assertEquals('1.0.0', bundle.get('version'));
    }

    @IsTest
    static void publish_missingWorkflow_returnsError() {
        PulseLibraryPublisher.PublishRequest req =
            new PulseLibraryPublisher.PublishRequest();
        req.workflowDefinitionId = null;
        req.bundleKey            = 'test';
        req.version              = '1.0.0';
        req.privateKeyPem        = TEST_PRIVATE_KEY_PEM;

        Test.startTest();
        PulseLibraryPublisher.PublishResult res =
            PulseLibraryPublisher.publish(req);
        Test.stopTest();

        System.assertEquals(false, res.success);
        System.assert(res.error.contains('workflowDefinitionId is required'));
    }

    @IsTest
    static void publish_invalidContract_returnsError() {
        String badJson = '{"schema":"pulse.workflow.v1","workflowKey":"","version":0,'
            + '"subjectKinds":[],"states":[]}';
        Workflow_Definition__c wd = createDefinition(badJson);
        PulseLibraryPublisher.PublishRequest req =
            buildRequest(wd.Id, TEST_PRIVATE_KEY_PEM);

        Test.startTest();
        PulseLibraryPublisher.PublishResult res =
            PulseLibraryPublisher.publish(req);
        Test.stopTest();

        System.assertEquals(false, res.success);
        System.assert(res.error.contains('validation failed'));
    }

    @IsTest
    static void publish_withDependencies_includesThemInBundle() {
        Workflow_Definition__c wd = createDefinition(VALID_DEFINITION_JSON);
        PulseLibraryPublisher.PublishRequest req =
            buildRequest(wd.Id, TEST_PRIVATE_KEY_PEM);

        PulseLibraryPublisher.DependencySpec dep =
            new PulseLibraryPublisher.DependencySpec();
        dep.bundleKey  = 'base-forms';
        dep.minVersion = '2.0.0';
        req.dependencies = new List<PulseLibraryPublisher.DependencySpec>{ dep };

        Test.startTest();
        PulseLibraryPublisher.PublishResult res =
            PulseLibraryPublisher.publish(req);
        Test.stopTest();

        System.assertEquals(true, res.success);
        Map<String, Object> bundle =
            (Map<String, Object>) JSON.deserializeUntyped(res.bundleJson);
        List<Object> deps = (List<Object>) bundle.get('dependencies');
        System.assertEquals(1, deps.size());
        Map<String, Object> d = (Map<String, Object>) deps[0];
        System.assertEquals('base-forms', d.get('bundleKey'));
    }

    @IsTest
    static void publish_noDefinitionJson_returnsError() {
        Workflow_Definition__c wd = new Workflow_Definition__c(
            Name               = 'Empty',
            Workflow_Key__c    = 'empty-wf-' + Crypto.getRandomInteger(),
            Version__c         = 1,
            Status__c          = 'Draft',
            Definition_JSON__c = null,
            Subject_Kinds__c   = 'Case'
        );
        insert wd;

        PulseLibraryPublisher.PublishRequest req =
            buildRequest(wd.Id, TEST_PRIVATE_KEY_PEM);

        Test.startTest();
        PulseLibraryPublisher.PublishResult res =
            PulseLibraryPublisher.publish(req);
        Test.stopTest();

        System.assertEquals(false, res.success);
        System.assert(res.error.contains('no Definition_JSON__c'));
    }
}
