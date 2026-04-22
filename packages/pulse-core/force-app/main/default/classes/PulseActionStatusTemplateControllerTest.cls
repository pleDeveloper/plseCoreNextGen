@IsTest
private class PulseActionStatusTemplateControllerTest {

    // listTemplates — must not throw, and when seed templates exist returns
    // them with the basic fields populated.
    @IsTest
    static void listTemplatesReturnsSeeds() {
        Test.startTest();
        List<PulseActionStatusTemplateController.TemplateView> rows =
            PulseActionStatusTemplateController.listTemplates();
        Test.stopTest();

        System.assertNotEquals(null, rows, 'List must never be null');
        // Seed records include Basic_Approval, Email_Send, Task, Field_Capture.
        // In the dev org they're deployed; in scratch/CI they may not exist —
        // so we only assert that populated entries carry the fields we expect.
        for (PulseActionStatusTemplateController.TemplateView v : rows) {
            System.assertNotEquals(null, v.developerName);
            System.assertNotEquals(null, v.templateKey);
        }
    }

    // coerceTemplateInput — null input returns empty shell without throwing.
    @IsTest
    static void coerceAcceptsNull() {
        PulseActionStatusTemplateController.TemplateInput t =
            PulseActionStatusTemplateController.coerceTemplateInput(null);
        System.assertEquals(null, t.templateKey);
        System.assertEquals(null, t.displayName);
        System.assertEquals(null, t.description);
        System.assertEquals(null, t.statusesJson);
    }

    // coerceTemplateInput — string statusesJson is passed through.
    @IsTest
    static void coerceAcceptsStringStatusesJson() {
        PulseActionStatusTemplateController.TemplateInput t =
            PulseActionStatusTemplateController.coerceTemplateInput(
                new Map<String, Object>{
                    'templateKey'  => 'MyKey',
                    'displayName'  => 'My Key',
                    'description'  => 'd',
                    'statusesJson' => '[{"key":"Open","label":"Open"}]'
                }
            );
        System.assertEquals('MyKey', t.templateKey);
        System.assertEquals('My Key', t.displayName);
        System.assertEquals('d', t.description);
        System.assertEquals('[{"key":"Open","label":"Open"}]', t.statusesJson);
    }

    // coerceTemplateInput — non-string statusesJson (e.g. already-parsed
    // list) gets re-serialized into a JSON string.
    @IsTest
    static void coerceReserializesListStatusesJson() {
        List<Object> statuses = new List<Object>{
            new Map<String, Object>{ 'key' => 'Open', 'label' => 'Open' }
        };
        PulseActionStatusTemplateController.TemplateInput t =
            PulseActionStatusTemplateController.coerceTemplateInput(
                new Map<String, Object>{
                    'templateKey'  => 'K',
                    'statusesJson' => statuses
                }
            );
        System.assertNotEquals(null, t.statusesJson);
        System.assert(t.statusesJson.contains('"key"'));
        System.assert(t.statusesJson.contains('"Open"'));
    }

    // upsertTemplate — rejects blank templateKey.
    @IsTest
    static void upsertRejectsBlankTemplateKey() {
        Test.startTest();
        PulseActionStatusTemplateController.UpsertResult r =
            PulseActionStatusTemplateController.upsertTemplate(
                new Map<String, Object>{
                    'statusesJson' => '[{"key":"Open"}]'
                }
            );
        Test.stopTest();
        System.assertEquals(false, r.success);
        System.assert(r.message != null && r.message.contains('templateKey'));
    }

    // upsertTemplate — rejects blank statusesJson.
    @IsTest
    static void upsertRejectsBlankStatusesJson() {
        Test.startTest();
        PulseActionStatusTemplateController.UpsertResult r =
            PulseActionStatusTemplateController.upsertTemplate(
                new Map<String, Object>{
                    'templateKey' => 'MyKey'
                }
            );
        Test.stopTest();
        System.assertEquals(false, r.success);
        System.assert(r.message != null && r.message.contains('statusesJson'));
    }

    // upsertTemplate — rejects invalid statusesJson (not an array).
    @IsTest
    static void upsertRejectsInvalidJsonShape() {
        Test.startTest();
        PulseActionStatusTemplateController.UpsertResult r =
            PulseActionStatusTemplateController.upsertTemplate(
                new Map<String, Object>{
                    'templateKey'  => 'MyKey',
                    'statusesJson' => '{"notAnArray":true}'
                }
            );
        Test.stopTest();
        System.assertEquals(false, r.success);
        System.assert(r.message != null);
    }

    // upsertTemplate — rejects empty array.
    @IsTest
    static void upsertRejectsEmptyArray() {
        Test.startTest();
        PulseActionStatusTemplateController.UpsertResult r =
            PulseActionStatusTemplateController.upsertTemplate(
                new Map<String, Object>{
                    'templateKey'  => 'MyKey',
                    'statusesJson' => '[]'
                }
            );
        Test.stopTest();
        System.assertEquals(false, r.success);
    }

    // upsertTemplate — happy path validates the synchronous branch
    // (shape checks + custom-metadata build). Metadata.Operations.enqueueDeployment
    // is not supported inside @IsTest context — it throws AsyncException
    // "Metadata cannot be deployed from within a test". We exercise the
    // full code path and assert the AsyncException is caught and surfaced
    // as a friendly failure message rather than an uncaught throw.
    @IsTest
    static void upsertHappyPathCatchesAsyncException() {
        Test.startTest();
        PulseActionStatusTemplateController.UpsertResult r =
            PulseActionStatusTemplateController.upsertTemplate(
                new Map<String, Object>{
                    'templateKey'  => 'Test_Template',
                    'displayName'  => 'Test Template',
                    'description'  => 'Just a test',
                    'statusesJson' =>
                        '[{"key":"Open","label":"Open","order":0,"category":"open","isInitial":true},' +
                        '{"key":"Done","label":"Done","order":1,"category":"terminal_success"}]'
                }
            );
        Test.stopTest();
        // Assertion chain: reached the deploy line and caught the test-
        // context AsyncException. Success=false is expected inside tests.
        System.assertEquals(false, r.success);
        System.assertNotEquals(null, r.message);
        System.assert(
            r.message.containsIgnoreCase('deployed from within a test')
            || r.message.containsIgnoreCase('AsyncException'),
            'Expected AsyncException message, got: ' + r.message
        );
    }

    // DTO coverage for output types (matches pattern in
    // PulseWorkflowTriggerControllerTest.innerDtoCoverage).
    @IsTest
    static void innerDtoCoverage() {
        PulseActionStatusTemplateController.TemplateView v =
            new PulseActionStatusTemplateController.TemplateView();
        v.developerName = 'd'; v.templateKey = 'k'; v.displayName = 'n';
        v.description = 'x'; v.statusesJson = '[]';

        PulseActionStatusTemplateController.UpsertResult r =
            new PulseActionStatusTemplateController.UpsertResult();
        r.success = true; r.deploymentJobId = null; r.message = 'm';

        System.assertNotEquals(null, v);
        System.assertNotEquals(null, r);
    }
}
