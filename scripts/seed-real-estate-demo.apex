// ============================================================
// seed-real-estate-demo.apex
// ============================================================
// Seeds the Real Estate Leasing demo scenario into a plse-namespaced
// scratch org. Idempotent — re-running after a partial run won't
// duplicate records (it keys on business-unique fields).
//
// Run with:
//   sf apex run -o pulse-core-next-dev -f scripts/seed-real-estate-demo.apex
//
// What this creates:
//   - Workflow_Definition__c (Workflow_Key = 'real_estate_leasing_v1')
//   - Opportunity (Name = 'Downtown Law Firm — 8,500 sqft lease')
//   - Workflow_Instance__c at state 'intake_qualification'
//   - 3 completed Workflow_Step_Result__c history rows
//   - 3 Stage_Dwell__c rows (so the SLA heatmap has data)
//   - 1 Conversation__c with 3 Conversation_Turn__c rows (tenant inquiry)
//   - 1 Conversation_Extract__c with 3 pending facts
//   - 1 Workflow_Action__c (pending HITL approval for an AI tool call)
//
// NOT created by this script:
//   - Workflow_Projection__mdt rows — those are CMDT records that
//     require async Metadata API deploy. Either publish the workflow
//     through the Admin Studio UI (which creates them for you via the
//     Tooling API), or deploy the sample projection CMDT records from
//     scripts/seed-demo-projections/ if that directory exists.
// ============================================================

final String WORKFLOW_KEY = 'real_estate_leasing_v1';
final String OPP_NAME     = 'Downtown Law Firm — 8,500 sqft lease';

// ------------------------------------------------------------
// 1. Workflow_Definition__c
// ------------------------------------------------------------
String contractJson =
    '{"schema":"pulse.workflow.v1",' +
    '"workflowKey":"' + WORKFLOW_KEY + '",' +
    '"version":1,' +
    '"subjectKinds":["Opportunity"],' +
    '"states":[' +
      '{"key":"intake","label":"Intake","type":"form",' +
        '"fields":[' +
          '{"key":"applicant_name","label":"Applicant Name","type":"Text","required":true,"projection":{"enabled":true,"scope":"WorkflowScoped"}},' +
          '{"key":"requested_sqft","label":"Requested Sqft","type":"Number","required":true,"projection":{"enabled":true,"scope":"WorkflowScoped"}},' +
          '{"key":"intake_notes","label":"Intake Notes","type":"LongTextArea","required":false,"projection":{"enabled":false}}' +
        '],' +
        '"transitions":[{"signal":"schedule_tour","to":"tour_scheduled"},{"signal":"decline","to":"declined"}]},' +
      '{"key":"tour_scheduled","label":"Tour Scheduled","type":"form",' +
        '"fields":[' +
          '{"key":"tour_host_name","label":"Tour Host","type":"Text","required":true,"projection":{"enabled":false}}' +
        '],' +
        '"transitions":[{"signal":"submit_application","to":"application_submitted"},{"signal":"no_show","to":"declined"}]},' +
      '{"key":"application_submitted","label":"Application Submitted","type":"approval",' +
        '"fields":[],' +
        '"transitions":[{"signal":"qualify","to":"intake_qualification"},{"signal":"decline","to":"declined"}]},' +
      '{"key":"intake_qualification","label":"Intake Qualification","type":"ai_driven",' +
        '"advancement":"manual_decision",' +
        '"actions":[' +
          '{"key":"send_followup_email","label":"Send follow-up email","type":"ai_tool",' +
            '"required":true,"dependsOn":[],"sequence":0,' +
            '"config":{"toolKey":"send_email","hitlPolicy":"Approval_Required",' +
            '"parameters":{"systemPrompt":"You are a leasing qualification assistant for Pulse Core Next. Review the conversation history and the applicant context. Draft a follow-up email to the prospect asking for any missing qualifying information: headcount, desired move-in date, and credit qualification documentation. Be professional and concise. Use the send_email tool."}}}' +
        '],' +
        '"transitions":[{"signal":"qualified","to":"credit_review"},{"signal":"disqualified","to":"declined"}]},' +
      '{"key":"credit_review","label":"Credit Review","type":"approval",' +
        '"fields":[' +
          '{"key":"credit_score","label":"Credit Score","type":"Number","required":true,"projection":{"enabled":true,"scope":"WorkflowScoped"}},' +
          '{"key":"credit_review_comments","label":"Reviewer Comments","type":"LongTextArea","required":false,"projection":{"enabled":false}}' +
        '],' +
        '"transitions":[{"signal":"approve_credit","to":"lease_drafted"},{"signal":"decline_credit","to":"declined"},{"signal":"request_more_info","to":"application_submitted"}]},' +
      '{"key":"lease_drafted","label":"Lease Drafted","type":"form",' +
        '"fields":[' +
          '{"key":"lease_term_months","label":"Lease Term (months)","type":"Number","required":true,"projection":{"enabled":true,"scope":"WorkflowScoped"}},' +
          '{"key":"monthly_rent","label":"Monthly Rent","type":"Currency","required":true,"projection":{"enabled":true,"scope":"WorkflowScoped"}}' +
        '],' +
        '"transitions":[{"signal":"sign","to":"signed"},{"signal":"withdraw","to":"declined"}]},' +
      '{"key":"signed","label":"Signed","type":"terminal","fields":[],"transitions":[]},' +
      '{"key":"declined","label":"Declined","type":"terminal","fields":[],"transitions":[]}' +
    ']}';

