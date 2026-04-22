// Seed Action_Hub_Column_Config__mdt records via Metadata API (same pattern
// as scripts/seed-tool-registry.apex). Source deploy hits UNKNOWN_EXCEPTION
// for new CMDT records on this org; this path is reliable.

List<Metadata.CustomMetadata> records = new List<Metadata.CustomMetadata>();

// Opportunity columns
Metadata.CustomMetadata opp = new Metadata.CustomMetadata();
opp.fullName = 'plse__Action_Hub_Column_Config.Opportunity_Columns';
opp.label = 'Opportunity Columns';
Metadata.CustomMetadataValue oppKey = new Metadata.CustomMetadataValue();
oppKey.field = 'plse__Config_Key__c'; oppKey.value = 'Opportunity_Columns';
opp.values.add(oppKey);
Metadata.CustomMetadataValue oppTarget = new Metadata.CustomMetadataValue();
oppTarget.field = 'plse__Target_Object__c'; oppTarget.value = 'Opportunity';
opp.values.add(oppTarget);
Metadata.CustomMetadataValue oppCols = new Metadata.CustomMetadataValue();
oppCols.field = 'plse__Columns_JSON__c';
oppCols.value = '[{"field":"Name","label":"Name"},{"field":"Amount","label":"Amount"},{"field":"StageName","label":"Stage"},{"field":"CloseDate","label":"Close Date"}]';
opp.values.add(oppCols);
Metadata.CustomMetadataValue oppActive = new Metadata.CustomMetadataValue();
oppActive.field = 'plse__Active__c'; oppActive.value = true;
opp.values.add(oppActive);
records.add(opp);

// Default fallback
Metadata.CustomMetadata def = new Metadata.CustomMetadata();
def.fullName = 'plse__Action_Hub_Column_Config.Default_Fallback';
def.label = 'Default Fallback';
Metadata.CustomMetadataValue defKey = new Metadata.CustomMetadataValue();
defKey.field = 'plse__Config_Key__c'; defKey.value = 'Default_Fallback';
def.values.add(defKey);
Metadata.CustomMetadataValue defTarget = new Metadata.CustomMetadataValue();
defTarget.field = 'plse__Target_Object__c'; defTarget.value = '*';
def.values.add(defTarget);
Metadata.CustomMetadataValue defCols = new Metadata.CustomMetadataValue();
defCols.field = 'plse__Columns_JSON__c';
defCols.value = '[{"field":"Name","label":"Record"}]';
def.values.add(defCols);
Metadata.CustomMetadataValue defActive = new Metadata.CustomMetadataValue();
defActive.field = 'plse__Active__c'; defActive.value = true;
def.values.add(defActive);
records.add(def);

Metadata.DeployContainer container = new Metadata.DeployContainer();
for (Metadata.CustomMetadata cm : records) container.addMetadata(cm);
Id jobId = Metadata.Operations.enqueueDeployment(container, null);
System.debug('### Enqueued CMDT deploy: ' + jobId + ' (records=' + records.size() + ')');
