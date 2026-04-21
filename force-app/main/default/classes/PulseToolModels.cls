public class PulseToolModels {

    public class Context {
        public Id instanceId;
        public Id parentRecordId;
        public String parentObjectType;
        public Map<String, Object> input;
        public Id actorUserId;

        public Context(Id instanceId, Map<String, Object> input) {
            this.instanceId = instanceId;
            this.input = input != null ? input : new Map<String, Object>();
        }
    }

    public class Result {
        public Boolean success;
        public String outputJson;
        public String errorMessage;
    }

    public static Result ok(String outputJson) {
        Result r = new Result();
        r.success = true;
        r.outputJson = outputJson;
        return r;
    }

    public static Result fail(String errorMessage) {
        Result r = new Result();
        r.success = false;
        r.errorMessage = errorMessage;
        return r;
    }
}
