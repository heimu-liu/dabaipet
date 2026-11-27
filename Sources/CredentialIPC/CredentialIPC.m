#import "CredentialIPC.h"
#import <Security/Security.h>
#import <xpc/xpc.h>

int32_t DabaiCredentialCall(NSString *operation, NSString *account, NSData *value, NSData **result) {
    NSString *leaf = [NSBundle.mainBundle objectForInfoDictionaryKey:@"DabaiCredentialSigner"];
    if (leaf.length != 40 || [leaf rangeOfCharacterFromSet:
        [NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEF"].invertedSet].location != NSNotFound)
        return errSecCSReqFailed;
    NSString *requirement = [NSString stringWithFormat:
        @"identifier \"com.dabaipet.app.credentials\" and certificate leaf = H\"%@\"", leaf];
    xpc_connection_t connection = xpc_connection_create("com.dabaipet.app.credentials", NULL);
    if (xpc_connection_set_peer_code_signing_requirement(connection, requirement.UTF8String) != 0)
        return errSecCSReqFailed;
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {});
    xpc_connection_activate(connection);
    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(request, "operation", operation.UTF8String);
    xpc_dictionary_set_string(request, "account", account.UTF8String);
    if (value.length) xpc_dictionary_set_data(request, "value", value.bytes, value.length);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block OSStatus status = errSecNotAvailable;
    __block NSData *data = nil;
    xpc_connection_send_message_with_reply(connection, request, NULL, ^(xpc_object_t reply) {
        if (xpc_get_type(reply) == XPC_TYPE_DICTIONARY &&
            xpc_dictionary_get_value(reply, "status") != NULL) {
            status = (OSStatus)xpc_dictionary_get_int64(reply, "status");
            size_t length = 0;
            const void *bytes = xpc_dictionary_get_data(reply, "value", &length);
            if (bytes) data = [NSData dataWithBytes:bytes length:length];
        }
        dispatch_semaphore_signal(done);
    });
    long timedOut = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    xpc_connection_cancel(connection);
    if (timedOut) return errSecNotAvailable;
    *result = data;
    return status;
}
