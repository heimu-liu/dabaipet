#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <xpc/xpc.h>
#import <os/log.h>

static SecRequirementRef host;
static dispatch_queue_t operations;

static OSStatus operate(xpc_object_t message, xpc_object_t reply) {
    const char *name = xpc_dictionary_get_string(message, "account");
    const char *verb = xpc_dictionary_get_string(message, "operation");
    if (!name || !verb || strnlen(name, 80) >= 80) return errSecParam;
    NSString *account = [NSString stringWithUTF8String:name];
    if (!account || [account rangeOfString:@"\\A(endpoint-[0-9a-f]{64}|canary-[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12})\\z"
                                    options:NSRegularExpressionSearch].location == NSNotFound) return errSecParam;
    BOOL read = strcmp(verb, "read") == 0, save = strcmp(verb, "save") == 0;
    if (!read && !save && strcmp(verb, "delete") != 0) return errSecParam;
    NSDictionary *query = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"com.dabaipet.app.llm.apikey.v1", (__bridge id)kSecAttrAccount: account};
    NSMutableDictionary *lookup = [query mutableCopy];
    lookup[(__bridge id)kSecReturnData] = @YES;
    CFTypeRef found = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)lookup, &found);
    NSData *previous = CFBridgingRelease(found);
    if (status != errSecSuccess && status != errSecItemNotFound) return status;
    if (read) {
        if (status == errSecSuccess) xpc_dictionary_set_data(reply, "value", previous.bytes, previous.length);
        return status;
    }
    if (!save) return status == errSecItemNotFound ? status : SecItemDelete((__bridge CFDictionaryRef)query);
    size_t length = 0;
    const void *bytes = xpc_dictionary_get_data(message, "value", &length);
    if (!bytes || length == 0 || length > 16384) return errSecParam;
    NSData *value = [NSData dataWithBytes:bytes length:length];
    NSDictionary *changes = @{(__bridge id)kSecValueData: value};
    if (status == errSecSuccess) {
        if ([previous isEqual:value]) return errSecSuccess;
        return SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)changes);
    }
    NSMutableDictionary *newItem = [query mutableCopy];
    [newItem addEntriesFromDictionary:changes];
    return SecItemAdd((__bridge CFDictionaryRef)newItem, NULL);
}

static void acceptPeer(xpc_connection_t peer) {
    xpc_connection_set_target_queue(peer, operations);
    xpc_connection_set_event_handler(peer, ^(xpc_object_t message) {
        @autoreleasepool {
            if (xpc_get_type(message) != XPC_TYPE_DICTIONARY) return;
            xpc_object_t reply = xpc_dictionary_create_reply(message);
            if (!reply) return;
            SecCodeRef client = NULL;
            OSStatus result = SecCodeCreateWithXPCMessage(message, 0, &client);
            if (result == errSecSuccess) {
                result = SecCodeCheckValidity(client, 0, host);
                CFRelease(client);
            }
            if (result == errSecSuccess) result = operate(message, reply);
            os_log_info(OS_LOG_DEFAULT, "Dabai credential operation status %{public}d", (int)result);
            xpc_dictionary_set_int64(reply, "status", result);
            xpc_connection_send_message(peer, reply);
        }
    });
    xpc_connection_activate(peer);
}

int main(void) {
    if (SecKeychainSetUserInteractionAllowed(false) != errSecSuccess) return 70;
    if (SecRequirementCreateWithString(CFSTR(HOST_REQUIREMENT), 0, &host) != errSecSuccess) return 70;
    operations = dispatch_queue_create("com.dabaipet.app.credential-operations", DISPATCH_QUEUE_SERIAL);
    xpc_main(acceptPeer);
}
