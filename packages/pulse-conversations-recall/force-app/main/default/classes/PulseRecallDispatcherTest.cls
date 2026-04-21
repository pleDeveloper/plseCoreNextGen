@IsTest
private class PulseRecallDispatcherTest {

    // ── HTTP mock ───────────────────────────────────────────────────────

    private class RecallBotMock implements HttpCalloutMock {
        public Integer callCount = 0;

        public HttpResponse respond(HttpRequest req) {
            callCount++;
            HttpResponse res = new HttpResponse();
            res.setStatusCode(201);
            res.setBody('{"id":"bot-dispatch-' + callCount + '","status":"joining"}');
            return res;
        }
    }

    // ── Helpers ─────────────────────────────────────────────────────────

    private static Calendar_Auto_Dispatch_Rule__mdt buildRule(
            String name, String titlePattern, String source,
            Boolean consentRequired, Boolean active) {
        return new Calendar_Auto_Dispatch_Rule__mdt(
            DeveloperName = name,
            Rule_Name__c = name,
            Meeting_Title_Pattern__c = titlePattern,
            Calendar_Source__c = source,
            Consent_Required__c = consentRequired,
            Active__c = active,
            Bot_Persona__c = 'Notetaker'
        );
    }

    private static PulseRecallDispatcher.MeetingInfo buildMeeting(
            String url, String title, String source, Boolean consent) {
        PulseRecallDispatcher.MeetingInfo m = new PulseRecallDispatcher.MeetingInfo();
        m.meetingUrl = url;
        m.meetingTitle = title;
        m.calendarSource = source;
        m.consentGiven = consent;
        return m;
    }

    // ── Dispatches bot when rule matches ────────────────────────────────

    @IsTest
    static void execute_matchingRule_dispatchesBot() {
        RecallBotMock mock = new RecallBotMock();
        Test.setMock(HttpCalloutMock.class, mock);

        PulseRecallDispatcher.testRulesOverride = new List<Calendar_Auto_Dispatch_Rule__mdt>{
            buildRule('All_Meetings', null, null, false, true)
        };

        List<PulseRecallDispatcher.MeetingInfo> meetings =
            new List<PulseRecallDispatcher.MeetingInfo>{
                buildMeeting('https://zoom.us/j/111', 'Standup', 'google', false)
            };

        Test.startTest();
        System.enqueueJob(new PulseRecallDispatcher(meetings));
        Test.stopTest();

        // Mock was called — bot was dispatched
        System.assertEquals(1, mock.callCount, 'Should dispatch one bot');
    }

    // ── Blocked by consent requirement ──────────────────────────────────

    @IsTest
    static void execute_consentRequired_noConsent_skips() {
        RecallBotMock mock = new RecallBotMock();
        Test.setMock(HttpCalloutMock.class, mock);

        PulseRecallDispatcher.testRulesOverride = new List<Calendar_Auto_Dispatch_Rule__mdt>{
            buildRule('Consent_Rule', null, null, true, true)
        };

        List<PulseRecallDispatcher.MeetingInfo> meetings =
            new List<PulseRecallDispatcher.MeetingInfo>{
                buildMeeting('https://zoom.us/j/222', 'Private Call', 'google', false)
            };

        Test.startTest();
        System.enqueueJob(new PulseRecallDispatcher(meetings));
        Test.stopTest();

        System.assertEquals(0, mock.callCount,
            'Should not dispatch when consent required but not given');
    }

    // ── Consent given — dispatches ──────────────────────────────────────

    @IsTest
    static void execute_consentRequired_consentGiven_dispatches() {
        RecallBotMock mock = new RecallBotMock();
        Test.setMock(HttpCalloutMock.class, mock);

        PulseRecallDispatcher.testRulesOverride = new List<Calendar_Auto_Dispatch_Rule__mdt>{
            buildRule('Consent_Rule', null, null, true, true)
        };

        List<PulseRecallDispatcher.MeetingInfo> meetings =
            new List<PulseRecallDispatcher.MeetingInfo>{
                buildMeeting('https://zoom.us/j/333', 'Team Sync', 'google', true)
            };

        Test.startTest();
        System.enqueueJob(new PulseRecallDispatcher(meetings));
        Test.stopTest();

        System.assertEquals(1, mock.callCount,
            'Should dispatch when consent is given');
    }

