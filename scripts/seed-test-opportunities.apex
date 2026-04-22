// ============================================================
// seed-test-opportunities.apex
// ============================================================
// Seeds 3 additional test Opportunities wired to the Real Estate
// Leasing workflow. Each gets:
//   - A Workflow_Instance__c at intake_qualification
//   - A Conversation__c with 3 turns (inbound email thread)
//   - A pending Workflow_Action__c (send_email HITL approval)
//
// Reuses the 'real_estate_leasing_v1' Workflow_Definition__c.
// Idempotent — keyed on Opportunity.Name.
//
// Run with:
//   sf apex run -o pulse-core-next-dev -f scripts/seed-test-opportunities.apex
// ============================================================

final String WORKFLOW_KEY = 'real_estate_leasing_v1';

List<plse__Workflow_Definition__c> defs = [
    SELECT Id FROM plse__Workflow_Definition__c
    WHERE plse__Workflow_Key__c = :WORKFLOW_KEY LIMIT 1
];
if (defs.isEmpty()) {
    throw new System.AsyncException(
        'Workflow definition "' + WORKFLOW_KEY + '" not found. Run seed-real-estate-demo.apex first.');
}
Id defId = defs[0].Id;

// Build scenarios as parallel lists to avoid anonymous-Apex map-literal-as-arg issues.
List<String> names = new List<String>();
List<String> stages = new List<String>();
List<Decimal> amounts = new List<Decimal>();
List<String> applicants = new List<String>();
List<String> contacts = new List<String>();
List<String> emails = new List<String>();
List<String> subjects = new List<String>();
List<String> inbounds = new List<String>();
List<String> replies = new List<String>();
List<String> followups = new List<String>();
List<String> requests = new List<String>();

// Scenario 1: Midtown Tech Startup
names.add('Midtown Tech Startup — 3,200 sqft lease');
stages.add('Qualification');
amounts.add(153600);
applicants.add('Helix Robotics');
contacts.add('Priya Shah');
emails.add('priya@helixrobotics.io');
subjects.add('Looking for 3,000-3,500 sqft in Midtown');
inbounds.add('Hi — we are Helix Robotics, a Series A robotics startup. We are outgrowing our current space and are interested in your Midtown listing (the ~3,200 sqft one). We have 22 people today, likely 35 by end of year. Can you share the floor plate and send over an application?');
replies.add('Thanks for reaching out, Priya. Happy to help. The Midtown unit is 3,200 usable sqft, single floor, 2 conference rooms built in. Application attached. Let me know when you can send it back.');
followups.add('Application coming your way by Friday. One question — does the HVAC support 24/7 server room cooling? We have a small GPU cluster.');
requests.add('{"toAddress":"priya@helixrobotics.io","subject":"Re: Looking for 3,000-3,500 sqft in Midtown — next steps","body":"Hi Priya — great to hear from you. To move forward with qualification on the Midtown space, could you send over the following?\\n\\n1. Most recent two quarters of financials (or funding docs if pre-revenue)\\n2. Projected headcount at 12 and 24 months\\n3. Specific IT/HVAC requirements for the GPU cluster you mentioned\\n\\nOn the HVAC question — the unit has redundant HVAC with 24/7 capability, we can walk through specs on the tour.\\n\\nLet me know what times work this week for a site visit.\\n\\nBest,\\nLeasing Team"}');

// Scenario 2: Brooklyn Design Studio
names.add('Brooklyn Design Studio — 5,500 sqft lease');
stages.add('Proposal/Price Quote');
amounts.add(247500);
applicants.add('Foxglove Design Collective');
contacts.add('Marcus Okafor');
emails.add('marcus@foxglovestudio.co');
subjects.add('Foxglove Design — 5,500 sqft in DUMBO');
inbounds.add('Hello — Marcus from Foxglove Design Collective. We saw your DUMBO listing. We are a 30-person design studio looking to consolidate two offices. Seven-year lease preferred, with option to expand into the adjacent unit if it opens up. Can we set up a tour?');
replies.add('Marcus — love Foxglove work. Tour can happen this week. The adjacent unit is month-to-month currently so expansion is very doable. Throwing over a few time slots separately.');
followups.add('Great, Thursday 3pm works. Also — we are pre-planning a build-out with exposed ceilings. Any restrictions on that in the lease?');
requests.add('{"toAddress":"marcus@foxglovestudio.co","subject":"Re: Foxglove Design — 5,500 sqft in DUMBO — application + build-out details","body":"Hi Marcus — confirming Thursday 3pm for the tour.\\n\\nOn the build-out: exposed ceilings are permitted in DUMBO as long as sprinkler coverage is maintained. Our tenant improvement allowance is $55/sqft for a 7-year term, which should cover most of what you described.\\n\\nTo move to next steps, please send over:\\n\\n1. Foxglove last two years of financials (or partner personal guarantees if thinner)\\n2. Bank references\\n3. Preferred lease commencement date\\n\\nLooking forward to Thursday.\\n\\nBest,\\nLeasing Team"}');