plse__Workflow_Definition__c def;
List<plse__Workflow_Definition__c> existingDefs = [
    SELECT Id FROM plse__Workflow_Definition__c
    WHERE plse__Workflow_Key__c = :WORKFLOW_KEY LIMIT 1
];
if (!existingDefs.isEmpty()) {
    def = existingDefs[0];
    def.plse__Definition_JSON__c = contractJson;
    def.plse__Status__c = 'Published';
    update def;
    System.debug('### Updated existing Workflow_Definition__c: ' + def.Id);
} else {
    def = new plse__Workflow_Definition__c(
        Name = 'Real Estate Leasing v1',
        plse__Workflow_Key__c = WORKFLOW_KEY,
        plse__Version__c = 1,
        plse__Status__c = 'Published',
        plse__Definition_JSON__c = contractJson,
        plse__Subject_Kinds__c = 'Opportunity',
        plse__Published_By__c = UserInfo.getUserId(),
        plse__Published_Date__c = Datetime.now()
    );
    insert def;
    System.debug('### Created Workflow_Definition__c: ' + def.Id);
}

// ------------------------------------------------------------
// 2. Opportunity
// ------------------------------------------------------------
Opportunity opp;
List<Opportunity> existingOpps = [
    SELECT Id FROM Opportunity WHERE Name = :OPP_NAME LIMIT 1
];
if (!existingOpps.isEmpty()) {
    opp = existingOpps[0];
    System.debug('### Reusing existing Opportunity: ' + opp.Id);
} else {
    opp = new Opportunity(
        Name = OPP_NAME,
        StageName = 'Qualification',
        CloseDate = Date.today().addDays(60),
        Amount = 357000  // 8500 sqft × $42/sqft × 12 months (full year signal)
    );
    insert opp;
    System.debug('### Created Opportunity: ' + opp.Id);
}

// ------------------------------------------------------------
// 3. Workflow_Instance__c at state 'credit_review'
// ------------------------------------------------------------
plse__Workflow_Instance__c inst;
List<plse__Workflow_Instance__c> existingInsts = [
    SELECT Id, plse__Current_State__c FROM plse__Workflow_Instance__c
    WHERE plse__Workflow_Definition__c = :def.Id
      AND plse__Parent_Record_Id__c = :opp.Id
    LIMIT 1
];
if (!existingInsts.isEmpty()) {
    inst = existingInsts[0];
    // Force-reset the state so re-running the seed after demo drift
    // returns the instance to the AI-driven qualification step.
    inst.plse__Current_State__c = 'intake_qualification';
    inst.plse__Status__c = 'Active';
    inst.plse__Pinned_Version__c = 1;
    update inst;
    System.debug('### Reset existing Workflow_Instance__c to intake_qualification: ' + inst.Id);
} else {
    inst = new plse__Workflow_Instance__c(
        plse__Workflow_Definition__c = def.Id,
        plse__Current_State__c = 'intake_qualification',
        plse__Status__c = 'Active',
        plse__Pinned_Version__c = 1,
        plse__Started_Date__c = Datetime.now().addDays(-5),
        plse__Parent_Object_Type__c = 'Opportunity',
        plse__Parent_Record_Id__c = opp.Id,
        plse__Context_JSON__c = '{"applicant_name":"Downtown Law Firm","requested_sqft":8500}'
    );
    insert inst;
    System.debug('### Created Workflow_Instance__c: ' + inst.Id);
}

