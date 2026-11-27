#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <Security/AuthSession.h>
#import <xpc/xpc.h>
#import <unistd.h>
#import "Round.h"

static NSNumber *currentSession(void) {
    SecuritySessionId session = noSecuritySession;
    return SessionGetInfo(callerSecuritySession, &session, NULL) == errSecSuccess ? @(session) : @0;
}

static NSString *roundFile(NSString *name) {
    return [@ROUND_DIR stringByAppendingPathComponent:name];
}

static NSData *encoded(NSDictionary *fields) {
    return [NSJSONSerialization dataWithJSONObject:fields options:0 error:NULL];
}

static void sendResult(xpc_connection_t peer, xpc_object_t request, NSDictionary *fields) {
    xpc_object_t reply = xpc_dictionary_create_reply(request);
    if (!reply) return;
    NSData *data = encoded(fields);
    xpc_dictionary_set_data(reply, "receipt", data.bytes, data.length);
    xpc_connection_send_message(peer, reply);
}
