// Smoke test: end-to-end Anthropic call through PulseAiFacade.
// Run: sf apex run -o pulse-core-next-dev -f scripts/smoke-test-anthropic.apex
//
// Prerequisite: Named Credential `Pulse_Anthropic` is configured per
// docs/pulse-anthropic-named-credential-setup.md and the Anthropic
// AI_Provider_Registration CMDT record is deployed + Active.

System.debug('=== Pulse Core Next: Anthropic smoke test ===');

try {
    plse.PulseAiModels.Request req = new plse.PulseAiModels.Request();
    req.systemPrompt = 'You are a terse assistant. Reply with only the word requested.';
    req.messages.add(new plse.PulseAiModels.Message(
        'user',
        'Say the word "hello" and nothing else.'
    ));
    req.maxTokens = 64;

    Long t0 = System.currentTimeMillis();
    plse.PulseAiModels.Response resp = plse.PulseAiFacade.invoke(req);
    Long elapsed = System.currentTimeMillis() - t0;

    System.debug('--- Response ---');
    System.debug('Elapsed ms:        ' + elapsed);
    System.debug('isError:           ' + resp.isError);
    System.debug('errorMessage:      ' + resp.errorMessage);
    System.debug('providerRequestId: ' + resp.providerRequestId);
    System.debug('text:              ' + resp.text);

    if (resp.toolCalls != null) {
        System.debug('toolCalls.size:    ' + resp.toolCalls.size());
        for (plse.PulseAiModels.ToolCall tc : resp.toolCalls) {
            System.debug('  tool: ' + tc.toolKey + ' id=' + tc.id + ' input=' + tc.inputJson);
        }
    }

    if (resp.usage != null) {
        System.debug('usage.inputTokens:  ' + resp.usage.inputTokens);
        System.debug('usage.outputTokens: ' + resp.usage.outputTokens);
    } else {
        System.debug('usage: (null)');
    }

    if (resp.isError) {
        System.debug(LoggingLevel.ERROR, 'SMOKE TEST FAILED: ' + resp.errorMessage);
    } else {
        System.debug('SMOKE TEST OK');
    }
} catch (Exception e) {
    System.debug(LoggingLevel.ERROR, '=== Uncaught exception ===');
    System.debug(LoggingLevel.ERROR, e.getTypeName() + ': ' + e.getMessage());
    System.debug(LoggingLevel.ERROR, e.getStackTraceString());
}
