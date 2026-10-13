#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
BOOL NoriMenuBarVisibilityAvailable(void);
id _Nullable NoriMenuBarVisibilityActivate(NSArray<NSString *> *allowedApps,
    void (^completion)(id _Nullable handle, NSString * _Nullable error));
void NoriMenuBarVisibilityRelease(id handle);
NS_ASSUME_NONNULL_END