// ------------------------------------------------------------
// 4. Workflow_Step_Result__c history + Stage_Dwell__c dwell facts
// ------------------------------------------------------------
// Only seed these if the instance has no step results yet.
Integer existingSteps = [
    SELECT COUNT() FROM plse__Workflow_Step_Result__c
    WHERE plse__Workflow_Instance__c = :inst.Id
];
if (existingSteps == 0) {
    Datetime now = Datetime.now();
    Datetime t0 = now.addDays(-5);
    Datetime t1 = now.addDays(-3).addHours(-2);
    Datetime t2 = now.addDays(-1).addHours(-6);

    List<plse__Workflow_Step_Result__c> steps = new List<plse__Workflow_Step_Result__c>{
        new plse__Workflow_Step_Result__c(
            plse__Workflow_Instance__c = inst.Id,
            plse__State_Key__c = 'intake',
            plse__Signal__c = 'schedule_tour',
            plse__Outcome__c = 'Completed',
            plse__Actor_Type__c = 'Human',
            plse__Actor_User__c = UserInfo.getUserId(),
            plse__Started_Date__c = t0,
            plse__Completed_Date__c = t1,
            plse__Values_JSON__c = '{"applicant_name":"Downtown Law Firm","requested_sqft":8500,"intake_notes":"Looking for 5-yr lease, moving from Lexington Ave office"}'
        ),
        new plse__Workflow_Step_Result__c(
            plse__Workflow_Instance__c = inst.Id,
            plse__State_Key__c = 'tour_scheduled',
            plse__Signal__c = 'submit_application',
            plse__Outcome__c = 'Completed',
            plse__Actor_Type__c = 'Human',
            plse__Actor_User__c = UserInfo.getUserId(),
            plse__Started_Date__c = t1,
            plse__Completed_Date__c = t2,
            plse__Values_JSON__c = '{"tour_host_name":"M. Chen"}'
        ),
        new plse__Workflow_Step_Result__c(
            plse__Workflow_Instance__c = inst.Id,
            plse__State_Key__c = 'application_submitted',
            plse__Signal__c = 'qualify',
            plse__Outcome__c = 'Completed',
            plse__Actor_Type__c = 'Human',
            plse__Actor_User__c = UserInfo.getUserId(),
            plse__Started_Date__c = t2,
            plse__Completed_Date__c = now.addHours(-12),
            plse__Values_JSON__c = '{}'
        )
    };
    insert steps;

    // Stage_Dwell__c rows so the SLA heatmap has data. Three closed rows
    // + one open row for the current state (credit_review).
    List<plse__Stage_Dwell__c> dwells = new List<plse__Stage_Dwell__c>{
        new plse__Stage_Dwell__c(
            plse__Workflow_Instance__c = inst.Id,
            plse__Workflow_Key__c = WORKFLOW_KEY,
            plse__Subject_Kind__c = 'Opportunity',
            plse__State_Key__c = 'intake',
            plse__State_Label__c = 'Intake',
            plse__State_Type__c = 'form',
            plse__Entered_At__c = t0,
            plse__Exited_At__c = t1,
            plse__Duration_Seconds__c = Math.round((t1.getTime() - t0.getTime()) / 1000.0),
            plse__Next_State_Key__c = 'tour_scheduled',
            plse__Signal__c = 'schedule_tour',
            plse__Actor_Type__c = 'Human'
        ),
        new plse__Stage_Dwell__c(
            plse__Workflow_Instance__c = inst.Id,
            plse__Workflow_Key__c = WORKFLOW_KEY,
            plse__Subject_Kind__c = 'Opportunity',
            plse__State_Key__c = 'tour_scheduled',
            plse__State_Label__c = 'Tour Scheduled',
            plse__State_Type__c = 'form',
            plse__Entered_At__c = t1,
            plse__Exited_At__c = t2,
            plse__Duration_Seconds__c = Math.round((t2.getTime() - t1.getTime()) / 1000.0),
            plse__Next_State_Key__c = 'application_submitted',
            plse__Signal__c = 'submit_application',
            plse__Actor_Type__c = 'Human'
        ),
        new plse__Stage_Dwell__c(
            plse__Workflow_Instance__c = inst.Id,
            plse__Workflow_Key__c = WORKFLOW_KEY,
            plse__Subject_Kind__c = 'Opportunity',
            plse__State_Key__c = 'application_submitted',
            plse__State_Label__c = 'Application Submitted',
            plse__State_Type__c = 'approval',
            plse__Entered_At__c = t2,
            plse__Exited_At__c = now.addHours(-12),
            plse__Duration_Seconds__c = Math.round((now.addHours(-12).getTime() - t2.getTime()) / 1000.0),
            plse__Next_State_Key__c = 'intake_qualification',
            plse__Signal__c = 'qualify',
            plse__Actor_Type__c = 'Human'
        ),
        new plse__Stage_Dwell__c(
            plse__Workflow_Instance__c = inst.Id,
            plse__Workflow_Key__c = WORKFLOW_KEY,
            plse__Subject_Kind__c = 'Opportunity',
            plse__State_Key__c = 'intake_qualification',
            plse__State_Label__c = 'Intake Qualification',
            plse__State_Type__c = 'ai_driven',
            plse__Entered_At__c = now.addHours(-12),
            plse__Exited_At__c = null,
            plse__Duration_Seconds__c = null,
            plse__Actor_Type__c = 'AI'
        )
    };
    insert dwells;
    System.debug('### Seeded 3 history steps + 4 dwell rows');
}

