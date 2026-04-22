@IsTest
private class InboundRecordRouterTest {

    private static Conversation_Routing_Rule__mdt buildRule(
        String key, Integer priority, String strategy,
        String targetObject, String defaultsJson, String workflowKey, Boolean active
    ) {
        Conversation_Routing_Rule__mdt r = new Conversation_Routing_Rule__mdt();
        r.DeveloperName           = key;
        r.Rule_Key__c             = key;
        r.Priority__c             = priority;
        r.Match_Strategy__c       = strategy;
        r.Target_Object__c        = targetObject;
        r.Create_Defaults_JSON__c = defaultsJson;
        r.Trigger_Workflow_Key__c = workflowKey;
        r.Source_Adapter__c       = 'email';
        r.Active__c               = active;
        return r;
    }

    private static final String DEFAULTS =
        '{"StageName":"Qualification","CloseDate":"+30d","Name":"New inquiry from {senderEmail}"}';

    @IsTest
    static void threadMatch_returnsExistingRecord() {
        // Seed an Opportunity and a Conversation that already points at it,
        // with the sender in Participants__c.
        Opportunity opp = new Opportunity(
            Name = 'Existing Opp',
            StageName = 'Qualification',
            CloseDate = Date.today().addDays(10)
        );
        insert opp;

        insert new Conversation__c(
            Medium__c = 'Email',
            Subject__c = 'Prior thread',
            Source_Adapter__c = 'inbound_email',
            Participants__c = 'Jane Doe; jane@example.com; leasing@us.com',
            Parent_Object_Type__c = 'Opportunity',
            Parent_Record_Id__c = opp.Id,
            Status__c = 'Ingested'
        );

        Test.startTest();
        InboundRecordRouter.RouteResult r = InboundRecordRouter.route(
            'jane@example.com', 'Re: something', null
        );
        Test.stopTest();

        System.assertNotEquals(null, r);
        System.assertEquals(opp.Id, r.recordId, 'Should return existing parent');
        System.assertEquals(true, r.matchedExistingThread);
        System.assertEquals(false, r.wasCreated);
        System.assertEquals('Opportunity', r.objectType);
    }

    @IsTest
    static void threadMiss_contactWithOpenOpp_returnsContactsOpp() {
        // Contact with an open Opportunity via contact role relationship
        Account acct = new Account(Name = 'Acme');
        insert acct;
        Contact c = new Contact(
            FirstName = 'Jordan', LastName = 'Matthews',
            Email = 'jordan@abc.com', AccountId = acct.Id
        );
        insert c;
        Opportunity opp = new Opportunity(
            Name = 'Open Opp',
            StageName = 'Qualification',
            CloseDate = Date.today().addDays(15),
            AccountId = acct.Id
        );
        insert opp;
        // child relation via ContactId (standard contact-opp relation)
        // Contact.Opportunities sub-query uses the OpportunityContactRole junction,
        // but the Contact → Opportunities child relation is the OpportunityContactRole
        // relation name 'Opportunities'. We populate via OpportunityContactRole.
        insert new OpportunityContactRole(
            OpportunityId = opp.Id, ContactId = c.Id, Role = 'Decision Maker'
        );

        InboundRecordRouter.testRuleOverride = new List<Conversation_Routing_Rule__mdt>{
            buildRule('rule1', 100, 'EMAIL_SENDER_TO_CONTACT', 'Opportunity',
                DEFAULTS, 'wf1', true)
        };

        Test.startTest();
        InboundRecordRouter.RouteResult r = InboundRecordRouter.route(
            'jordan@abc.com', 'New question', null
        );
        Test.stopTest();

        System.assertNotEquals(null, r);
        System.assertEquals(opp.Id, r.recordId);
        System.assertEquals(false, r.wasCreated);
        System.assertEquals(false, r.matchedExistingThread);
        System.assertEquals('rule1', r.ruleKey);
        System.assertEquals('wf1', r.triggerWorkflowKey);
    }

    @IsTest
    static void contactNoOpenOpp_createsNewOppOnAccount() {
        Account acct = new Account(Name = 'Acme Holdings');
        insert acct;
        Contact c = new Contact(
            FirstName = 'Kim', LastName = 'Lee',
            Email = 'kim@abc.com', AccountId = acct.Id
        );
        insert c;

        InboundRecordRouter.testRuleOverride = new List<Conversation_Routing_Rule__mdt>{
            buildRule('rule1', 100, 'EMAIL_SENDER_TO_CONTACT', 'Opportunity',
                DEFAULTS, 'wf1', true)
        };

        Test.startTest();
        InboundRecordRouter.RouteResult r = InboundRecordRouter.route(
            'kim@abc.com', 'New inquiry', null
        );
        Test.stopTest();

        System.assertNotEquals(null, r);
        System.assertNotEquals(null, r.recordId);
        System.assertEquals(true, r.wasCreated);

        Opportunity created = [
            SELECT Id, Name, StageName, CloseDate, AccountId
            FROM Opportunity
            WHERE Id = :r.recordId
        ];
        System.assertEquals('Qualification', created.StageName);
        System.assert(created.Name.contains('kim@abc.com'),
            'Name placeholder should be substituted');
        System.assertEquals(acct.Id, created.AccountId,
            'New Opp should inherit AccountId from Contact');
        System.assert(created.CloseDate >= Date.today().addDays(29) &&
                      created.CloseDate <= Date.today().addDays(31),
            'CloseDate should be ~30 days in the future');
    }

