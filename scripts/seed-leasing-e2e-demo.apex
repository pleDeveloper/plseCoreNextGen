// ============================================================
// seed-leasing-e2e-demo.apex
// ============================================================
// Full end-to-end Commercial Lease Application demo.
//
//   1. Idempotent teardown of prior demo data.
//   2. Publishes / updates the `real_estate_leasing_v1` workflow with a
//      richer 8-phase contract (action-level status machines, agent
//      enabled on the qualification phase).
//   3. Creates the demo Account + Contact ("Hawthorne & Sterling LLP" /
//      "Marcus Chen").
//   4. Simulates an inbound email — PulseInboundEmailHandler routes it
//      through InboundRecordRouter, creating a fresh Opportunity and
//      starting the workflow instance automatically.
//   5. Advances past the inquiry form into the qualification phase so the
//      agent has work to do.
//   6. Seeds one Ask_User decision so the field-question pill lights up.
//   7. (Agent kick is intentionally NOT run here — anonymous-Apex DML
//      blocks the Anthropic callout in the same transaction. Click
//      "Kick agent" on the record page in Lightning.)
//
// Run with:
//   sf apex run -o pulse-core-next-dev -f scripts/seed-leasing-e2e-demo.apex

// ============================================================
// CONSTANTS
// ============================================================
final String WORKFLOW_KEY    = 'real_estate_leasing_v1';
final String ACCOUNT_NAME    = 'Hawthorne & Sterling LLP';
final String CONTACT_FIRST   = 'Marcus';
final String CONTACT_LAST    = 'Chen';
final String CONTACT_EMAIL   = 'marcus.chen@hawthorne-sterling-demo.example';
final String INBOUND_SUBJECT = 'Leasing inquiry — 8,500 sqft downtown';
final String INBOUND_BODY    =
    'Hi Pulse team,\n\n' +
    'We are relocating from our current Lexington Ave office and are looking\n' +
    'to lease approximately 8,500 sqft of Class A office space in the\n' +
    'downtown financial district. Ideal move-in is mid-next quarter.\n\n' +
    'Could you share availability and schedule a tour?\n\n' +
    'Best,\n' +
    'Marcus Chen\n' +
    'Managing Partner, Hawthorne & Sterling LLP\n' +
    '(212) 555-0137';

// ============================================================
// 1. CONTRACT — Commercial Lease Application v1
// ============================================================
// Built as a Map tree then JSON.serialize'd so the structure is legible.

// Reusable status machines -----------------------------------

List<Object> STATUS_EMAIL = new List<Object>{
    new Map<String,Object>{ 'key'=>'Drafting','label'=>'Drafting','order'=>0,'category'=>'open','isInitial'=>true },
    new Map<String,Object>{ 'key'=>'Pending_Approval','label'=>'Pending approval','order'=>1,'category'=>'open' },
    new Map<String,Object>{ 'key'=>'Sent','label'=>'Sent','order'=>2,'category'=>'open' },
    new Map<String,Object>{ 'key'=>'Bounced','label'=>'Bounced','order'=>3,'category'=>'terminal_failure' },
    new Map<String,Object>{ 'key'=>'Complete','label'=>'Complete','order'=>4,'category'=>'terminal_success' }
};
List<Object> STATUS_FIELD_CAPTURE = new List<Object>{
    new Map<String,Object>{ 'key'=>'Empty','label'=>'Empty','order'=>0,'category'=>'open','isInitial'=>true },
    new Map<String,Object>{ 'key'=>'Partial','label'=>'Partial','order'=>1,'category'=>'open' },
    new Map<String,Object>{ 'key'=>'Complete','label'=>'Complete','order'=>2,'category'=>'terminal_success' }
};
List<Object> STATUS_APPROVAL = new List<Object>{
    new Map<String,Object>{ 'key'=>'Pending','label'=>'Pending','order'=>0,'category'=>'open','isInitial'=>true },
    new Map<String,Object>{ 'key'=>'Approved','label'=>'Approved','order'=>1,'category'=>'terminal_success' },
    new Map<String,Object>{ 'key'=>'Rejected','label'=>'Rejected','order'=>2,'category'=>'terminal_failure' }
};
List<Object> STATUS_TASK = new List<Object>{
    new Map<String,Object>{ 'key'=>'Not_Started','label'=>'Not started','order'=>0,'category'=>'open','isInitial'=>true },
    new Map<String,Object>{ 'key'=>'In_Progress','label'=>'In progress','order'=>1,'category'=>'open' },
    new Map<String,Object>{ 'key'=>'On_Hold','label'=>'On hold','order'=>2,'category'=>'blocked' },
    new Map<String,Object>{ 'key'=>'Complete','label'=>'Complete','order'=>3,'category'=>'terminal_success' }
};

