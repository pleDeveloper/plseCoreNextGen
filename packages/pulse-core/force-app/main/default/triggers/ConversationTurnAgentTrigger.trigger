trigger ConversationTurnAgentTrigger on Conversation_Turn__c (after insert) {
    Set<Id> conversationIds = new Set<Id>();
    for (Conversation_Turn__c t : Trigger.new) {
        if (t.Conversation__c != null) {
            conversationIds.add(t.Conversation__c);
        }
    }
    if (conversationIds.isEmpty()) {
        return;
    }

    Map<Id, Id> convToInstance = new Map<Id, Id>();
    for (Conversation__c c : [
        SELECT Id, Workflow_Instance__c
        FROM Conversation__c
        WHERE Id IN :conversationIds
          AND Workflow_Instance__c != null
    ]) {
        convToInstance.put(c.Id, c.Workflow_Instance__c);
    }
    if (convToInstance.isEmpty()) {
        return;
    }

    // Deduplicate: one enqueue per unique instance, not per turn
    Set<Id> instanceIds = new Set<Id>(convToInstance.values());

    Set<Id> aiEligibleIds = PulseAgentInvoker.filterAiDrivenInstances(instanceIds);
    if (aiEligibleIds.isEmpty()) {
        return;
    }

    if (!PulseAgentInvoker.enqueueSuppressed) {
        for (Id instId : aiEligibleIds) {
            System.enqueueJob(new PulseAgentInvokerQueueable(instId));
        }
    }
}
