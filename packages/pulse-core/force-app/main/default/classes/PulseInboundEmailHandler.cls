global with sharing class PulseInboundEmailHandler implements Messaging.InboundEmailHandler {

    global Messaging.InboundEmailResult handleInboundEmail(
        Messaging.InboundEmail email, Messaging.InboundEnvelope env
    ) {
        Messaging.InboundEmailResult result = new Messaging.InboundEmailResult();

        Id instanceId = PulseEmailRouter.extractInstanceId(email.subject);
        if (instanceId == null) {
            instanceId = PulseEmailRouter.routeByContactEmail(email.fromAddress);
        }

        PulseConversationModels.ConversationInput input =
            PulseEmailRouter.buildConversationInput(email, instanceId);

        ConversationIngestionService.ingest(
            new List<PulseConversationModels.ConversationInput>{ input }
        );

        result.success = true;
        return result;
    }
}