// ------------------------------------------------------------
// 5. Conversation + turns + extract
// ------------------------------------------------------------
String convExternalId = 'realestate-demo-' + inst.Id;
plse__Conversation__c conv;
List<plse__Conversation__c> existingConvs = [
    SELECT Id FROM plse__Conversation__c
    WHERE plse__External_Source_Id__c = :convExternalId LIMIT 1
];
if (!existingConvs.isEmpty()) {
    conv = existingConvs[0];
    System.debug('### Reusing existing Conversation: ' + conv.Id);
} else {
    conv = new plse__Conversation__c(
        plse__Medium__c = 'Email',
        plse__Subject__c = 'Interest in your Lexington Ave space',
        plse__Summary__c = 'Prospective tenant inquiring about 8,500 sqft space; 5-year lease preferred',
        plse__Participants__c = 'Jordan Matthews (AB Properties); leasing@ourcompany.com',
        plse__Source_Adapter__c = 'email',
        plse__External_Source__c = 'inbound_email',
        plse__External_Source_Id__c = convExternalId,
        plse__Parent_Object_Type__c = 'Opportunity',
        plse__Parent_Record_Id__c = opp.Id,
        plse__Workflow_Instance__c = inst.Id,
        plse__Status__c = 'Extracted'
    );
    insert conv;

    insert new List<plse__Conversation_Turn__c>{
        new plse__Conversation_Turn__c(
            plse__Conversation__c = conv.Id,
            plse__Turn_Index__c = 0,
            plse__Role__c = 'Customer',
            plse__Speaker__c = 'Jordan Matthews',
            plse__Content__c = 'Hi — I am Jordan from AB Properties. We are interested in your 8,500 square-foot space on Lexington Ave. Looking for roughly a five-year lease. Could we schedule a tour next Tuesday afternoon?',
            plse__Timestamp__c = Datetime.now().addDays(-6)
        ),
        new plse__Conversation_Turn__c(
            plse__Conversation__c = conv.Id,
            plse__Turn_Index__c = 1,
            plse__Role__c = 'Agent',
            plse__Speaker__c = 'Leasing Team',
            plse__Content__c = 'Hi Jordan — happy to help. Tuesday 2pm works. Could you share rough headcount and any build-out needs beforehand?',
            plse__Timestamp__c = Datetime.now().addDays(-6).addHours(3)
        ),
        new plse__Conversation_Turn__c(
            plse__Conversation__c = conv.Id,
            plse__Turn_Index__c = 2,
            plse__Role__c = 'Customer',
            plse__Speaker__c = 'Jordan Matthews',
            plse__Content__c = 'About 45 people, private offices along one wall, open floor otherwise. Budget around $42/sqft.',
            plse__Timestamp__c = Datetime.now().addDays(-6).addHours(4)
        )
    };
    System.debug('### Created Conversation with 3 turns');
}

