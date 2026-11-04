#import "SICURLInterception.h"
#import <objc/runtime.h>
#import <objc/message.h>
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
static char connectionOptionsConsumedKey;
static char launchOptionsConsumedKey;
static char urlContextConsumedKey;

static BOOL isInternalURL(NSURL *url) {
    return [url isKindOfClass:NSURL.class] && isRunnerURL && isRunnerURL(url);
}

static BOOL consumeURL(NSURL *url) {
    if (!isInternalURL(url)) return NO;
    // Finish UIKit's callback before starting an app-to-app transition.
    dispatch_async(dispatch_get_main_queue(), ^{ receiveRunnerURL(url); });
    return YES;
}

static NSSet *filterURLContexts(NSSet *contexts, BOOL dispatchInternal) {
    NSMutableSet *remaining = [NSMutableSet new];
    for (id<SICURLContext> context in contexts) {
        NSURL *url = [context respondsToSelector:@selector(URL)] ? context.URL : nil;
        if (isInternalURL(url)) {
            if (dispatchInternal && !objc_getAssociatedObject(context, &urlContextConsumedKey)) {
                objc_setAssociatedObject(context, &urlContextConsumedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                consumeURL(url);
            }
        } else if (context) {
            [remaining addObject:context];
        }
    }
    return remaining;
}

static NSDictionary *guestLaunchOptions(id delegate, NSDictionary *options) {
    // UIApplicationLaunchOptionsURLKey's exported value, without linking UIKit
    // into the Foundation-only delegate regression tests.
    NSString *key = @"UIApplicationLaunchOptionsURLKey";
    NSURL *url = options[key];
    if (!isInternalURL(url)) return options;
    if (delegate && !objc_getAssociatedObject(delegate, &launchOptionsConsumedKey)) {
        objc_setAssociatedObject(delegate, &launchOptionsConsumedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        consumeURL(url);
    } else if (!delegate) {
        consumeURL(url);
    }
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

static void hookSceneDelegate(Class cls) {
    if (!cls || objc_getAssociatedObject(cls, &sceneDelegateHookKey)) return;
    objc_setAssociatedObject(cls, &sceneDelegateHookKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SEL open = NSSelectorFromString(@"scene:openURLContexts:");
    IMP originalOpen = methodImplementation(cls, open);
    replaceMethod(cls, open, ^(id self, id scene, NSSet *contexts) {
        NSSet *remaining = filterURLContexts(contexts, YES);
        if (remaining.count && originalOpen) ((void (*)(id, SEL, id, id))originalOpen)(self, open, scene, remaining);
    }, "v@:@@");

    SEL connect = NSSelectorFromString(@"scene:willConnectToSession:options:");
    IMP originalConnect = methodImplementation(cls, connect);
    replaceMethod(cls, connect, ^(id self, id scene, id session, id<SICConnectionOptions> options) {
        // The hooked public getter dispatches internal cold-start URLs once,
        // even when the guest does not inspect connection options itself.
        if ([options respondsToSelector:@selector(URLContexts)]) {
            (void)options.URLContexts;
        }
        if (originalConnect) ((void (*)(id, SEL, id, id, id))originalConnect)(self, connect, scene, session, options);
    }, "v@:@@@");
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
            return ((BOOL (*)(id, SEL, id, id))original)(self, selector, app, guestLaunchOptions(self, options));
        }, NULL);
    }
    SEL configSel = NSSelectorFromString(@"application:configurationForConnectingSceneSession:options:");
    IMP originalConfig = methodImplementation(cls, configSel);
    if (originalConfig) {
        replaceMethod(cls, configSel, ^id(id self, id app, id session, id<SICConnectionOptions> options) {
            if ([options respondsToSelector:@selector(URLContexts)]) {
                (void)options.URLContexts;
            }
            id config = ((id (*)(id, SEL, id, id, id))originalConfig)(self, configSel, app, session, options);
            SEL delClassSel = NSSelectorFromString(@"delegateClass");
            if ([config respondsToSelector:delClassSel]) {
                Class scCls = ((Class (*)(id, SEL))objc_msgSend)(config, delClassSel);
                if (scCls) hookSceneDelegate(scCls);
            }
            return config;
        }, "@@:@@@");
    }
}

void SICInstallURLInterception(BOOL (^isInternalURL)(NSURL *), void (^handleURL)(NSURL *)) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        isRunnerURL = [isInternalURL copy];
        receiveRunnerURL = [handleURL copy];
        SEL setter = NSSelectorFromString(@"setDelegate:");
        SEL delegateGetter = NSSelectorFromString(@"delegate");
        SEL getter = NSSelectorFromString(@"URLContexts");

        Class appClass = NSClassFromString(@"UIApplication");
        IMP appSetter = methodImplementation(appClass, setter);
        if (appSetter) replaceMethod(appClass, setter, ^(id self, id delegate) {
            hookApplicationDelegate([delegate class]);
            ((void (*)(id, SEL, id))appSetter)(self, setter, delegate);
        }, NULL);
        IMP appGetter = methodImplementation(appClass, delegateGetter);
        if (appGetter) replaceMethod(appClass, delegateGetter, ^id(id self) {
            id delegate = ((id (*)(id, SEL))appGetter)(self, delegateGetter);
            if (delegate) hookApplicationDelegate([delegate class]);
            return delegate;
        }, "@@:");

        Class sceneClass = NSClassFromString(@"UIScene");
        IMP sceneSetter = methodImplementation(sceneClass, setter);
        if (sceneSetter) replaceMethod(sceneClass, setter, ^(id self, id delegate) {
            hookSceneDelegate([delegate class]);
            ((void (*)(id, SEL, id))sceneSetter)(self, setter, delegate);
        }, NULL);
        IMP sceneGetter = methodImplementation(sceneClass, delegateGetter);
        if (sceneGetter) replaceMethod(sceneClass, delegateGetter, ^id(id self) {
            id delegate = ((id (*)(id, SEL))sceneGetter)(self, delegateGetter);
            if (delegate) hookSceneDelegate([delegate class]);
            return delegate;
        }, "@@:");

        SEL sceneInit = NSSelectorFromString(@"initWithSession:connectionOptions:");
        IMP originalSceneInit = methodImplementation(sceneClass, sceneInit);
        if (originalSceneInit) replaceMethod(sceneClass, sceneInit, ^id(id self, id session, id<SICConnectionOptions> options) {
            if ([options respondsToSelector:getter]) {
                (void)options.URLContexts;
            }
            id instance = ((id (*)(id, SEL, id, id))originalSceneInit)(self, sceneInit, session, options);
            if (instance && sceneGetter) {
                id delegate = ((id (*)(id, SEL))sceneGetter)(instance, delegateGetter);
                if (delegate) hookSceneDelegate([delegate class]);
            }
            return instance;
        }, "@@:@@");

        SEL privateSceneOpen = NSSelectorFromString(@"_openURLContexts:");
        IMP originalPrivateSceneOpen = methodImplementation(sceneClass, privateSceneOpen);
        if (originalPrivateSceneOpen) replaceMethod(sceneClass, privateSceneOpen, ^(id self, NSSet *contexts) {
            if (sceneGetter) {
                id delegate = ((id (*)(id, SEL))sceneGetter)(self, delegateGetter);
                if (delegate) hookSceneDelegate([delegate class]);
            }
            NSSet *remaining = filterURLContexts(contexts, YES);
            if (remaining.count) {
                ((void (*)(id, SEL, id))originalPrivateSceneOpen)(self, privateSceneOpen, remaining);
            }
        }, "v@:@");

        Class sceneConfigClass = NSClassFromString(@"UISceneConfiguration");
        SEL configGetter = NSSelectorFromString(@"delegateClass");
        IMP originalConfigGetter = methodImplementation(sceneConfigClass, configGetter);
        if (originalConfigGetter) replaceMethod(sceneConfigClass, configGetter, ^Class(id self) {
            Class cls = ((Class (*)(id, SEL))originalConfigGetter)(self, configGetter);
            if (cls) hookSceneDelegate(cls);
            return cls;
        }, "#@:");
        SEL configSetter = NSSelectorFromString(@"setDelegateClass:");
        IMP originalConfigSetter = methodImplementation(sceneConfigClass, configSetter);
        if (originalConfigSetter) replaceMethod(sceneConfigClass, configSetter, ^(id self, Class cls) {
            if (cls) hookSceneDelegate(cls);
            ((void (*)(id, SEL, Class))originalConfigSetter)(self, configSetter, cls);
        }, "v@:#");

        Class optionsClass = NSClassFromString(@"UISceneConnectionOptions");
        IMP originalContexts = methodImplementation(optionsClass, getter);
        if (originalContexts) replaceMethod(optionsClass, getter, ^NSSet *(id self) {
            NSSet *contexts = ((id (*)(id, SEL))originalContexts)(self, getter);
            BOOL shouldDispatch = !objc_getAssociatedObject(self, &connectionOptionsConsumedKey);
            if (shouldDispatch) {
                objc_setAssociatedObject(self, &connectionOptionsConsumedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            return filterURLContexts(contexts, shouldDispatch);
        }, NULL);
    });
}

void SICRefreshURLInterceptionForActiveObjects(void) {
    Class appClass = NSClassFromString(@"UIApplication");
    SEL sharedSel = NSSelectorFromString(@"sharedApplication");
    SEL delegateSel = NSSelectorFromString(@"delegate");
    SEL scenesSel = NSSelectorFromString(@"connectedScenes");
    if (!appClass || ![appClass respondsToSelector:sharedSel]) return;
    id app = ((id (*)(id, SEL))objc_msgSend)(appClass, sharedSel);
    if (!app) return;
    if ([app respondsToSelector:delegateSel]) {
        id appDel = ((id (*)(id, SEL))objc_msgSend)(app, delegateSel);
        if (appDel) hookApplicationDelegate([appDel class]);
    }
    if ([app respondsToSelector:scenesSel]) {
        NSSet *scenes = ((id (*)(id, SEL))objc_msgSend)(app, scenesSel);
        for (id scene in scenes) {
            if ([scene respondsToSelector:delegateSel]) {
                id scDel = ((id (*)(id, SEL))objc_msgSend)(scene, delegateSel);
                if (scDel) hookSceneDelegate([scDel class]);
            }
        }
    }
}
