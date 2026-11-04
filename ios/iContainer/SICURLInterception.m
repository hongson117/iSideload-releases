#import "SICURLInterception.h"
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

@protocol SICURLContext <NSObject>
@property(nonatomic, readonly) NSURL *URL;
@end

@protocol SICConnectionOptions <NSObject>
@property(nonatomic, readonly) NSSet *URLContexts;
@end

static BOOL (^isRunnerURL)(NSURL *);
static void (^receiveRunnerURL)(NSURL *);
static char applicationDelegateHookKey;
static char sceneDelegateHookKey;

static BOOL consumeURL(NSURL *url) {
    if (![url isKindOfClass:NSURL.class] || !isRunnerURL(url)) return NO;
    // Finish UIKit's callback before starting an app-to-app transition.
    dispatch_async(dispatch_get_main_queue(), ^{ receiveRunnerURL(url); });
    return YES;
}

static NSSet *guestURLContexts(NSSet *contexts) {
    NSMutableSet *remaining = [NSMutableSet new];
    for (id<SICURLContext> context in contexts) {
        if (!consumeURL(context.URL)) [remaining addObject:context];
    }
    return remaining;
}

static NSDictionary *guestLaunchOptions(NSDictionary *options) {
    // UIApplicationLaunchOptionsURLKey's exported value, without linking UIKit
    // into the Foundation-only delegate regression tests.
    NSString *key = @"UIApplicationLaunchOptionsURLKey";
    if (!consumeURL(options[key])) return options;
    NSMutableDictionary *filtered = [options mutableCopy];
    [filtered removeObjectForKey:key];
    return filtered;
}

static IMP methodImplementation(Class cls, SEL selector) {
    Method method = class_getInstanceMethod(cls, selector);
    return method ? method_getImplementation(method) : NULL;
}

static void replaceMethod(Class cls, SEL selector, id block, const char *fallbackTypes) {
    Method method = class_getInstanceMethod(cls, selector);
    // class_replaceMethod adds an override when the implementation is inherited,
    // leaving sibling delegate classes and their superclass untouched.
    class_replaceMethod(cls, selector, imp_implementationWithBlock(block),
                        method ? method_getTypeEncoding(method) : fallbackTypes);
}

static void hookApplicationDelegate(Class cls) {
    if (!cls || objc_getAssociatedObject(cls, &applicationDelegateHookKey)) return;
    objc_setAssociatedObject(cls, &applicationDelegateHookKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    SEL open = NSSelectorFromString(@"application:openURL:options:");
    SEL legacy = NSSelectorFromString(@"application:openURL:sourceApplication:annotation:");
    SEL handle = NSSelectorFromString(@"application:handleOpenURL:");
    IMP originalOpen = methodImplementation(cls, open);
    IMP originalLegacy = methodImplementation(cls, legacy);
    IMP originalHandle = methodImplementation(cls, handle);
    NSString *boolTypes = [NSString stringWithFormat:@"%s@:@@@", @encode(BOOL)];
    replaceMethod(cls, open, ^BOOL(id self, id app, NSURL *url, NSDictionary *options) {
        if (consumeURL(url)) return YES;
        if (originalOpen) return ((BOOL (*)(id, SEL, id, id, id))originalOpen)(self, open, app, url, options);
        // Adding the modern selector must preserve a legacy guest's URL handler.
        if (originalLegacy) return ((BOOL (*)(id, SEL, id, id, id, id))originalLegacy)(self, legacy, app, url,
            options[@"UIApplicationOpenURLOptionsSourceApplicationKey"], options[@"UIApplicationOpenURLOptionsAnnotationKey"]);
        if (originalHandle) return ((BOOL (*)(id, SEL, id, id))originalHandle)(self, handle, app, url);
        return NO;
    }, boolTypes.UTF8String);

    if (originalLegacy) {
        replaceMethod(cls, legacy, ^BOOL(id self, id app, NSURL *url, id source, id annotation) {
            if (consumeURL(url)) return YES;
            return ((BOOL (*)(id, SEL, id, id, id, id))originalLegacy)(self, legacy, app, url, source, annotation);
        }, NULL);
    }
    if (originalHandle) {
        replaceMethod(cls, handle, ^BOOL(id self, id app, NSURL *url) {
            if (consumeURL(url)) return YES;
            return ((BOOL (*)(id, SEL, id, id))originalHandle)(self, handle, app, url);
        }, NULL);
    }
    for (NSString *name in @[@"application:willFinishLaunchingWithOptions:", @"application:didFinishLaunchingWithOptions:"]) {
        SEL selector = NSSelectorFromString(name);
        IMP original = methodImplementation(cls, selector);
        if (!original) continue;
        replaceMethod(cls, selector, ^BOOL(id self, id app, NSDictionary *options) {
            return ((BOOL (*)(id, SEL, id, id))original)(self, selector, app, guestLaunchOptions(options));
        }, NULL);
    }
}

static void hookSceneDelegate(Class cls) {
    if (!cls || objc_getAssociatedObject(cls, &sceneDelegateHookKey)) return;
    objc_setAssociatedObject(cls, &sceneDelegateHookKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SEL open = NSSelectorFromString(@"scene:openURLContexts:");
    IMP originalOpen = methodImplementation(cls, open);
    replaceMethod(cls, open, ^(id self, id scene, NSSet *contexts) {
        NSSet *remaining = guestURLContexts(contexts);
        if (remaining.count && originalOpen) ((void (*)(id, SEL, id, id))originalOpen)(self, open, scene, remaining);
    }, "v@:@@");

    SEL connect = NSSelectorFromString(@"scene:willConnectToSession:options:");
    IMP originalConnect = methodImplementation(cls, connect);
    replaceMethod(cls, connect, ^(id self, id scene, id session, id<SICConnectionOptions> options) {
        // The hooked public getter dispatches internal cold-start URLs even when
        // the guest does not inspect connection options itself.
        (void)options.URLContexts;
        if (originalConnect) ((void (*)(id, SEL, id, id, id))originalConnect)(self, connect, scene, session, options);
    }, "v@:@@@");
}

void SICInstallURLInterception(BOOL (^isInternalURL)(NSURL *), void (^handleURL)(NSURL *)) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        isRunnerURL = [isInternalURL copy];
        receiveRunnerURL = [handleURL copy];
        SEL setter = NSSelectorFromString(@"setDelegate:");
        Class appClass = NSClassFromString(@"UIApplication");
        IMP appSetter = methodImplementation(appClass, setter);
        if (appSetter) replaceMethod(appClass, setter, ^(id self, id delegate) {
            hookApplicationDelegate([delegate class]);
            ((void (*)(id, SEL, id))appSetter)(self, setter, delegate);
        }, NULL);

        Class sceneClass = NSClassFromString(@"UIScene");
        IMP sceneSetter = methodImplementation(sceneClass, setter);
        if (sceneSetter) replaceMethod(sceneClass, setter, ^(id self, id delegate) {
            hookSceneDelegate([delegate class]);
            ((void (*)(id, SEL, id))sceneSetter)(self, setter, delegate);
        }, NULL);

        Class optionsClass = NSClassFromString(@"UISceneConnectionOptions");
        SEL getter = NSSelectorFromString(@"URLContexts");
        IMP originalContexts = methodImplementation(optionsClass, getter);
        if (originalContexts) replaceMethod(optionsClass, getter, ^NSSet *(id self) {
            NSSet *contexts = ((id (*)(id, SEL))originalContexts)(self, getter);
            return guestURLContexts(contexts);
        }, NULL);
    });
}
