#import "Probe.h"
#import <CommonCrypto/CommonDigest.h>
#import <fcntl.h>

static void recordEvent(NSDictionary *fields) {
    NSMutableDictionary *entry = [fields mutableCopy];
    entry[@"servicePID"] = @(getpid());
    entry[@"securitySession"] = currentSession();
    entry[@"uid"] = @(getuid());
    NSMutableData *line = [encoded(entry) mutableCopy];
    [line appendBytes:"\n" length:1];
    int fd = open(roundFile(@"service.jsonl").fileSystemRepresentation,
                  O_CREAT | O_APPEND | O_WRONLY, 0600);
    if (fd < 0 || write(fd, line.bytes, line.length) != (ssize_t)line.length) _exit(74);
    close(fd);
}

static NSString *digest(NSData *data) {
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, hash);
    NSMutableString *hex = [NSMutableString new];
    for (size_t i = 0; i < sizeof(hash); ++i) [hex appendFormat:@"%02x", hash[i]];
    return hex;
}

// The audit token comes from the kernel-delivered XPC message, never from its payload.
static OSStatus checkClient(xpc_object_t message, SecRequirementRef requirement) {
    SecCodeRef actual = NULL;
    OSStatus status = SecCodeCreateWithXPCMessage(message, kSecCSDefaultFlags, &actual);
    if (status == errSecSuccess) {
        status = SecCodeCheckValidity(actual, kSecCSDefaultFlags, requirement);
        CFRelease(actual);
    }
    return status;
}

static NSDictionary *operate(NSString *op) {
    NSMutableDictionary *r = [NSMutableDictionary new];
    recordEvent(@{@"event": @"keychain", @"op": op});
    OSStatus disabled = SecKeychainSetUserInteractionAllowed(false);
    r[@"disableInteractionStatus"] = @(disabled);
    if (disabled != errSecSuccess) return r;
    NSDictionary *query = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"com.dabaipet.spikes.s1-xpc.disposable",
        (__bridge id)kSecAttrAccount: @ROUND_UUID};
    NSString *marker = roundFile(@"created.sha256");
    if ([op isEqual:@"create"]) {
        unsigned char bytes[32];
        OSStatus random = SecRandomCopyBytes(kSecRandomDefault, sizeof(bytes), bytes);
        r[@"randomStatus"] = @(random);
        if (random != errSecSuccess) return r;
        NSData *value = [NSData dataWithBytes:bytes length:sizeof(bytes)];
        NSMutableDictionary *attrs = [query mutableCopy];
        attrs[(__bridge id)kSecValueData] = value;
        OSStatus add = SecItemAdd((__bridge CFDictionaryRef)attrs, NULL);
        r[@"addStatus"] = @(add);
        if (add == errSecSuccess) {
            NSString *hash = digest(value);
            BOOL saved = [[hash dataUsingEncoding:NSASCIIStringEncoding]
                writeToFile:marker options:NSDataWritingWithoutOverwriting error:NULL];
            r[@"markerSaved"] = @(saved);
            r[@"sha256"] = hash;
            // If persistence of the ownership marker fails, this exact add just succeeded.
            if (!saved) r[@"rollbackStatus"] = @(SecItemDelete((__bridge CFDictionaryRef)query));
        }
        return r;
    }
    if (![NSFileManager.defaultManager fileExistsAtPath:marker]) return r;
    NSMutableDictionary *read = [query mutableCopy];
    read[(__bridge id)kSecReturnData] = @YES;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)read, &result);
    NSData *value = CFBridgingRelease(result);
    r[@"readStatus"] = @(status);
    if (status != errSecSuccess || ![value isKindOfClass:NSData.class]) return r;
    NSString *hash = digest(value);
    r[@"sha256"] = hash;
    if ([op isEqual:@"cleanup"]) {
        NSString *created = [NSString stringWithContentsOfFile:marker
            encoding:NSASCIIStringEncoding error:NULL];
        if (![hash isEqual:created]) return r;
        OSStatus deleted = SecItemDelete((__bridge CFDictionaryRef)query);
        r[@"deleteStatus"] = @(deleted);
        r[@"postDeleteStatus"] = @(SecItemCopyMatching((__bridge CFDictionaryRef)query, NULL));
    }
    return r;
}

static SecRequirementRef requirement;

static void acceptPeer(xpc_connection_t peer) {
    __block NSString *session = nil;
    xpc_connection_set_event_handler(peer, ^(xpc_object_t msg) {
        @autoreleasepool {
            if (xpc_get_type(msg) == XPC_TYPE_ERROR) {
                if (msg == XPC_ERROR_CONNECTION_INVALID) {
                    recordEvent(@{@"event": @"exit", @"exitCode": @0});
                    _exit(0);
                }
                return;
            }
            if (xpc_get_type(msg) != XPC_TYPE_DICTIONARY) return;
            OSStatus auth = checkClient(msg, requirement);
            NSMutableDictionary *r = [@{@"servicePID": @(getpid()),
                @"clientPID": @(xpc_connection_get_pid(peer)), @"clientStatus": @(auth)} mutableCopy];
            if (auth != errSecSuccess) {
                r[@"event"] = @"denied";
                recordEvent(r);
                sendResult(peer, msg, r);
                return;
            }
            const char *verb = xpc_dictionary_get_string(msg, "op");
            NSString *op = verb ? [NSString stringWithUTF8String:verb] : nil;
            if ([op isEqual:@"hello"]) {
                session = NSUUID.UUID.UUIDString;
                r[@"session"] = session;
            } else {
                const char *token = xpc_dictionary_get_string(msg, "session");
                if (token && [session isEqual:[NSString stringWithUTF8String:token]] &&
                    [@[@"create", @"read", @"cleanup"] containsObject:op]) {
                    [r addEntriesFromDictionary:operate(op)];
                }
            }
            sendResult(peer, msg, r);
        }
    });
    xpc_connection_activate(peer);
}

int main(void) {
    if (SecRequirementCreateWithString(CFSTR(HOST_REQ), 0, &requirement)) return 70;
    recordEvent(@{@"event": @"start", @"executable": NSBundle.mainBundle.executablePath});
    xpc_main(acceptPeer);
}
