/**
 * DTOs for the PulseConversationAdapter contract.
 * Lives in Core so the interface and all adapter implementations
 * (in extension packages) can reference these types without
 * creating a circular dependency on Pulse Conversations – Core.
 */
global class PulseConversationModels {

    global class ConversationInput {
        global String medium;           // Email | Phone_Call | Meeting | Chat
        global String subject;
        global String summary;
        global String participants;
        global String sourceAdapter;
        global String externalSource;
        global String externalSourceId;
        global String parentObjectType;
        global String parentRecordId;
        global Id workflowInstanceId;
        global List<TurnInput> turns;

        global ConversationInput() {
            this.turns = new List<TurnInput>();
        }
    }

    global class TurnInput {
        global String content;
        global String role;             // Agent | Customer | System | AI (restricted picklist)
        global String speaker;
        global Datetime timestamp;
        global Decimal turnIndex;
    }
}
