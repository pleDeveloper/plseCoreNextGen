// Seed Action_Status_Template__mdt records via the Apex Metadata API.
// Source deploy of new CMDT records hits UNKNOWN_EXCEPTION on this org;
// Metadata.Operations.enqueueDeployment works reliably (same pattern as
// scripts/seed-tool-registry.apex and scripts/seed-action-hub-configs.apex).

List<Metadata.CustomMetadata> records = new List<Metadata.CustomMetadata>();

Map<String, Map<String, Object>> templates = new Map<String, Map<String, Object>>{
    'Basic_Approval' => new Map<String, Object>{
        'displayName' => 'Basic Approval',
        'description' => 'Pending → Approved | Rejected. Use for simple human-approval actions.',
        'statuses' => new List<Object>{
            new Map<String, Object>{ 'key' => 'Pending',  'label' => 'Pending',  'order' => 0, 'category' => 'open',              'isInitial' => true },
            new Map<String, Object>{ 'key' => 'Approved', 'label' => 'Approved', 'order' => 1, 'category' => 'terminal_success' },
            new Map<String, Object>{ 'key' => 'Rejected', 'label' => 'Rejected', 'order' => 2, 'category' => 'terminal_failure' }
        }
    },
    'Email_Send' => new Map<String, Object>{
        'displayName' => 'Email Send',
        'description' => 'Drafting → Pending Approval → Sent → Complete. Bounced is a terminal failure.',
        'statuses' => new List<Object>{
            new Map<String, Object>{ 'key' => 'Drafting',         'label' => 'Drafting',         'order' => 0, 'category' => 'open',              'isInitial' => true },
            new Map<String, Object>{ 'key' => 'Pending_Approval', 'label' => 'Pending approval', 'order' => 1, 'category' => 'open' },
            new Map<String, Object>{ 'key' => 'Sent',             'label' => 'Sent',             'order' => 2, 'category' => 'open' },
            new Map<String, Object>{ 'key' => 'Bounced',          'label' => 'Bounced',          'order' => 3, 'category' => 'terminal_failure' },
            new Map<String, Object>{ 'key' => 'Complete',         'label' => 'Complete',         'order' => 4, 'category' => 'terminal_success' }
        }
    },
    'Task' => new Map<String, Object>{
        'displayName' => 'Task',
        'description' => 'Classic Not Started → In Progress → On Hold | Complete lifecycle.',
        'statuses' => new List<Object>{
            new Map<String, Object>{ 'key' => 'Not_Started', 'label' => 'Not started', 'order' => 0, 'category' => 'open',              'isInitial' => true },
            new Map<String, Object>{ 'key' => 'In_Progress','label' => 'In progress',  'order' => 1, 'category' => 'open' },
            new Map<String, Object>{ 'key' => 'On_Hold',    'label' => 'On hold',      'order' => 2, 'category' => 'blocked' },
            new Map<String, Object>{ 'key' => 'Complete',   'label' => 'Complete',     'order' => 3, 'category' => 'terminal_success' }
        }
    },
    'Field_Capture' => new Map<String, Object>{
        'displayName' => 'Field Capture',
        'description' => 'Tracks how much of a form has been filled: Empty → Partial → Complete.',
        'statuses' => new List<Object>{
            new Map<String, Object>{ 'key' => 'Empty',    'label' => 'Empty',    'order' => 0, 'category' => 'open',              'isInitial' => true },
            new Map<String, Object>{ 'key' => 'Partial',  'label' => 'Partial',  'order' => 1, 'category' => 'open' },
            new Map<String, Object>{ 'key' => 'Complete', 'label' => 'Complete', 'order' => 2, 'category' => 'terminal_success' }
        }
    }
};

for (String devName : templates.keySet()) {
    Map<String, Object> t = templates.get(devName);
    Metadata.CustomMetadata cm = new Metadata.CustomMetadata();
    cm.fullName = 'plse__Action_Status_Template.' + devName;
    cm.label    = (String) t.get('displayName');

    Metadata.CustomMetadataValue keyVal = new Metadata.CustomMetadataValue();
    keyVal.field = 'plse__Template_Key__c';
    keyVal.value = devName;
    cm.values.add(keyVal);

    Metadata.CustomMetadataValue nameVal = new Metadata.CustomMetadataValue();
    nameVal.field = 'plse__Display_Name__c';
    nameVal.value = (String) t.get('displayName');
    cm.values.add(nameVal);

    Metadata.CustomMetadataValue descVal = new Metadata.CustomMetadataValue();
    descVal.field = 'plse__Description__c';
    descVal.value = (String) t.get('description');
    cm.values.add(descVal);

    Metadata.CustomMetadataValue statusesVal = new Metadata.CustomMetadataValue();
    statusesVal.field = 'plse__Statuses_JSON__c';
    statusesVal.value = JSON.serialize(t.get('statuses'));
    cm.values.add(statusesVal);

    records.add(cm);
}

Metadata.DeployContainer container = new Metadata.DeployContainer();
for (Metadata.CustomMetadata cm : records) container.addMetadata(cm);
Id jobId = Metadata.Operations.enqueueDeployment(container, null);
System.debug('### Enqueued Action_Status_Template deploy: ' + jobId + ' (records=' + records.size() + ')');
