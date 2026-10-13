#import "NoriMenuBarVisibility.h"
#import <dlfcn.h>
#import <objc/message.h>

// Experimental macOS 27 backend. Runtime discovery and exception handling keep
// private API changes from becoming launch failures. Never used on older OSes.
static Class Configuration(void) { return NSClassFromString(@"MBAssessmentModeConfiguration"); }
static Class Assertion(void) { return NSClassFromString(@"MBAssessmentModeAssertion"); }
BOOL NoriMenuBarVisibilityAvailable(void) {
    static void *framework;
    if (!framework) framework = dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_NOW | RTLD_LOCAL);
    return framework && [Configuration() instancesRespondToSelector:@selector(initWithAllowedSystemItems:allowedBundleIdentifiers:)]
        && [Assertion() instancesRespondToSelector:@selector(activateWithConfiguration:completionHandler:)]
        && [Assertion() instancesRespondToSelector:@selector(invalidate)];
}
void NoriMenuBarVisibilityRelease(id handle) {
    @try {
        if ([handle respondsToSelector:@selector(invalidate)])
            ((void (*)(id, SEL))objc_msgSend)(handle, @selector(invalidate));
    } @catch (NSException *exception) { NSLog(@"Nori menu bar restore: %@", exception.reason); }
}
id NoriMenuBarVisibilityActivate(NSArray<NSString *> *allowedApps,
    void (^completion)(id, NSString *)) {
    if (!NoriMenuBarVisibilityAvailable()) { dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, @"Visibility API unavailable"); }); return nil; }
    id handle = nil;
    @try {
        // Includes all currently known system controls; unknown identifiers are
        // ignored by macOS. This undocumented mapping must be checked per release.
        NSMutableArray *systemItems = [NSMutableArray array];
        for (NSInteger i = 0; i < 64; i++) [systemItems addObject:@(i)];
        id config = ((id (*)(id, SEL, id, id))objc_msgSend)([Configuration() alloc],
            @selector(initWithAllowedSystemItems:allowedBundleIdentifiers:), systemItems, [allowedApps copy]);
        handle = [[Assertion() alloc] init];
        if (!config || !handle) { dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, @"Visibility configuration unavailable"); }); return nil; }
        id retainedHandle = handle;
        ((void (*)(id, SEL, id, void (^)(NSError *)))objc_msgSend)(handle,
            @selector(activateWithConfiguration:completionHandler:), config, ^(NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (error) NoriMenuBarVisibilityRelease(retainedHandle);
                    completion(error ? nil : retainedHandle, error.localizedDescription);
                });
            });
    } @catch (NSException *exception) {
        if (handle) NoriMenuBarVisibilityRelease(handle);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, exception.reason ?: @"Visibility API exception"); });
        return nil;
    }
    return handle;
}