// Phase builders ---------------------------------------------

Map<String,Object> inquiry = new Map<String,Object>{
    'key' => 'inquiry',
    'label' => 'Inquiry Received',
    'type' => 'form',
    'fields' => new List<Object>{
        new Map<String,Object>{ 'key'=>'applicant_name','label'=>'Primary Contact','type'=>'Text','required'=>true,'projection'=>new Map<String,Object>{'enabled'=>true,'scope'=>'WorkflowScoped'} },
        new Map<String,Object>{ 'key'=>'company_name','label'=>'Company','type'=>'Text','required'=>true,'projection'=>new Map<String,Object>{'enabled'=>true,'scope'=>'WorkflowScoped'} },
        new Map<String,Object>{ 'key'=>'applicant_email','label'=>'Contact Email','type'=>'Text','required'=>false,'projection'=>new Map<String,Object>{'enabled'=>false} },
        new Map<String,Object>{ 'key'=>'requested_sqft','label'=>'Requested Sqft','type'=>'Number','required'=>true,'projection'=>new Map<String,Object>{'enabled'=>true,'scope'=>'WorkflowScoped'} },
        new Map<String,Object>{ 'key'=>'desired_move_in','label'=>'Desired Move-in Date','type'=>'Date','required'=>false,'projection'=>new Map<String,Object>{'enabled'=>false} },
        new Map<String,Object>{ 'key'=>'inquiry_notes','label'=>'Notes','type'=>'LongTextArea','required'=>false,'projection'=>new Map<String,Object>{'enabled'=>false} }
    },
    'transitions' => new List<Object>{
        new Map<String,Object>{ 'signal'=>'submit','to'=>'qualification' },
        new Map<String,Object>{ 'signal'=>'decline','to'=>'declined' }
    }
};

Map<String,Object> qualification = new Map<String,Object>{
    'key' => 'qualification',
    'label' => 'Qualification',
    'type' => 'ai_driven',
    'advancement' => 'manual_decision',
    'agent' => new Map<String,Object>{
        'enabled' => true,
        'persona' => 'Harper',
        'autonomy' => 'Act_With_Approval',
        'systemPrompt' =>
            'You are Harper, a commercial leasing assistant for Pulse. ' +
            'The applicant has submitted an inquiry. Your job is to (a) ' +
            'review context, (b) ask for any missing qualifying information ' +
            '(desired_move_in, company details), (c) propose a follow-up ' +
            'email that invites the applicant to schedule a property tour. ' +
            'Be concise and professional. Use the send_email tool for outbound ' +
            'emails (Approval_Required policy will gate on human approval).'
    },
    'actions' => new List<Object>{
        new Map<String,Object>{
            'key'=>'ask_missing_info', 'label'=>'Ask for missing information',
            'type'=>'ai_tool', 'required'=>false, 'sequence'=>0,
            'dependsOn' => new List<Object>{},
            'statuses' => STATUS_FIELD_CAPTURE, 'initialStatusKey' => 'Empty',
            'config' => new Map<String,Object>{
                'toolKey' => 'ask_user', 'hitlPolicy' => 'Autonomous',
                'parameters' => new Map<String,Object>{
                    'systemPrompt' =>
                        'Check the inquiry context. If desired_move_in or contact ' +
                        'phone is missing, ask the applicant for it via a field ' +
                        'question pill on the form.'
                }
            }
        },
        new Map<String,Object>{
            'key'=>'send_tour_invite_email', 'label'=>'Send tour invitation email',
            'type'=>'ai_tool', 'required'=>true, 'sequence'=>1,
            'dependsOn' => new List<Object>{},
            'statuses' => STATUS_EMAIL, 'initialStatusKey' => 'Drafting',
            'config' => new Map<String,Object>{
                'toolKey' => 'send_email', 'hitlPolicy' => 'Approval_Required',
                'parameters' => new Map<String,Object>{
                    'systemPrompt' =>
                        'Draft a warm, professional email inviting the applicant ' +
                        'to a property tour. Reference their requested_sqft and ' +
                        'proposed move-in date. Offer 2–3 time windows in the ' +
                        'next 10 business days.'
                }
            }
        }
    },
    'transitions' => new List<Object>{
        new Map<String,Object>{ 'signal'=>'schedule_tour','to'=>'tour_scheduled' },
        new Map<String,Object>{ 'signal'=>'disqualify','to'=>'declined' }
    }
};

