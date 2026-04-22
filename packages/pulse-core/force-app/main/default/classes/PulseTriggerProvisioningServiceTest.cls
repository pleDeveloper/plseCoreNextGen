@IsTest
private class PulseTriggerProvisioningServiceTest {

    @IsTest
    static void triggerNameForStandardObject() {
        System.assertEquals(
            'Opportunity_PulseWorkflowTrigger',
            PulseTriggerProvisioningService.triggerNameFor('Opportunity')
        );
    }

    @IsTest
    static void triggerNameForCustomObjectStripsSuffix() {
        System.assertEquals(
            'My_Thing_PulseWorkflowTrigger',
            PulseTriggerProvisioningService.triggerNameFor('My_Thing__c')
        );
    }

    @IsTest
    static void triggerNameForBlankReturnsNull() {
        System.assertEquals(null, PulseTriggerProvisioningService.triggerNameFor(''));
        System.assertEquals(null, PulseTriggerProvisioningService.triggerNameFor(null));
    }

    @IsTest
    static void buildTriggerBodyContainsExpectedParts() {
        String body = PulseTriggerProvisioningService.buildTriggerBody(
            'Opportunity', 'Opportunity_PulseWorkflowTrigger'
        );
        System.assert(body.contains('trigger Opportunity_PulseWorkflowTrigger on Opportunity'));
        System.assert(body.contains('after insert, after update'));
        System.assert(body.contains('plse.PulseWorkflowStarter.handle'));
    }

    @IsTest
    static void ensureTriggerForUnknownObjectFails() {
        Test.startTest();
        PulseTriggerProvisioningService.ProvisionResult r =
            PulseTriggerProvisioningService.ensureTriggerFor('DoesNotExist__c');
        Test.stopTest();
        System.assertEquals(false, r.success);
        System.assert(r.message.contains('does not exist'));
    }

    @IsTest
    static void ensureTriggerForBlankFails() {
        PulseTriggerProvisioningService.ProvisionResult r =
            PulseTriggerProvisioningService.ensureTriggerFor('');
        System.assertEquals(false, r.success);
    }

    @IsTest
    static void ensureTriggerForValidObjectInTestModeSkipsCallout() {
        // In test context and without mockProvisioned flag we bypass the callout.
        Test.startTest();
        PulseTriggerProvisioningService.ProvisionResult r =
            PulseTriggerProvisioningService.ensureTriggerFor('Opportunity');
        Test.stopTest();
        System.assertEquals(true, r.success);
        System.assertEquals('Opportunity_PulseWorkflowTrigger', r.triggerName);
    }

    @IsTest
    static void provisionResultInnerTypeCoverage() {
        PulseTriggerProvisioningService.ProvisionResult r =
            new PulseTriggerProvisioningService.ProvisionResult();
        r.success        = true;
        r.alreadyExisted = false;
        r.triggerName    = 'X_PulseWorkflowTrigger';
        r.message        = 'ok';
        System.assertNotEquals(null, r);
    }

    // ── Callout coverage ──────────────────────────────────────────────
    // To cover the Tooling-API branch we flip the mockProvisioned flag
    // (which bypasses the early test-mode return) and stub the HTTP layer.

    private class CreatedMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse r = new HttpResponse();
            r.setStatusCode(201);
            r.setBody('{"id":"01qxx0000000001","success":true}');
            return r;
        }
    }

    private class FailureMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse r = new HttpResponse();
            r.setStatusCode(400);
            r.setBody('[{"message":"Duplicate name","errorCode":"DUPLICATE_VALUE"}]');
            return r;
        }
    }

    @IsTest
    static void ensureTriggerSucceedsOnCreatedResponse() {
        PulseTriggerProvisioningService.mockProvisioned = true;
        Test.setMock(HttpCalloutMock.class, new CreatedMock());

        Test.startTest();
        PulseTriggerProvisioningService.ProvisionResult r =
            PulseTriggerProvisioningService.ensureTriggerFor('Account');
        Test.stopTest();

        System.assertEquals(true, r.success, r.message);
        System.assertEquals(false, r.alreadyExisted);
        System.assertEquals('Account_PulseWorkflowTrigger', r.triggerName);
    }

    @IsTest
    static void ensureTriggerFailsOnToolingApiError() {
        PulseTriggerProvisioningService.mockProvisioned = true;
        Test.setMock(HttpCalloutMock.class, new FailureMock());

        Test.startTest();
        PulseTriggerProvisioningService.ProvisionResult r =
            PulseTriggerProvisioningService.ensureTriggerFor('Contact');
        Test.stopTest();

        System.assertEquals(false, r.success);
        System.assert(r.message.contains('Tooling API 400'));
    }
}