// Scenario 3: Chelsea Architecture Firm
names.add('Chelsea Architecture Firm — 12,000 sqft lease');
stages.add('Negotiation/Review');
amounts.add(648000);
applicants.add('Veldt & Laurents Architects');
contacts.add('Catherine Laurents');
emails.add('catherine@veldtlaurents.com');
subjects.add('Veldt & Laurents — Chelsea expansion');
inbounds.add('Hi — Catherine Laurents from Veldt & Laurents. We have been in our current Chelsea space for 11 years and the lease is up next March. Planning to double our footprint to around 12,000 sqft. Have a strong preference for the neighborhood. What do you have that would fit 60-70 people plus a model-making shop?');
replies.add('Catherine — we have the 14th floor at 245 W 25th, 12,400 sqft, with loading access for a shop space. Pre-marketing list right now, available April 1. Happy to walk it whenever.');
followups.add('That timing is close to perfect. Please send the floor plan and rent sheet. We are serious on this.');
requests.add('{"toAddress":"catherine@veldtlaurents.com","subject":"Re: Veldt & Laurents — Chelsea expansion — qualification docs","body":"Catherine — 245 W 25th 14th floor, floor plan and rent sheet attached separately.\\n\\nGiven the lease size and the timing overlap with your current term, we will need to move qualification forward quickly. Could you send by end of next week:\\n\\n1. Firm financials, last three years\\n2. Current landlord reference\\n3. Any strategic partners or equity investors we should know about\\n4. A short LOI with your target commencement date and requested TI allowance\\n\\nHappy to jump on a call to walk through the lease economics before you put the LOI together.\\n\\nBest,\\nLeasing Team"}');