Map<String,Object> tourScheduled = new Map<String,Object>{
    'key' => 'tour_scheduled',
    'label' => 'Tour Scheduled',
    'type' => 'form',
    'fields' => new List<Object>{
        new Map<String,Object>{ 'key'=>'tour_date','label'=>'Tour Date','type'=>'DateTime','required'=>true,'projection'=>new Map<String,Object>{'enabled'=>true,'scope'=>'WorkflowScoped'} },
        new Map<String,Object>{ 'key'=>'tour_host_name','label'=>'Tour Host','type'=>'Text','required'=>true,'projection'=>new Map<String,Object>{'enabled'=>false} }
    },
    'actions' => new List<Object>{
        new Map<String,Object>{
            'key'=>'send_tour_confirmation', 'label'=>'Send tour confirmation email',
            'type'=>'ai_tool', 'required'=>true, 'sequence'=>0,
            'dependsOn' => new List<Object>{},
            'statuses' => STATUS_EMAIL, 'initialStatusKey' => 'Drafting',
            'config' => new Map<String,Object>{
                'toolKey' => 'send_email', 'hitlPolicy' => 'Approval_Required',
                'parameters' => new Map<String,Object>{
                    'systemPrompt' => 'Send a tour confirmation email with date/time, address, and parking instructions.'
                }
            }
        }
    },
    'transitions' => new List<Object>{
        new Map<String,Object>{ 'signal'=>'tour_complete','to'=>'application_submitted' },
        new Map<String,Object>{ 'signal'=>'no_show','to'=>'declined' }
    }
};

Map<String,Object> applicationSubmitted = new Map<String,Object>{
    'key' => 'application_submitted',
    'label' => 'Application Submitted',
    'type' => 'approval',
    'fields' => new List<Object>{
        new Map<String,Object>{ 'key'=>'application_received','label'=>'Application received','type'=>'Checkbox','required'=>true,'projection'=>new Map<String,Object>{'enabled'=>false} },
        new Map<String,Object>{ 'key'=>'financial_docs_received','label'=>'Financial docs received','type'=>'Checkbox','required'=>true,'projection'=>new Map<String,Object>{'enabled'=>false} },
        new Map<String,Object>{ 'key'=>'insurance_cert_received','label'=>'Insurance cert received','type'=>'Checkbox','required'=>false,'projection'=>new Map<String,Object>{'enabled'=>false} }
    },
    'actions' => new List<Object>{
        new Map<String,Object>{
            'key'=>'request_application_email', 'label'=>'Request full application email',
            'type'=>'ai_tool', 'required'=>true, 'sequence'=>0,
            'dependsOn' => new List<Object>{},
            'statuses' => STATUS_EMAIL, 'initialStatusKey' => 'Drafting',
            'config' => new Map<String,Object>{
                'toolKey' => 'send_email', 'hitlPolicy' => 'Approval_Required',
                'parameters' => new Map<String,Object>{ 'systemPrompt' => 'Email the applicant a checklist of the application, financials, and insurance COI with the secure upload link.' }
            }
        },
        new Map<String,Object>{
            'key'=>'verify_documents', 'label'=>'Verify received documents',
            'type'=>'ai_tool', 'required'=>true, 'sequence'=>1,
            'dependsOn' => new List<Object>{ 'request_application_email' },
            'statuses' => STATUS_APPROVAL, 'initialStatusKey' => 'Pending',
            'config' => new Map<String,Object>{
                'toolKey' => 'update_record', 'hitlPolicy' => 'Review_After',
                'parameters' => new Map<String,Object>{ 'systemPrompt' => 'Mark the three checkbox fields true once each document is received.' }
            }
        }
    },
    'transitions' => new List<Object>{
        new Map<String,Object>{ 'signal'=>'approve','to'=>'credit_review' },
        new Map<String,Object>{ 'signal'=>'reject','to'=>'declined' }
    }
};

