public with sharing class PulseExternalApiTool implements PulseTool {

    private static final String TOOL_KEY = 'call_external_api';

    private static final Set<String> ALLOWED_METHODS = new Set<String>{
        'GET', 'POST', 'PUT', 'PATCH', 'DELETE'
    };

    public String getToolKey() {
        return TOOL_KEY;
    }

    public String getDescription() {
        return 'Make an HTTP callout via a Named Credential. Requires namedCredential, path, and method.';
    }

    public Map<String, Object> getInputSchema() {
        return new Map<String, Object>{
            'type' => 'object',
            'properties' => new Map<String, Object>{
                'namedCredential' => new Map<String, Object>{
                    'type' => 'string',
                    'description' => 'Named Credential developer name'
                },
                'path' => new Map<String, Object>{
                    'type' => 'string',
                    'description' => 'URL path appended to Named Credential endpoint'
                },
                'method' => new Map<String, Object>{
                    'type' => 'string',
                    'description' => 'HTTP method (GET, POST, PUT, PATCH, DELETE)'
                },
                'body' => new Map<String, Object>{
                    'type' => 'string',
                    'description' => 'Optional request body as JSON string'
                }
            },
            'required' => new List<String>{ 'namedCredential', 'path', 'method' }
        };
    }

    public String getDefaultHitlPolicy() {
        return 'Approval_Required';
    }

    public PulseToolModels.Result execute(PulseToolModels.Context ctx) {
        String namedCred = (String) ctx.input.get('namedCredential');
        String path = (String) ctx.input.get('path');
        String method = (String) ctx.input.get('method');
        String body = (String) ctx.input.get('body');

        if (String.isBlank(namedCred) || String.isBlank(path) || String.isBlank(method)) {
            return PulseToolModels.fail('Missing required: namedCredential, path, method');
        }

        method = method.toUpperCase();
        if (!ALLOWED_METHODS.contains(method)) {
            return PulseToolModels.fail('Invalid HTTP method: ' + method);
        }

        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:' + namedCred + path);
        req.setMethod(method);
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(60000);

        if (String.isNotBlank(body) && method != 'GET') {
            req.setBody(body);
        }

        try {
            HttpResponse res = new Http().send(req);

            Map<String, Object> output = new Map<String, Object>{
                'statusCode' => res.getStatusCode(),
                'body' => res.getBody()
            };

            if (res.getStatusCode() >= 200 && res.getStatusCode() < 300) {
                return PulseToolModels.ok(JSON.serialize(output));
            }
            return PulseToolModels.fail('HTTP ' + res.getStatusCode() + ': ' + res.getBody());
        } catch (Exception e) {
            return PulseToolModels.fail('Callout failed: ' + e.getMessage());
        }
    }
}
