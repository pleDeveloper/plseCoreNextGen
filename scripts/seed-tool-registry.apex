// Seed Workflow_Tool_Registration__mdt records via Metadata API
// Needed because source deploy of CustomMetadata records hits UNKNOWN_EXCEPTION
// on this scratch org — likely a platform quirk with packaged namespace + CMDT.

List<Metadata.CustomMetadata> records = new List<Metadata.CustomMetadata>();

Map<String, Map<String, Object>> tools = new Map<String, Map<String, Object>>{
    'Send_Email' => new Map<String, Object>{
        'label' => 'Send Email',
        'toolKey' => 'send_email',
        'apexClass' => 'plse.PulseEmailTool',
        'description' => 'Sends a Salesforce email via Messaging.SingleEmailMessage. Default HITL policy is Approval_Required so agent-drafted emails route through the Action Hub before they go out.'
    },
    'Update_Record' => new Map<String, Object>{
        'label' => 'Update Record',
        'toolKey' => 'update_record',
        'apexClass' => 'plse.PulseRecordUpdateTool',
        'description' => 'Updates a single Salesforce record. Fields are allowlisted per object via fieldAllowlist; reviewers approve the exact field set before the update lands.'
    },
    'External_Api' => new Map<String, Object>{
        'label' => 'External API call',
        'toolKey' => 'external_api',
        'apexClass' => 'plse.PulseExternalApiTool',
        'description' => 'Generic HTTP callout via a Named Credential. Default policy forces HITL approval because outbound calls often hit external systems with side effects.'
    }
};

for (String devName : tools.keySet()) {
    Map<String, Object> t = tools.get(devName);

    Metadata.CustomMetadata cm = new Metadata.CustomMetadata();
    cm.fullName = 'plse__Workflow_Tool_Registration.' + devName;
    cm.label = (String) t.get('label');

    Metadata.CustomMetadataValue vToolKey = new Metadata.CustomMetadataValue();
    vToolKey.field = 'plse__Tool_Key__c';
    vToolKey.value = (String) t.get('toolKey');
    cm.values.add(vToolKey);

    Metadata.CustomMetadataValue vApex = new Metadata.CustomMetadataValue();
    vApex.field = 'plse__Apex_Class__c';
    vApex.value = (String) t.get('apexClass');
    cm.values.add(vApex);

    Metadata.CustomMetadataValue vHitl = new Metadata.CustomMetadataValue();
    vHitl.field = 'plse__Default_HITL_Policy__c';
    vHitl.value = 'Approval_Required';
    cm.values.add(vHitl);

    Metadata.CustomMetadataValue vDesc = new Metadata.CustomMetadataValue();
    vDesc.field = 'plse__Description__c';
    vDesc.value = (String) t.get('description');
    cm.values.add(vDesc);

    Metadata.CustomMetadataValue vActive = new Metadata.CustomMetadataValue();
    vActive.field = 'plse__Active__c';
    vActive.value = true;
    cm.values.add(vActive);

    records.add(cm);
}

Metadata.DeployContainer container = new Metadata.DeployContainer();
for (Metadata.CustomMetadata cm : records) {
    container.addMetadata(cm);
}

Id jobId = Metadata.Operations.enqueueDeployment(container, null);
System.debug('Enqueued CMDT deploy job: ' + jobId);
System.debug('Records queued: ' + records.size());