Map<String,Object> creditReview = new Map<String,Object>{
    'key' => 'credit_review',
    'label' => 'Credit Review',
    'type' => 'approval',
    'fields' => new List<Object>{
        new Map<String,Object>{ 'key'=>'credit_score','label'=>'Credit Score','type'=>'Number','required'=>true,'projection'=>new Map<String,Object>{'enabled'=>true,'scope'=>'WorkflowScoped'} },
        new Map<String,Object>{ 'key'=>'credit_review_comments','label'=>'Reviewer Comments','type'=>'LongTextArea','required'=>false,'projection'=>new Map<String,Object>{'enabled'=>false} }
    },
    'actions' => new List<Object>{
        new Map<String,Object>{
            'key'=>'run_credit_check', 'label'=>'Run credit check',
            'type'=>'ai_tool', 'required'=>true, 'sequence'=>0,
            'dependsOn' => new List<Object>{},
            'statuses' => STATUS_TASK, 'initialStatusKey' => 'Not_Started',
            'config' => new Map<String,Object>{
                'toolKey' => 'external_api', 'hitlPolicy' => 'Review_After',
                'parameters' => new Map<String,Object>{ 'systemPrompt' => 'Call the credit bureau API with the applicant\'s company EIN and record the returned score on the credit_score field.' }
            }
        },
        new Map<String,Object>{
            'key'=>'reviewer_sign_off', 'label'=>'Reviewer sign-off',
            'type'=>'manual', 'required'=>true, 'sequence'=>1,
            'dependsOn' => new List<Object>{ 'run_credit_check' },
            'statuses' => STATUS_APPROVAL, 'initialStatusKey' => 'Pending'
        }
    },
    'transitions' => new List<Object>{
        new Map<String,Object>{ 'signal'=>'approve_credit','to'=>'lease_drafted' },
        new Map<String,Object>{ 'signal'=>'decline_credit','to'=>'declined' }
    }
};

Map<String,Object> leaseDrafted = new Map<String,Object>{
    'key' => 'lease_drafted',
    'label' => 'Lease Drafted',
    'type' => 'form',
    'fields' => new List<Object>{
        new Map<String,Object>{ 'key'=>'lease_term_months','label'=>'Lease Term (months)','type'=>'Number','required'=>true,'projection'=>new Map<String,Object>{'enabled'=>true,'scope'=>'WorkflowScoped'} },
        new Map<String,Object>{ 'key'=>'monthly_rent','label'=>'Monthly Rent','type'=>'Currency','required'=>true,'projection'=>new Map<String,Object>{'enabled'=>true,'scope'=>'WorkflowScoped'} },
        new Map<String,Object>{ 'key'=>'security_deposit','label'=>'Security Deposit','type'=>'Currency','required'=>true,'projection'=>new Map<String,Object>{'enabled'=>false} },
        new Map<String,Object>{ 'key'=>'lease_start_date','label'=>'Lease Start Date','type'=>'Date','required'=>true,'projection'=>new Map<String,Object>{'enabled'=>true,'scope'=>'WorkflowScoped'} }
    },
    'actions' => new List<Object>{
        new Map<String,Object>{
            'key'=>'send_lease_draft', 'label'=>'Send lease draft for signature',
            'type'=>'ai_tool', 'required'=>true, 'sequence'=>0,
            'dependsOn' => new List<Object>{},
            'statuses' => STATUS_EMAIL, 'initialStatusKey' => 'Drafting',
            'config' => new Map<String,Object>{
                'toolKey' => 'send_email', 'hitlPolicy' => 'Approval_Required',
                'parameters' => new Map<String,Object>{ 'systemPrompt' => 'Email the lease PDF with e-sign link, summarizing term/rent/deposit.' }
            }
        }
    },
    'transitions' => new List<Object>{
        new Map<String,Object>{ 'signal'=>'sign','to'=>'signed' },
        new Map<String,Object>{ 'signal'=>'withdraw','to'=>'declined' }
    }
};

