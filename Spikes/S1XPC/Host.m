#import "Probe.h"

static NSDictionary *call(xpc_connection_t peer, NSString *op, NSString *session) {
    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(request, "op", op.UTF8String);
    if (session) xpc_dictionary_set_string(request, "session", session.UTF8String);
    xpc_object_t reply = xpc_connection_send_message_with_reply_sync(peer, request);
    if (xpc_get_type(reply) != XPC_TYPE_DICTIONARY) {
        const char *reason = xpc_dictionary_get_string(reply, XPC_ERROR_KEY_DESCRIPTION);
        return @{@"transportError": reason ? @(reason) : @"unexpected reply"};
    }
    size_t len = 0;
    const void *bytes = xpc_dictionary_get_data(reply, "receipt", &len);
    if (!bytes) return @{};
    return [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes length:len]
        options:0 error:NULL] ?: @{};
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 2) return 64;
        NSString *op = @(argv[1]);
        NSString *build = @BUILD_MARKER;
        BOOL negative = [build isEqual:@"negative"] && [op isEqual:@"reject"];
        if (!(negative || ([build isEqual:@"A"] && [op isEqual:@"create"]) ||
              ([build isEqual:@"B"] && [@[@"read", @"cleanup"] containsObject:op]))) return 64;
        alarm(20);
        xpc_connection_t peer = xpc_connection_create(SERVICE_ID, NULL);
        int configured = xpc_connection_set_peer_code_signing_requirement(peer, SERVICE_REQ);
        NSMutableDictionary *report = [@{@"hostPID": @(getpid()), @"phase": op,
            @"build": build, @"securitySession": currentSession(), @"uid": @(getuid()),
            @"serviceRequirementStatus": @(configured),
            @"bundle": NSBundle.mainBundle.bundlePath} mutableCopy];
        BOOL ok = NO;
        if (configured == 0) {
            xpc_connection_set_event_handler(peer, ^(xpc_object_t event) {});
            xpc_connection_activate(peer);
            if (negative) {
                // Attempt a real read. The service must return signature failure before
                // checking the operation, session token or touching the disposable item.
                NSDictionary *denied = call(peer, @"read", nil);
                report[@"attemptedOp"] = @"read";
                report[@"result"] = denied;
                ok = [denied[@"clientStatus"] isEqual:@(errSecCSReqFailed)] &&
                     [denied[@"event"] isEqual:@"denied"];
            } else {
                NSMutableDictionary *hello = [call(peer, @"hello", nil) mutableCopy];
                NSString *session = hello[@"session"];
                [hello removeObjectForKey:@"session"];
                report[@"handshake"] = hello;
                if ([hello[@"clientStatus"] isEqual:@0] && session.length) {
                    NSDictionary *result = call(peer, op, session);
                    report[@"result"] = result;
                    ok = [hello[@"servicePID"] isEqual:result[@"servicePID"]] &&
                         [result[@"clientStatus"] isEqual:@0] &&
                         [result[@"disableInteractionStatus"] isEqual:@0];
                    if ([op isEqual:@"create"]) {
                        ok = ok && [result[@"addStatus"] isEqual:@0] &&
                             [result[@"markerSaved"] boolValue];
                    } else if ([op isEqual:@"read"]) {
                        ok = ok && [result[@"readStatus"] isEqual:@0] && result[@"sha256"];
                    } else {
                        ok = ok && [result[@"deleteStatus"] isEqual:@0] &&
                             [result[@"postDeleteStatus"] isEqual:@(errSecItemNotFound)];
                    }
                }
            }
        }
        int rc = ok ? 0 : 1;
        report[@"exitCode"] = @(rc);
        if (![encoded(report) writeToFile:roundFile([op stringByAppendingString:@".json"])
            options:NSDataWritingWithoutOverwriting error:NULL]) rc = 74;
        xpc_connection_cancel(peer);
        return rc;
    }
}
