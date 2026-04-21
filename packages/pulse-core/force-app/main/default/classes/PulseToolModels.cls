global class PulseToolModels {

    global class Context {
        global Id instanceId;
        global Id parentRecordId;
        global String parentObjectType;
        global Map<String, Object> input;
        global Id actorUserId;

        global Context(Id instanceId, Map<String, Object> input) {
            this.instanceId = instanceId;
            this.input = input != null ? input : new Map<String, Object>();
        }
    }

    global class Result {
        global Boolean success;
        global String outputJson;
        global String errorMessage;
    }

    global static Result ok(String outputJson) {
        Result r = new Result();
        r.success = true;
        r.outputJson = outputJson;
        return r;
    }

    global static Result fail(String errorMessage) {
        Result r = new Result();
        r.success = false;
        r.errorMessage = errorMessage;
        return r;
    }
}