Map<String,Object> signed = new Map<String,Object>{
    'key' => 'signed', 'label' => 'Signed', 'type' => 'terminal',
    'fields' => new List<Object>{}, 'transitions' => new List<Object>{}
};
Map<String,Object> declined = new Map<String,Object>{
    'key' => 'declined', 'label' => 'Declined', 'type' => 'terminal',
    'fields' => new List<Object>{}, 'transitions' => new List<Object>{}
};

Map<String,Object> contract = new Map<String,Object>{
    'schema' => 'pulse.workflow.v1',
    'workflowKey' => WORKFLOW_KEY,
    'version' => 1,
    'name' => 'Commercial Lease Application',
    'subjectKinds' => new List<String>{ 'Opportunity' },
    'agent' => new Map<String,Object>{
        'enabled' => true,
        'persona' => 'Harper',
        'autonomy' => 'Act_With_Approval',
        'systemPrompt' => 'You are Harper, a commercial leasing assistant. Help the leasing team qualify applicants, schedule tours, and shepherd applications through to signed leases. Always propose concrete next steps.'
    },
    'states' => new List<Object>{
        inquiry, qualification, tourScheduled, applicationSubmitted,
        creditReview, leaseDrafted, signed, declined
    }
};

String contractJson = JSON.serialize(contract);
System.debug('### Contract JSON length: ' + contractJson.length());

// ============================================================
// 2. TEARDOWN
// ============================================================
System.debug('### === Teardown ===');

// Find any demo Opportunity(s) pointing at this contact email
List<Contact> priorContacts = [SELECT Id FROM Contact WHERE Email = :CONTACT_EMAIL];
Set<Id> priorContactIds = new Map<Id, Contact>(priorContacts).keySet();

List<Id> priorOppIds = new List<Id>();
if (!priorContactIds.isEmpty()) {
    for (OpportunityContactRole r : [
        SELECT OpportunityId FROM OpportunityContactRole WHERE ContactId IN :priorContactIds
    ]) {
        priorOppIds.add(r.OpportunityId);
    }
}
// Also pick up bare opps created from email defaults that reference the email in Name
for (Opportunity o : [SELECT Id FROM Opportunity WHERE Name LIKE '%marcus.chen@hawthorne-sterling-demo.example%']) {
    priorOppIds.add(o.Id);
}

Set<Id> instIds = new Set<Id>();
for (plse__Workflow_Instance__c i : [
    SELECT Id FROM plse__Workflow_Instance__c WHERE plse__Parent_Record_Id__c IN :priorOppIds
]) { instIds.add(i.Id); }

if (!instIds.isEmpty()) {
    delete [SELECT Id FROM plse__Agent_Decision__c WHERE plse__Workflow_Instance__c IN :instIds];
    delete [SELECT Id FROM plse__Agent_Thread__c   WHERE plse__Workflow_Instance__c IN :instIds];
    delete [SELECT Id FROM plse__Workflow_Event__c WHERE plse__Workflow_Instance__c IN :instIds];
    delete [SELECT Id FROM plse__Workflow_Action__c WHERE plse__Workflow_Instance__c IN :instIds];
    delete [SELECT Id FROM plse__Workflow_Step_Result__c WHERE plse__Workflow_Instance__c IN :instIds];
    delete [SELECT Id FROM plse__Stage_Dwell__c WHERE plse__Workflow_Instance__c IN :instIds];
    delete [SELECT Id FROM plse__Conversation_Turn__c WHERE plse__Conversation__c IN (
        SELECT Id FROM plse__Conversation__c WHERE plse__Workflow_Instance__c IN :instIds
    )];
    delete [SELECT Id FROM plse__Conversation_Extract__c WHERE plse__Conversation__c IN (
        SELECT Id FROM plse__Conversation__c WHERE plse__Workflow_Instance__c IN :instIds
    )];
    delete [SELECT Id FROM plse__Conversation__c WHERE plse__Workflow_Instance__c IN :instIds];
    delete [SELECT Id FROM plse__Workflow_Instance__c WHERE Id IN :instIds];
}

