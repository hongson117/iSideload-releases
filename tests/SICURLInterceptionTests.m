#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import "../ios/iContainer/SICURLInterception.h"

// Foundation-only doubles exercise the actual Objective-C delegate wrapping on
// macOS. Real UIKit/SwiftUI delivery and process switching still require iPhone QA.
@interface UIApplication : NSObject
@property(nonatomic, strong) id delegate;
@end
@implementation UIApplication
@end
@interface UIScene : NSObject
@property(nonatomic, strong) id delegate;
@end
@implementation UIScene
@end
@interface UISceneConnectionOptions : NSObject
@property(nonatomic, strong) NSSet *URLContexts;
@end
@implementation UISceneConnectionOptions
@end
@interface URLContext : NSObject
@property(nonatomic, strong) NSURL *URL;
@end
@implementation URLContext
@end

@interface AppDelegate : NSObject
@property(nonatomic) NSUInteger opens;
@property(nonatomic, strong) NSDictionary *willLaunchOptions;
@property(nonatomic, strong) NSDictionary *launchOptions;
- (BOOL)application:(id)app openURL:(NSURL *)url options:(NSDictionary *)options;
- (BOOL)application:(id)app willFinishLaunchingWithOptions:(NSDictionary *)options;
- (BOOL)application:(id)app didFinishLaunchingWithOptions:(NSDictionary *)options;
@end
@implementation AppDelegate
- (BOOL)application:(id)app openURL:(NSURL *)url options:(NSDictionary *)options { self.opens++; return YES; }
- (BOOL)application:(id)app willFinishLaunchingWithOptions:(NSDictionary *)options { self.willLaunchOptions = options; return YES; }
- (BOOL)application:(id)app didFinishLaunchingWithOptions:(NSDictionary *)options { self.launchOptions = options; return YES; }
@end
@interface AppSubclass : AppDelegate
@end
@implementation AppSubclass
@end

@interface LegacyDelegate : NSObject
@property(nonatomic) NSUInteger opens;
@property(nonatomic, strong) NSString *source;
- (BOOL)application:(id)app openURL:(NSURL *)url sourceApplication:(NSString *)source annotation:(id)annotation;
@end
@implementation LegacyDelegate
- (BOOL)application:(id)app openURL:(NSURL *)url sourceApplication:(NSString *)source annotation:(id)annotation {
    self.opens++; self.source = source; return YES;
}
@end

@interface SceneDelegate : NSObject
@property(nonatomic, strong) NSSet *received;
@property(nonatomic) NSUInteger openCalls;
@property(nonatomic) NSUInteger connects;
- (void)scene:(id)scene openURLContexts:(NSSet *)contexts;
- (void)scene:(id)scene willConnectToSession:(id)session options:(UISceneConnectionOptions *)options;
@end
@implementation SceneDelegate
- (void)scene:(id)scene openURLContexts:(NSSet *)contexts { self.openCalls++; self.received = contexts; }
- (void)scene:(id)scene willConnectToSession:(id)session options:(UISceneConnectionOptions *)options {
    self.connects++;
    NSSet *firstRead = options.URLContexts;
    NSSet *secondRead = options.URLContexts;
    require([firstRead isEqual:secondRead], @"Repeated connectionOptions.URLContexts reads stay consistent");
    self.received = secondRead;
}
@end

static void require(BOOL value, NSString *message) {
    if (!value) { NSLog(@"FAIL %@", message); exit(1); }
}

int main(void) {
    @autoreleasepool {
        __block NSUInteger handled = 0;
        SICInstallURLInterception(^BOOL(NSURL *url) {
            return [url.scheme isEqual:@"sicontainer-runner1"];
        }, ^(NSURL *url) { handled++; });
        NSURL *internal = [NSURL URLWithString:@"sicontainer-runner1://launch?guest=5BCC9837-1C4A-498F-91DF-F9DE42DE68B1"];
        NSURL *external = [NSURL URLWithString:@"calendar://event/123"];
        UIApplication *app = [UIApplication new];
        AppSubclass *delegate = [AppSubclass new];
        app.delegate = delegate;
        app.delegate = delegate;
        require([delegate application:app openURL:internal options:@{}], @"Internal URL consumed");
        require(delegate.opens == 0, @"Internal URL must not reach guest");
        require([delegate application:app openURL:external options:@{}] && delegate.opens == 1, @"External URL forwarded once");
        AppDelegate *sibling = [AppDelegate new];
        [sibling application:app openURL:internal options:@{}];
        require(sibling.opens == 1, @"Hooking subclass must not modify superclass/siblings");
        NSDictionary *rawLaunch = @{@"UIApplicationLaunchOptionsURLKey": internal, @"other": @42};
        [delegate application:app willFinishLaunchingWithOptions:rawLaunch];
        [delegate application:app didFinishLaunchingWithOptions:rawLaunch];
        require(delegate.willLaunchOptions[@"UIApplicationLaunchOptionsURLKey"] == nil && [delegate.willLaunchOptions[@"other"] isEqual:@42], @"WillFinish launch options filtered");
        require(delegate.launchOptions[@"UIApplicationLaunchOptionsURLKey"] == nil && [delegate.launchOptions[@"other"] isEqual:@42], @"DidFinish launch options filtered");

        LegacyDelegate *legacy = [LegacyDelegate new];
        app.delegate = legacy;
        [(AppDelegate *)legacy application:app openURL:external options:@{@"UIApplicationOpenURLOptionsSourceApplicationKey": @"sender"}];
        require(legacy.opens == 1 && [legacy.source isEqual:@"sender"], @"Modern hook preserves legacy callback and options");
        [legacy application:app openURL:internal sourceApplication:nil annotation:nil];
        require(legacy.opens == 1, @"Legacy internal URL suppressed");

        UIScene *scene = [UIScene new];
        SceneDelegate *sceneDelegate = [SceneDelegate new];
        scene.delegate = sceneDelegate;
        URLContext *inside = [URLContext new]; inside.URL = internal;
        URLContext *outside = [URLContext new]; outside.URL = external;
        NSSet *mixed = [NSSet setWithObjects:inside, outside, nil];
        [sceneDelegate scene:scene openURLContexts:mixed];
        require(sceneDelegate.openCalls == 1 && [sceneDelegate.received isEqual:[NSSet setWithObject:outside]], @"Mixed scene context preserves external URLs and invokes guest once");
        [sceneDelegate scene:scene openURLContexts:[NSSet setWithObject:inside]];
        require(sceneDelegate.openCalls == 1, @"Internal-only scene context does not invoke guest scene:openURLContexts:");
        UISceneConnectionOptions *options = [UISceneConnectionOptions new];
        options.URLContexts = mixed;
        [sceneDelegate scene:scene willConnectToSession:nil options:options];
        require(sceneDelegate.connects == 1 && [sceneDelegate.received isEqual:[NSSet setWithObject:outside]], @"Scene cold launch connects with filtered contexts");
        require(handled == 0, @"Internal actions deferred until after UIKit callback");
        dispatch_async(dispatch_get_main_queue(), ^{
            require(handled == 6, [NSString stringWithFormat:@"Expected exactly 6 internal URL dispatches, got %lu", (unsigned long)handled]);
            NSLog(@"SIContainer delegate interception regression tests passed");
            exit(0);
        });
        dispatch_main();
    }
}