    @IsTest
    static void noContact_createsBareOppFromDefaults() {
        InboundRecordRouter.testRuleOverride = new List<Conversation_Routing_Rule__mdt>{
            buildRule('rule1', 100, 'EMAIL_SENDER_TO_CONTACT', 'Opportunity',
                DEFAULTS, 'wf1', true)
        };

        Test.startTest();
        InboundRecordRouter.RouteResult r = InboundRecordRouter.route(
            'stranger@nowhere.com', 'Inquiry', null
        );
        Test.stopTest();

        System.assertNotEquals(null, r.recordId);
        System.assertEquals(true, r.wasCreated);

        Opportunity created = [
            SELECT Id, Name, StageName, CloseDate, AccountId
            FROM Opportunity
            WHERE Id = :r.recordId
        ];
        System.assert(created.Name.contains('stranger@nowhere.com'));
        System.assertEquals(null, created.AccountId,
            'No contact → no Account linkage');
    }

    @IsTest
    static void priorityOrdering_lowerRunsFirst() {
        // Two rules, one with priority 10 (should win) and one with 100
        InboundRecordRouter.testRuleOverride = new List<Conversation_Routing_Rule__mdt>{
            buildRule('low_priority', 100, 'EMAIL_SENDER_TO_CONTACT', 'Opportunity',
                DEFAULTS, 'wf_low', true),
            buildRule('high_priority', 10, 'EMAIL_SENDER_TO_CONTACT', 'Opportunity',
                DEFAULTS, 'wf_high', true)
        };

        // The router sorts the list it queries; when we inject an override,
        // we must pre-sort to mirror production ordering.
        InboundRecordRouter.testRuleOverride.sort(new RulePrioritySorter());

        Test.startTest();
        InboundRecordRouter.RouteResult r = InboundRecordRouter.route(
            'priority@test.com', 'Test', null
        );
        Test.stopTest();

        System.assertEquals('high_priority', r.ruleKey,
            'Rule with priority=10 should win');
        System.assertEquals('wf_high', r.triggerWorkflowKey);
    }

    @IsTest
    static void noActiveRules_returnsNullRecord() {
        InboundRecordRouter.testRuleOverride = new List<Conversation_Routing_Rule__mdt>();

        Test.startTest();
        InboundRecordRouter.RouteResult r = InboundRecordRouter.route(
            'noone@example.com', 'Hi', null
        );
        Test.stopTest();

        System.assertNotEquals(null, r);
        System.assertEquals(null, r.recordId);
        System.assertEquals(false, r.wasCreated);
        System.assertEquals(false, r.matchedExistingThread);
    }

    @IsTest
    static void blankSender_returnsEmptyResult() {
        Test.startTest();
        InboundRecordRouter.RouteResult r = InboundRecordRouter.route('', 'Subj', null);
        Test.stopTest();
        System.assertEquals(null, r.recordId);
    }

    @IsTest
    static void parseDateOffset_handlesPlusMinusAndGarbage() {
        System.assertEquals(30, InboundRecordRouter.parseDateOffset('+30d'));
        System.assertEquals(-7, InboundRecordRouter.parseDateOffset('-7d'));
        System.assertEquals(null, InboundRecordRouter.parseDateOffset('today'));
        System.assertEquals(null, InboundRecordRouter.parseDateOffset(''));
        System.assertEquals(null, InboundRecordRouter.parseDateOffset('30'));
    }

    // Comparator so we can sort override rules the same way the SOQL does.
    private class RulePrioritySorter implements System.Comparator<Conversation_Routing_Rule__mdt> {
        public Integer compare(Conversation_Routing_Rule__mdt a, Conversation_Routing_Rule__mdt b) {
            Decimal ap = a.Priority__c == null ? 99999 : a.Priority__c;
            Decimal bp = b.Priority__c == null ? 99999 : b.Priority__c;
            if (ap < bp) return -1;
            if (ap > bp) return 1;
            return 0;
        }
    }
}