if (!priorOppIds.isEmpty()) {
    delete [SELECT Id FROM Opportunity WHERE Id IN :priorOppIds];
}

// Delete prior demo Contact + Account
if (!priorContacts.isEmpty()) {
    delete priorContacts;
}
delete [SELECT Id FROM Account WHERE Name = :ACCOUNT_NAME];

System.debug('### Teardown done.');

// ============================================================
// 3. UPSERT WORKFLOW DEFINITION
// ============================================================
plse__Workflow_Definition__c def;
List<plse__Workflow_Definition__c> existingDefs = [
    SELECT Id FROM plse__Workflow_Definition__c WHERE plse__Workflow_Key__c = :WORKFLOW_KEY LIMIT 1
];
if (!existingDefs.isEmpty()) {
    def = existingDefs[0];
    def.plse__Definition_JSON__c = contractJson;
    def.plse__Status__c = 'Published';
    update def;
    System.debug('### Updated Workflow_Definition__c: ' + def.Id);
} else {
    def = new plse__Workflow_Definition__c(
        Name = 'Commercial Lease Application v1',
        plse__Workflow_Key__c     = WORKFLOW_KEY,
        plse__Version__c          = 1,
        plse__Status__c           = 'Published',
        plse__Definition_JSON__c  = contractJson,
        plse__Subject_Kinds__c    = 'Opportunity',
        plse__Published_By__c     = UserInfo.getUserId(),
        plse__Published_Date__c   = Datetime.now()
    );
    insert def;
    System.debug('### Created Workflow_Definition__c: ' + def.Id);
}

// ============================================================
// 4. CREATE ACCOUNT + CONTACT
// ============================================================
Account acct = new Account(Name = ACCOUNT_NAME);
insert acct;
Contact contact = new Contact(
    FirstName = CONTACT_FIRST,
    LastName  = CONTACT_LAST,
    Email     = CONTACT_EMAIL,
    AccountId = acct.Id,
    Phone     = '+1 212 555 0137'
);
insert contact;
System.debug('### Created Contact ' + contact.Id + ' on Account ' + acct.Id);

// ============================================================
// 5. SIMULATE INBOUND EMAIL → routes to Opportunity + starts workflow
// ============================================================
Messaging.InboundEmail email = new Messaging.InboundEmail();
email.fromAddress   = CONTACT_EMAIL;
email.fromName      = CONTACT_FIRST + ' ' + CONTACT_LAST;
email.subject       = INBOUND_SUBJECT;
email.plainTextBody = INBOUND_BODY;
email.toAddresses   = new List<String>{ 'leasing@pulseplatform.example' };
Messaging.InboundEnvelope env = new Messaging.InboundEnvelope();
env.fromAddress = CONTACT_EMAIL;
env.toAddress   = 'leasing@pulseplatform.example';

Messaging.InboundEmailResult res = new plse.PulseInboundEmailHandler().handleInboundEmail(email, env);
System.debug('### Inbound handler result: ' + res.success);

// Locate the Opportunity and Workflow_Instance__c that the handler created.
List<OpportunityContactRole> roles = [
    SELECT OpportunityId FROM OpportunityContactRole WHERE ContactId = :contact.Id
    ORDER BY CreatedDate DESC LIMIT 1
];
Id oppId = null;
if (!roles.isEmpty()) {
    oppId = roles[0].OpportunityId;
} else {
    // Router falls back to creating a bare Opportunity if no OCR exists —
    // match on the Name template "New inquiry from {senderEmail}".
    List<Opportunity> byName = [SELECT Id FROM Opportunity WHERE Name LIKE :('%' + CONTACT_EMAIL + '%') ORDER BY CreatedDate DESC LIMIT 1];
    if (!byName.isEmpty()) oppId = byName[0].Id;
}
System.debug('### Routed Opportunity: ' + oppId);

List<plse__Workflow_Instance__c> newInsts = [
    SELECT Id, plse__Current_State__c FROM plse__Workflow_Instance__c
    WHERE plse__Parent_Record_Id__c = :String.valueOf(oppId)
    ORDER BY CreatedDate DESC LIMIT 1
];
if (newInsts.isEmpty()) {
    System.debug('### ERROR — no Workflow_Instance__c was created by the inbound handler.');
    return;
}
plse__Workflow_Instance__c inst = newInsts[0];
System.debug('### Workflow_Instance__c: ' + inst.Id + ' @ ' + inst.plse__Current_State__c);