    // ── No matching rules ───────────────────────────────────────────────

    @IsTest
    static void execute_noMatchingRules_doesNotDispatch() {
        RecallBotMock mock = new RecallBotMock();
        Test.setMock(HttpCalloutMock.class, mock);

        PulseRecallDispatcher.testRulesOverride = new List<Calendar_Auto_Dispatch_Rule__mdt>{
            buildRule('Outlook_Only', null, 'outlook', false, true)
        };

        List<PulseRecallDispatcher.MeetingInfo> meetings =
            new List<PulseRecallDispatcher.MeetingInfo>{
                buildMeeting('https://zoom.us/j/444', 'Standup', 'google', false)
            };

        Test.startTest();
        System.enqueueJob(new PulseRecallDispatcher(meetings));
        Test.stopTest();

        System.assertEquals(0, mock.callCount,
            'Should not dispatch when calendar source does not match');
    }

    // ── Title pattern matching ──────────────────────────────────────────

    @IsTest
    static void execute_titlePatternMatch_dispatches() {
        RecallBotMock mock = new RecallBotMock();
        Test.setMock(HttpCalloutMock.class, mock);

        PulseRecallDispatcher.testRulesOverride = new List<Calendar_Auto_Dispatch_Rule__mdt>{
            buildRule('Standup_Rule', '.*Standup.*', null, false, true)
        };

        List<PulseRecallDispatcher.MeetingInfo> meetings =
            new List<PulseRecallDispatcher.MeetingInfo>{
                buildMeeting('https://zoom.us/j/555', 'Daily Standup Call', 'google', false)
            };

        Test.startTest();
        System.enqueueJob(new PulseRecallDispatcher(meetings));
        Test.stopTest();

        System.assertEquals(1, mock.callCount,
            'Should dispatch when title matches pattern');
    }

    @IsTest
    static void execute_titlePatternNoMatch_skips() {
        RecallBotMock mock = new RecallBotMock();
        Test.setMock(HttpCalloutMock.class, mock);

        PulseRecallDispatcher.testRulesOverride = new List<Calendar_Auto_Dispatch_Rule__mdt>{
            buildRule('Standup_Rule', '.*Standup.*', null, false, true)
        };

        List<PulseRecallDispatcher.MeetingInfo> meetings =
            new List<PulseRecallDispatcher.MeetingInfo>{
                buildMeeting('https://zoom.us/j/666', 'Lunch Break', 'google', false)
            };

        Test.startTest();
        System.enqueueJob(new PulseRecallDispatcher(meetings));
        Test.stopTest();

        System.assertEquals(0, mock.callCount,
            'Should not dispatch when title does not match pattern');
    }

    // ── Empty meetings list ─────────────────────────────────────────────

    @IsTest
    static void execute_emptyMeetings_noErrors() {
        PulseRecallDispatcher.testRulesOverride = new List<Calendar_Auto_Dispatch_Rule__mdt>{
            buildRule('All', null, null, false, true)
        };

        Test.startTest();
        System.enqueueJob(
            new PulseRecallDispatcher(new List<PulseRecallDispatcher.MeetingInfo>()));
        Test.stopTest();
        // No exception = pass
    }

    // ── Rule matching unit test ─────────────────────────────────────────

    @IsTest
    static void matchRule_returnsFirstMatch() {
        Calendar_Auto_Dispatch_Rule__mdt rule1 =
            buildRule('Google', null, 'google', false, true);
        Calendar_Auto_Dispatch_Rule__mdt rule2 =
            buildRule('Outlook', null, 'outlook', false, true);

        PulseRecallDispatcher.MeetingInfo meeting =
            buildMeeting('url', 'title', 'google', false);

        Calendar_Auto_Dispatch_Rule__mdt matched = PulseRecallDispatcher.matchRule(
            meeting,
            new List<Calendar_Auto_Dispatch_Rule__mdt>{ rule1, rule2 }
        );

        System.assertNotEquals(null, matched);
        System.assertEquals('Google', matched.DeveloperName);
    }
}
