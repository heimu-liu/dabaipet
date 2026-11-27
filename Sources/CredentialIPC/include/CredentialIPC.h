#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Returns a Security OSStatus. Only read returns bytes.
int32_t DabaiCredentialCall(NSString *operation, NSString *account, NSData *value,
                            NSData * _Nullable * _Nonnull result);
NS_ASSUME_NONNULL_END