// Prefill context so the form isn't completely empty for the demo viewer.
inst.plse__Context_JSON__c = JSON.serialize(new Map<String,Object>{
    'applicant_name'   => CONTACT_FIRST + ' ' + CONTACT_LAST,
    'company_name'     => ACCOUNT_NAME,
    'applicant_email'  => CONTACT_EMAIL,
    'requested_sqft'   => 8500,
    'inquiry_notes'    => 'Relocating from Lexington Ave office, Class A preferred.'
});
update inst;

// Advance past the inquiry form to the qualification phase so the agent
// actually has work to do when we kick it. (Fields are prefilled above,
// so this transition is legitimate.)
try {
    plse.PulseRuntimeController.AdvanceView av =
        plse.PulseRuntimeController.advanceInstance(inst.Id, 'submit', null, null);
    if (av.success) {
        System.debug('### Advanced instance to qualification (' + av.fromStateKey + '→' + av.toStateKey + ').');
    } else {
        System.debug('### !!! advance returned success=false: ' + av.error);
    }
} catch (Exception e) {
    System.debug('### advance threw: ' + e.getMessage());
}

// ============================================================
// 6. (Agent kick happens from the UI — clicking "Kick agent" on the
//     record page runs in its own clean transaction. Anonymous-Apex
//     DML done above this line blocks the Anthropic callout if we
//     tried to run it here.)
// ============================================================

// ============================================================
// 7. SEED A VISIBLE FIELD-QUESTION PILL
// ============================================================
// Creates the Agent_Thread__c up front (via the orchestrator helper so
// the persona/autonomy/system-prompt fields snapshot from the contract)
// and plants a pending Ask_User decision so the field-question pill on
// the form renders deterministically, even before the admin clicks
// "Kick agent".
plse__Agent_Thread__c threadRow =
    plse.PulseAgentOrchestrator.getOrCreateThread(inst.Id);
if (threadRow != null) {
    Id threadId = threadRow.Id;
    List<plse__Agent_Decision__c> existingAsk = [
        SELECT Id FROM plse__Agent_Decision__c
        WHERE plse__Workflow_Instance__c = :inst.Id
          AND plse__Decision_Type__c = 'Ask_User'
          AND plse__Status__c = 'Pending_User'
        LIMIT 1
    ];
    if (existingAsk.isEmpty()) {
        insert new plse__Agent_Decision__c(
            plse__Agent_Thread__c       = threadId,
            plse__Workflow_Instance__c  = inst.Id,
            plse__Decision_Type__c      = 'Ask_User',
            plse__Status__c             = 'Pending_User',
            plse__Phase_Key__c          = inst.plse__Current_State__c,
            plse__Rationale__c          = 'Need a move-in target to prioritize tour slots.',
            plse__Question_JSON__c      = JSON.serialize(new Map<String,Object>{
                'fieldKey'  => 'desired_move_in',
                'prompt'    => 'When does Hawthorne & Sterling need to be moved in by?',
                'inputType' => 'Date'
            })
        );
        System.debug('### Seeded Ask_User decision for desired_move_in pill.');
    }
}

// ============================================================
// 8. SUMMARY
// ============================================================
System.debug('### ==============================================');
System.debug('### DEMO READY');
System.debug('### Account:          ' + acct.Id  + ' — ' + ACCOUNT_NAME);
System.debug('### Contact:          ' + contact.Id + ' — ' + CONTACT_FIRST + ' ' + CONTACT_LAST);
System.debug('### Opportunity:      ' + oppId);
System.debug('### WorkflowInstance: ' + inst.Id);
System.debug('### Workflow key:     ' + WORKFLOW_KEY);
System.debug('### ==============================================');
System.debug('### NEXT: open the Opportunity record page in Lightning. You should see:');
System.debug('###   1. Stage_Status__c badge (if the engine has set it)');
System.debug('###   2. Agent status rail + decision queue at top (agent enabled)');
System.debug('###   3. A field-question pill next to "Desired Move-in Date" (inquiry form)');
System.debug('###   4. Journey card showing qualification phase actions with status machines');
