/**
 * Queueable that evaluates Calendar_Auto_Dispatch_Rule__mdt and dispatches
 * Recall bots for matching meetings. Respects consent requirements and
 * title-pattern filters.
 */
public with sharing class PulseRecallDispatcher implements Queueable, Database.AllowsCallouts {

    @TestVisible
    private static List<Calendar_Auto_Dispatch_Rule__mdt> testRulesOverride;

    // ── Input DTO ───────────────────────────────────────────────────────

    public class MeetingInfo {
        public String meetingUrl;
        public String meetingTitle;
        public String calendarSource;
        public Boolean consentGiven;

        public MeetingInfo() {
            this.consentGiven = false;
        }
    }

    // ── State ───────────────────────────────────────────────────────────

    private List<MeetingInfo> meetings;

    public PulseRecallDispatcher(List<MeetingInfo> meetings) {
        this.meetings = meetings;
    }

    // ── Queueable entry point ───────────────────────────────────────────

    public void execute(QueueableContext ctx) {
        if (meetings == null || meetings.isEmpty()) {
            return;
        }

        List<Calendar_Auto_Dispatch_Rule__mdt> rules = loadActiveRules();
        if (rules.isEmpty()) {
            return;
        }

        RecallAdapter adapter = new RecallAdapter();

        for (MeetingInfo meeting : meetings) {
            Calendar_Auto_Dispatch_Rule__mdt matched = matchRule(meeting, rules);
            if (matched == null) {
                continue;
            }

            // Hard constraint: never auto-dispatch without consent when required
            if (matched.Consent_Required__c && !meeting.consentGiven) {
                continue;
            }

            RecallAdapter.RecallBotRequest botReq = new RecallAdapter.RecallBotRequest();
            botReq.meetingUrl = meeting.meetingUrl;
            botReq.botName = 'Pulse Notetaker';
            botReq.botPersona = matched.Bot_Persona__c;

            try {
                adapter.createBot(botReq);
            } catch (RecallAdapter.RecallAdapterException e) {
                System.debug(LoggingLevel.ERROR,
                    'Recall dispatch failed for ' + meeting.meetingUrl
                    + ': ' + e.getMessage());
            }
        }
    }

    // ── Rule loading ────────────────────────────────────────────────────

    @TestVisible
    private static List<Calendar_Auto_Dispatch_Rule__mdt> loadActiveRules() {
        if (testRulesOverride != null) {
            return testRulesOverride;
        }
        List<Calendar_Auto_Dispatch_Rule__mdt> active =
            new List<Calendar_Auto_Dispatch_Rule__mdt>();
        for (Calendar_Auto_Dispatch_Rule__mdt rule
                : Calendar_Auto_Dispatch_Rule__mdt.getAll().values()) {
            if (rule.Active__c) {
                active.add(rule);
            }
        }
        return active;
    }

    // ── Rule matching ───────────────────────────────────────────────────

    @TestVisible
    private static Calendar_Auto_Dispatch_Rule__mdt matchRule(
            MeetingInfo meeting,
            List<Calendar_Auto_Dispatch_Rule__mdt> rules) {

        for (Calendar_Auto_Dispatch_Rule__mdt rule : rules) {
            // Filter by calendar source when specified
            if (String.isNotBlank(rule.Calendar_Source__c)
                    && rule.Calendar_Source__c != meeting.calendarSource) {
                continue;
            }

            // Filter by title pattern when specified
            if (String.isNotBlank(rule.Meeting_Title_Pattern__c)) {
                if (String.isBlank(meeting.meetingTitle)
                        || !Pattern.matches(
                            rule.Meeting_Title_Pattern__c, meeting.meetingTitle)) {
                    continue;
                }
            }

            return rule;
        }
        return null;
    }
}
