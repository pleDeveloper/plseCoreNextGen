public with sharing class PulseEmailTool implements PulseTool {

    private static final String TOOL_KEY = 'send_email';

    public String getToolKey() {
        return TOOL_KEY;
    }

    public String getDescription() {
        return 'Send an email using Salesforce native email service. Requires toAddress, subject, and body.';
    }

    public Map<String, Object> getInputSchema() {
        return new Map<String, Object>{
            'type' => 'object',
            'properties' => new Map<String, Object>{
                'toAddress' => new Map<String, Object>{
                    'type' => 'string',
                    'description' => 'Recipient email address'
                },
                'subject' => new Map<String, Object>{
                    'type' => 'string',
                    'description' => 'Email subject line'
                },
                'body' => new Map<String, Object>{
                    'type' => 'string',
                    'description' => 'Email body text'
                },
                'ccAddress' => new Map<String, Object>{
                    'type' => 'string',
                    'description' => 'Optional CC email address'
                }
            },
            'required' => new List<String>{ 'toAddress', 'subject', 'body' }
        };
    }

    public String getDefaultHitlPolicy() {
        return 'Approval_Required';
    }

    public PulseToolModels.Result execute(PulseToolModels.Context ctx) {
        String toAddress = (String) ctx.input.get('toAddress');
        String subject = (String) ctx.input.get('subject');
        String body = (String) ctx.input.get('body');
        String ccAddress = (String) ctx.input.get('ccAddress');

        if (String.isBlank(toAddress) || String.isBlank(subject) || String.isBlank(body)) {
            return PulseToolModels.fail('Missing required fields: toAddress, subject, body');
        }

        Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
        email.setToAddresses(new List<String>{ toAddress });
        email.setSubject(subject);
        email.setPlainTextBody(body);
        if (String.isNotBlank(ccAddress)) {
            email.setCcAddresses(new List<String>{ ccAddress });
        }
        email.setSaveAsActivity(true);

        try {
            List<Messaging.SendEmailResult> results = Messaging.sendEmail(
                new List<Messaging.SingleEmailMessage>{ email }
            );
            if (results[0].isSuccess()) {
                return PulseToolModels.ok(JSON.serialize(new Map<String, String>{
                    'status' => 'sent',
                    'toAddress' => toAddress
                }));
            }
            String errors = '';
            for (Messaging.SendEmailError err : results[0].getErrors()) {
                errors += err.getMessage() + '; ';
            }
            return PulseToolModels.fail('Email send failed: ' + errors);
        } catch (Exception e) {
            return PulseToolModels.fail('Email exception: ' + e.getMessage());
        }
    }
}