// Pending Extract
Integer extractCount = [
    SELECT COUNT() FROM plse__Conversation_Extract__c
    WHERE plse__Conversation__c = :conv.Id
];
if (extractCount == 0) {
    insert new plse__Conversation_Extract__c(
        plse__Conversation__c = conv.Id,
        plse__Extraction_Profile__c = 'email_default',
        plse__Status__c = 'Pending',
        plse__Facts_JSON__c = '{"applicant_name":"AB Properties","requested_sqft":8500,"lease_term_months":60,"monthly_rent":42}',
        plse__Confidence_JSON__c = '{"applicant_name":0.92,"requested_sqft":0.95,"lease_term_months":0.88,"monthly_rent":0.74}',
        plse__Source_Turn_References__c = '[{"factKey":"applicant_name","turnIndexes":[0]},{"factKey":"requested_sqft","turnIndexes":[0]},{"factKey":"lease_term_months","turnIndexes":[0]},{"factKey":"monthly_rent","turnIndexes":[2]}]',
        plse__Workflow_Instance__c = inst.Id
    );
    System.debug('### Created pending Conversation_Extract__c');
}

// ------------------------------------------------------------
// 6. Pending HITL action (AI proposed a follow-up email at intake_qualification)
// ------------------------------------------------------------
// Upsert the pending action keyed on (phase_key, action_key) — the
// WorkflowInstanceActionTrigger may have already instantiated a skeleton
// row; we populate it with the demo email payload.
List<plse__Workflow_Action__c> existingActions = [
    SELECT Id, plse__Status__c, plse__Action_Key__c
    FROM plse__Workflow_Action__c
    WHERE plse__Workflow_Instance__c = :inst.Id
      AND plse__Phase_Key__c = 'intake_qualification'
      AND plse__Action_Key__c = 'send_followup_email'
    LIMIT 1
];
String demoEmailJson = '{"toAddress":"jordan@abproperties.com","subject":"Additional information needed for your lease application","body":"Hi Jordan — thank you for your interest in the Lexington Ave space. To move forward with qualification, we need a few more details:\\n\\n1. Expected headcount\\n2. Desired move-in date\\n3. Credit qualification documentation\\n\\nPlease reply at your earliest convenience.\\n\\nBest regards,\\nLeasing Team"}';
if (!existingActions.isEmpty()) {
    plse__Workflow_Action__c a = existingActions[0];
    a.plse__Request_JSON__c      = demoEmailJson;
    a.plse__Label__c             = 'Send follow-up email';
    a.plse__Tool_Key__c          = 'send_email';
    a.plse__HITL_Policy__c       = 'Approval_Required';
    a.plse__Required_For_Phase__c = true;
    a.plse__Assigned_User__c     = UserInfo.getUserId();
    if (a.plse__Status__c != 'Executed' && a.plse__Status__c != 'Rejected') {
        a.plse__Status__c = 'Pending';
    }
    update a;
    System.debug('### Updated existing Workflow_Action__c: ' + a.Id);
} else {
    insert new plse__Workflow_Action__c(
        plse__Workflow_Instance__c = inst.Id,
        plse__Action_Key__c       = 'send_followup_email',
        plse__Phase_Key__c        = 'intake_qualification',
        plse__Label__c            = 'Send follow-up email',
        plse__Tool_Key__c         = 'send_email',
        plse__Action_Type__c      = 'AI_Tool_Call',
        plse__HITL_Policy__c      = 'Approval_Required',
        plse__Status__c           = 'Pending',
        plse__Required_For_Phase__c = true,
        plse__Sequence__c         = 0,
        plse__Request_JSON__c     = demoEmailJson,
        plse__Assigned_User__c    = UserInfo.getUserId()
    );
    System.debug('### Created pending Workflow_Action__c');
}

System.debug('### Demo seed complete. Open Pulse Admin Studio OR navigate to the Opportunity "' + OPP_NAME + '" to see the workflow in flight.');