for (Integer i = 0; i < names.size(); i++) {
    String oppName = names[i];

    Opportunity opp;
    List<Opportunity> existing = [SELECT Id FROM Opportunity WHERE Name = :oppName LIMIT 1];
    if (!existing.isEmpty()) {
        opp = existing[0];
        System.debug('### Reusing Opportunity: ' + oppName);
    } else {
        opp = new Opportunity(
            Name = oppName,
            StageName = stages[i],
            CloseDate = Date.today().addDays(45),
            Amount = amounts[i]
        );
        insert opp;
        System.debug('### Created Opportunity: ' + oppName);
    }

    plse__Workflow_Instance__c inst;
    List<plse__Workflow_Instance__c> existingInst = [
        SELECT Id FROM plse__Workflow_Instance__c
        WHERE plse__Workflow_Definition__c = :defId
          AND plse__Parent_Record_Id__c = :opp.Id
        LIMIT 1
    ];
    if (!existingInst.isEmpty()) {
        inst = existingInst[0];
        inst.plse__Current_State__c = 'intake_qualification';
        inst.plse__Status__c = 'Active';
        inst.plse__Pinned_Version__c = 1;
        update inst;
    } else {
        inst = new plse__Workflow_Instance__c(
            plse__Workflow_Definition__c = defId,
            plse__Current_State__c = 'intake_qualification',
            plse__Status__c = 'Active',
            plse__Pinned_Version__c = 1,
            plse__Started_Date__c = Datetime.now().addDays(-3),
            plse__Parent_Object_Type__c = 'Opportunity',
            plse__Parent_Record_Id__c = opp.Id,
            plse__Context_JSON__c = '{"applicant_name":"' + applicants[i] + '"}'
        );
        insert inst;
    }

    // History steps + dwell facts — so the journey timeline has content
    Integer existingSteps = [
        SELECT COUNT() FROM plse__Workflow_Step_Result__c
        WHERE plse__Workflow_Instance__c = :inst.Id
    ];
    if (existingSteps == 0) {
        Datetime now   = Datetime.now();
        Datetime tIntake    = now.addDays(-4);
        Datetime tTour      = now.addDays(-3).addHours(-1);
        Datetime tApp       = now.addDays(-2).addHours(-3);
        Datetime tQualEntry = now.addHours(-18);

        List<plse__Workflow_Step_Result__c> steps = new List<plse__Workflow_Step_Result__c>();
        steps.add(new plse__Workflow_Step_Result__c(
            plse__Workflow_Instance__c = inst.Id,
            plse__State_Key__c        = 'intake',
            plse__Signal__c           = 'schedule_tour',
            plse__Outcome__c          = 'Completed',
            plse__Actor_Type__c       = 'Human',
            plse__Actor_User__c       = UserInfo.getUserId(),
            plse__Started_Date__c     = tIntake,
            plse__Completed_Date__c   = tTour,
            plse__Values_JSON__c      = '{"applicant_name":"' + applicants[i] + '","requested_sqft":0,"intake_notes":"Inbound email inquiry"}'
        ));
        steps.add(new plse__Workflow_Step_Result__c(
            plse__Workflow_Instance__c = inst.Id,
            plse__State_Key__c        = 'tour_scheduled',
            plse__Signal__c           = 'submit_application',
            plse__Outcome__c          = 'Completed',
            plse__Actor_Type__c       = 'Human',
            plse__Actor_User__c       = UserInfo.getUserId(),
            plse__Started_Date__c     = tTour,
            plse__Completed_Date__c   = tApp,
            plse__Values_JSON__c      = '{"tour_host_name":"Leasing Team"}'
        ));
        steps.add(new plse__Workflow_Step_Result__c(
            plse__Workflow_Instance__c = inst.Id,
            plse__State_Key__c        = 'application_submitted',
            plse__Signal__c           = 'qualify',
            plse__Outcome__c          = 'Completed',
            plse__Actor_Type__c       = 'Human',
            plse__Actor_User__c       = UserInfo.getUserId(),
            plse__Started_Date__c     = tApp,
            plse__Completed_Date__c   = tQualEntry,
            plse__Values_JSON__c      = '{}'
        ));
        insert steps;

        List<plse__Stage_Dwell__c> dwells = new List<plse__Stage_Dwell__c>();
        dwells.add(new plse__Stage_Dwell__c(
            plse__Workflow_Instance__c = inst.Id,
            plse__Workflow_Key__c      = WORKFLOW_KEY,
            plse__Subject_Kind__c      = 'Opportunity',
            plse__State_Key__c         = 'intake',
            plse__State_Label__c       = 'Intake',
            plse__State_Type__c        = 'form',
            plse__Entered_At__c        = tIntake,
            plse__Exited_At__c         = tTour,
            plse__Duration_Seconds__c  = Math.round((tTour.getTime() - tIntake.getTime()) / 1000.0),
            plse__Next_State_Key__c    = 'tour_scheduled',
            plse__Signal__c            = 'schedule_tour',
            plse__Actor_Type__c        = 'Human'
        ));
        dwells.add(new plse__Stage_Dwell__c(
            plse__Workflow_Instance__c = inst.Id,
            plse__Workflow_Key__c      = WORKFLOW_KEY,
            plse__Subject_Kind__c      = 'Opportunity',
            plse__State_Key__c         = 'tour_scheduled',
            plse__State_Label__c       = 'Tour Scheduled',
            plse__State_Type__c        = 'form',
            plse__Entered_At__c        = tTour,
            plse__Exited_At__c         = tApp,
            plse__Duration_Seconds__c  = Math.round((tApp.getTime() - tTour.getTime()) / 1000.0),
            plse__Next_State_Key__c    = 'application_submitted',
            plse__Signal__c            = 'submit_application',
            plse__Actor_Type__c        = 'Human'
        ));
        dwells.add(new plse__Stage_Dwell__c(
            plse__Workflow_Instance__c = inst.Id,
            plse__Workflow_Key__c      = WORKFLOW_KEY,
            plse__Subject_Kind__c      = 'Opportunity',
            plse__State_Key__c         = 'application_submitted',
            plse__State_Label__c       = 'Application Submitted',
            plse__State_Type__c        = 'approval',
            plse__Entered_At__c        = tApp,
            plse__Exited_At__c         = tQualEntry,
            plse__Duration_Seconds__c  = Math.round((tQualEntry.getTime() - tApp.getTime()) / 1000.0),
            plse__Next_State_Key__c    = 'intake_qualification',
            plse__Signal__c            = 'qualify',
            plse__Actor_Type__c        = 'Human'
        ));
        dwells.add(new plse__Stage_Dwell__c(
            plse__Workflow_Instance__c = inst.Id,
            plse__Workflow_Key__c      = WORKFLOW_KEY,
            plse__Subject_Kind__c      = 'Opportunity',
            plse__State_Key__c         = 'intake_qualification',
            plse__State_Label__c       = 'Intake Qualification',
            plse__State_Type__c        = 'ai_driven',
            plse__Entered_At__c        = tQualEntry,
            plse__Exited_At__c         = null,
            plse__Duration_Seconds__c  = null,
            plse__Actor_Type__c        = 'AI'
        ));
        insert dwells;
        System.debug('### Seeded history + dwells for: ' + oppName);
    }

    String convExternalId = 'test-opp-' + inst.Id;
    plse__Conversation__c conv;
    List<plse__Conversation__c> existingConv = [
        SELECT Id FROM plse__Conversation__c
        WHERE plse__External_Source_Id__c = :convExternalId LIMIT 1
    ];
    if (existingConv.isEmpty()) {
        conv = new plse__Conversation__c(
            plse__Medium__c = 'Email',
            plse__Subject__c = subjects[i],
            plse__Summary__c = applicants[i] + ' inbound inquiry',
            plse__Participants__c = contacts[i] + ' <' + emails[i] + '>; leasing@ourcompany.com',
            plse__Source_Adapter__c = 'email',
            plse__External_Source__c = 'inbound_email',
            plse__External_Source_Id__c = convExternalId,
            plse__Parent_Object_Type__c = 'Opportunity',
            plse__Parent_Record_Id__c = opp.Id,
            plse__Workflow_Instance__c = inst.Id,
            plse__Status__c = 'Extracted'
        );
        insert conv;

        List<plse__Conversation_Turn__c> turns = new List<plse__Conversation_Turn__c>();
        turns.add(new plse__Conversation_Turn__c(
            plse__Conversation__c = conv.Id,
            plse__Turn_Index__c = 0,
            plse__Role__c = 'Customer',
            plse__Speaker__c = contacts[i],
            plse__Content__c = inbounds[i],
            plse__Timestamp__c = Datetime.now().addDays(-4)
        ));
        turns.add(new plse__Conversation_Turn__c(
            plse__Conversation__c = conv.Id,
            plse__Turn_Index__c = 1,
            plse__Role__c = 'Agent',
            plse__Speaker__c = 'Leasing Team',
            plse__Content__c = replies[i],
            plse__Timestamp__c = Datetime.now().addDays(-4).addHours(4)
        ));
        turns.add(new plse__Conversation_Turn__c(
            plse__Conversation__c = conv.Id,
            plse__Turn_Index__c = 2,
            plse__Role__c = 'Customer',
            plse__Speaker__c = contacts[i],
            plse__Content__c = followups[i],
            plse__Timestamp__c = Datetime.now().addDays(-3).addHours(2)
        ));
        insert turns;
        System.debug('### Created Conversation + 3 turns for: ' + oppName);
    }

    List<plse__Workflow_Action__c> existingAct = [
        SELECT Id, plse__Status__c
        FROM plse__Workflow_Action__c
        WHERE plse__Workflow_Instance__c = :inst.Id
          AND plse__Phase_Key__c = 'intake_qualification'
          AND plse__Action_Key__c = 'send_followup_email'
        LIMIT 1
    ];
    if (!existingAct.isEmpty()) {
        plse__Workflow_Action__c a = existingAct[0];
        a.plse__Request_JSON__c       = requests[i];
        a.plse__Label__c              = 'Send follow-up email';
        a.plse__Tool_Key__c           = 'send_email';
        a.plse__HITL_Policy__c        = 'Approval_Required';
        a.plse__Required_For_Phase__c = true;
        if (a.plse__Status__c != 'Executed' && a.plse__Status__c != 'Rejected') {
            a.plse__Status__c = 'Pending';
        }
        update a;
    } else {
        insert new plse__Workflow_Action__c(
            plse__Workflow_Instance__c = inst.Id,
            plse__Action_Key__c        = 'send_followup_email',
            plse__Phase_Key__c         = 'intake_qualification',
            plse__Label__c             = 'Send follow-up email',
            plse__Tool_Key__c          = 'send_email',
            plse__Action_Type__c       = 'AI_Tool_Call',
            plse__HITL_Policy__c       = 'Approval_Required',
            plse__Status__c            = 'Pending',
            plse__Required_For_Phase__c = true,
            plse__Sequence__c          = 0,
            plse__Request_JSON__c      = requests[i]
        );
        System.debug('### Created pending HITL action for: ' + oppName);
    }
}

System.debug('### Seeded ' + names.size() + ' test opportunities. Visit each to see the Action Hub.');
