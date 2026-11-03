// iContainer experimental iOS runtime. Original implementation, 2026.
// Guests share this process and its OS sandbox. Path routing is convenience,
// NOT a security boundary against untrusted guest code.
#import "ICRuntime.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/loader.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <unistd.h>
#import <sys/stat.h>
#import <stdlib.h>
#import <string.h>

static NSString *rootPath;
static NSBundle *guestBundle;
static NSBundle *hostBundle;
static NSDictionary *guestInfo;
static NSString *guestData;
static IMP originalMainBundle, originalInfo, originalObject, originalForClass;
static IMP originalURLs, originalURL;
static IMP originalDefaults;
static NSUserDefaults *guestDefaults;
static UIWindow *returnWindow;

NSString *ICContainerRoot(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *base = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject.path;
        rootPath = [base stringByAppendingPathComponent:@"iContainer"];
        [NSFileManager.defaultManager createDirectoryAtPath:rootPath withIntermediateDirectories:YES attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil];
    });
    return rootPath;
}
static NSString *ticketPath(void) { return [ICContainerRoot() stringByAppendingPathComponent:@"next-launch.plist"]; }
static NSString *errorPath(void) { return [ICContainerRoot() stringByAppendingPathComponent:@"last-launch-error.txt"]; }
NSString *ICLastLaunchError(void) { return [NSString stringWithContentsOfFile:errorPath() encoding:NSUTF8StringEncoding error:nil]; }
static void fail(NSString *message) { [message writeToFile:errorPath() atomically:YES encoding:NSUTF8StringEncoding error:nil]; }

static BOOL validIdentifier(NSString *identifier) {
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:identifier];
    return uuid != nil && [uuid.UUIDString caseInsensitiveCompare:identifier] == NSOrderedSame;
}
static NSString *verifiedPath(NSString *path, NSString *parent) {
    NSString *p = path.stringByResolvingSymlinksInPath.stringByStandardizingPath;
    NSString *r = [parent.stringByResolvingSymlinksInPath.stringByStandardizingPath stringByAppendingString:@"/"];
    return [p hasPrefix:r] ? p : nil;
}
BOOL ICQueueGuest(NSString *identifier, NSError **error) {
    if (!validIdentifier(identifier)) {
        if (error) *error=[NSError errorWithDomain:@"iContainer" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Danh tính app không hợp lệ."}];
        return NO;
    }
    NSString *dir=[ICContainerRoot() stringByAppendingPathComponent:identifier];
    NSString *prepared=[dir stringByAppendingPathComponent:@"Prepared.app"];
    NSData *data=[NSData dataWithContentsOfFile:[prepared stringByAppendingPathComponent:@"iContainerLaunch.json"]];
    NSDictionary *manifest=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:error] : nil;
    if (![manifest isKindOfClass:NSDictionary.class] || ![manifest[@"prepared"] boolValue] || ![manifest[@"id"] isEqual:identifier]) {
        if (error && !*error) *error=[NSError errorWithDomain:@"iContainer" code:2 userInfo:@{NSLocalizedDescriptionKey:@"App chưa được chuẩn bị. Chọn nguồn ký rồi chuẩn bị lại."}];
        return NO;
    }
    if ([manifest[@"preparation_revision"] integerValue] < 2) {
        if (error) *error=[NSError errorWithDomain:@"iContainer" code:3 userInfo:@{NSLocalizedDescriptionKey:@"Chọn Chuẩn bị lại để sửa bản chạy cũ. App gốc và dữ liệu được giữ nguyên."}];
        return NO;
    }
    NSDictionary *ticket=@{@"id":identifier,@"created":@([NSDate.date timeIntervalSince1970])};
    NSData *plist=[NSPropertyListSerialization dataWithPropertyList:ticket format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    return plist && [plist writeToFile:ticketPath() options:NSDataWritingAtomic error:error];
}

static NSBundle *mainBundle(id self, SEL cmd) { return guestBundle; }
static NSDictionary *infoDictionary(id self, SEL cmd) {
    if (self==hostBundle) return guestInfo;
    return ((NSDictionary *(*)(id,SEL))originalInfo)(self,cmd);
}
static id objectForKey(id self, SEL cmd, NSString *key) {
    if (self==hostBundle) return guestInfo[key];
    return ((id (*)(id,SEL,id))originalObject)(self,cmd,key);
}
static NSBundle *bundleForClass(id self, SEL cmd, Class cls) {
    const char *path=class_getImageName(cls);
    if (path && [[NSString stringWithUTF8String:path] hasPrefix:[guestBundle.bundlePath stringByAppendingString:@"/"]]) return guestBundle;
    return ((NSBundle *(*)(id,SEL,Class))originalForClass)(self,cmd,cls);
}
static NSURL *directoryURL(NSSearchPathDirectory directory) {
    NSString *sub=nil;
    switch(directory) {
        case NSDocumentDirectory:sub=@"Documents";break;
        case NSLibraryDirectory:sub=@"Library";break;
        case NSApplicationSupportDirectory:sub=@"Library/Application Support";break;
        case NSCachesDirectory:sub=@"Library/Caches";break;
        default:return nil;
    }
    NSString *path=[guestData stringByAppendingPathComponent:sub];
    [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    return [NSURL fileURLWithPath:path isDirectory:YES];
}
static NSArray *URLsForDirectory(id self, SEL cmd, NSSearchPathDirectory dir, NSSearchPathDomainMask domain) {
    NSURL *url=(domain & NSUserDomainMask) ? directoryURL(dir) : nil;
    return url ? @[url] : ((id (*)(id,SEL,NSUInteger,NSUInteger))originalURLs)(self,cmd,dir,domain);
}
static NSURL *URLForDirectory(id self, SEL cmd, NSSearchPathDirectory dir, NSSearchPathDomainMask domain, NSURL *appropriate, BOOL create, NSError **error) {
    NSURL *url=(domain & NSUserDomainMask) ? directoryURL(dir) : nil;
    return url ?: ((id (*)(id,SEL,NSUInteger,NSUInteger,id,BOOL,NSError **))originalURL)(self,cmd,dir,domain,appropriate,create,error);
}
static NSUserDefaults *standardDefaults(id self, SEL cmd) { return guestDefaults; }
static void installContext(void) {
    hostBundle=NSBundle.mainBundle;
    originalMainBundle=method_setImplementation(class_getClassMethod(NSBundle.class,@selector(mainBundle)),(IMP)mainBundle);
    originalInfo=method_setImplementation(class_getInstanceMethod(NSBundle.class,@selector(infoDictionary)),(IMP)infoDictionary);
    originalObject=method_setImplementation(class_getInstanceMethod(NSBundle.class,@selector(objectForInfoDictionaryKey:)),(IMP)objectForKey);
    originalForClass=method_setImplementation(class_getClassMethod(NSBundle.class,@selector(bundleForClass:)),(IMP)bundleForClass);
    originalURLs=method_setImplementation(class_getInstanceMethod(NSFileManager.class,@selector(URLsForDirectory:inDomains:)),(IMP)URLsForDirectory);
    originalURL=method_setImplementation(class_getInstanceMethod(NSFileManager.class,@selector(URLForDirectory:inDomain:appropriateForURL:create:error:)),(IMP)URLForDirectory);
    // Separate the usual preferences API. Direct CFPreferences/Keychain calls
    // still share the host environment and are not claimed to be isolated.
    NSString *identity=guestData.stringByDeletingLastPathComponent.lastPathComponent;
    guestDefaults=[[NSUserDefaults alloc] initWithSuiteName:[@"com.hongson117.icontainer.guest." stringByAppendingString:identity]];
    originalDefaults=method_setImplementation(class_getClassMethod(NSUserDefaults.class,@selector(standardUserDefaults)),(IMP)standardDefaults);
    setenv("HOME",guestData.fileSystemRepresentation,1);
    setenv("CFFIXED_USER_HOME",guestData.fileSystemRepresentation,1);
    setenv("TMPDIR",[guestData stringByAppendingPathComponent:@"tmp"].fileSystemRepresentation,1);
    chdir(guestData.fileSystemRepresentation);
}
static void restoreContext(void) {
    if (!originalMainBundle) return;
    method_setImplementation(class_getClassMethod(NSBundle.class,@selector(mainBundle)),originalMainBundle);
    method_setImplementation(class_getInstanceMethod(NSBundle.class,@selector(infoDictionary)),originalInfo);
    method_setImplementation(class_getInstanceMethod(NSBundle.class,@selector(objectForInfoDictionaryKey:)),originalObject);
    method_setImplementation(class_getClassMethod(NSBundle.class,@selector(bundleForClass:)),originalForClass);
    method_setImplementation(class_getInstanceMethod(NSFileManager.class,@selector(URLsForDirectory:inDomains:)),originalURLs);
    method_setImplementation(class_getInstanceMethod(NSFileManager.class,@selector(URLForDirectory:inDomain:appropriateForURL:create:error:)),originalURL);
    method_setImplementation(class_getClassMethod(NSUserDefaults.class,@selector(standardUserDefaults)),originalDefaults);
}

@interface ICReturnController : UIViewController
@end
@interface ICReturnWindow : UIWindow
@end
@implementation ICReturnWindow
- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event {
    UIView *hit=[super hitTest:point withEvent:event];
    if (!self.rootViewController.presentedViewController && (hit==self.rootViewController.view || hit==self)) return nil;
    return hit;
}
@end
@implementation ICReturnController
- (void)viewDidLoad {
    [super viewDidLoad];
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];
    self.view.backgroundColor=UIColor.clearColor;
    button.frame=CGRectMake(12,70,128,38);
    [button setTitle:@"↩ iContainer" forState:UIControlStateNormal];
    button.backgroundColor=[UIColor colorWithWhite:0.12 alpha:0.88];button.tintColor=UIColor.whiteColor;button.layer.cornerRadius=18;
    [button addTarget:self action:@selector(back) forControlEvents:UIControlEventTouchUpInside];[self.view addSubview:button];
}
- (void)back {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Về iContainer" message:@"App này sẽ đóng. Mở lại iContainer để về danh sách. Dữ liệu đã lưu vẫn được giữ." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Đóng app" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){exit(0);}]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
static void installReturnButton(void) {
    // A transparent pass-through window leaves guest gestures intact; its full
    // bounds also allow the confirmation alert to be presented normally.
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        returnWindow=[[ICReturnWindow alloc] initWithWindowScene:(UIWindowScene*)s];break;
    }
    if (!returnWindow) returnWindow=[[ICReturnWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    returnWindow.backgroundColor=UIColor.clearColor;returnWindow.windowLevel=UIWindowLevelAlert+1;
    returnWindow.rootViewController=[ICReturnController new];returnWindow.hidden=NO;
}

int ICBootGuest(void) {
    NSString *root=ICContainerRoot();
    NSDictionary *ticket=[NSDictionary dictionaryWithContentsOfFile:ticketPath()];
    if (!ticket) return -1;
    // Consume first, even if any following validation or guest initialization fails.
    [NSFileManager.defaultManager removeItemAtPath:ticketPath() error:nil];
    NSString *identifier=ticket[@"id"];
    NSTimeInterval age=[NSDate.date timeIntervalSince1970]-[ticket[@"created"] doubleValue];
    if (![identifier isKindOfClass:NSString.class] || !validIdentifier(identifier) || age<0 || age>600) { fail(@"Yêu cầu mở app đã hết hạn. Chọn Chạy lại.");return -1; }
    NSString *dir=verifiedPath([root stringByAppendingPathComponent:identifier],root);
    NSString *app=dir ? verifiedPath([dir stringByAppendingPathComponent:@"Prepared.app"],dir) : nil;
    NSData *data=app ? [NSData dataWithContentsOfFile:[app stringByAppendingPathComponent:@"iContainerLaunch.json"]] : nil;
    NSDictionary *manifest=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![manifest isKindOfClass:NSDictionary.class] || ![manifest[@"id"] isEqual:identifier] || ![manifest[@"prepared"] boolValue]) {fail(@"Không đọc được bản app đã chuẩn bị.");return -1;}
    if ([manifest[@"preparation_revision"] integerValue] < 2) {fail(@"Bản chạy cũ cần Chuẩn bị lại. App gốc và dữ liệu được giữ nguyên.");return -1;}
    if (![manifest[@"host_bundle_id"] isEqual:NSBundle.mainBundle.bundleIdentifier] || [manifest[@"certificate_expires"] doubleValue]<=[NSDate.date timeIntervalSince1970]) {
        fail(@"Chứng chỉ hoặc danh tính host đã thay đổi/hết hạn. Chọn Chuẩn bị lại bằng nguồn ký hiện tại.");return -1;
    }
    guestBundle=[NSBundle bundleWithPath:app];guestInfo=[NSDictionary dictionaryWithContentsOfFile:[app stringByAppendingPathComponent:@"Info.plist"]];
    NSString *exe=manifest[@"executable"];
    if (![exe isKindOfClass:NSString.class] || ![exe isEqual:exe.lastPathComponent]) {fail(@"Executable không hợp lệ.");return -1;}
    NSString *execPath=verifiedPath([app stringByAppendingPathComponent:exe],app);
    uint64_t entry=[manifest[@"entry_offset"] unsignedLongLongValue];
    if (!execPath || !guestBundle || !guestInfo || entry==0) {fail(@"Thiếu executable hoặc entry point.");return -1;}
    guestData=verifiedPath([dir stringByAppendingPathComponent:@"Data"],dir);
    if (!guestData) {fail(@"Vùng dữ liệu không hợp lệ.");return -1;}
    [NSFileManager.defaultManager removeItemAtPath:errorPath() error:nil];
    // Preload nested frameworks by dependency retries. All must have been signed
    // with the host certificate; system library validation remains enabled.
    NSString *frameworks=[app stringByAppendingPathComponent:@"Frameworks"];
    NSMutableArray<NSString*> *pending=[NSMutableArray new];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:frameworks error:nil]) {
        NSString *p=[frameworks stringByAppendingPathComponent:name];
        if ([name.pathExtension isEqual:@"framework"]) p=[[NSBundle bundleWithPath:p] executablePath];
        if (p && ([name.pathExtension isEqual:@"framework"] || [name.pathExtension isEqual:@"dylib"])) [pending addObject:p];
    }
    // The guest's NSBundle context must be ready before +load/constructors run.
    NSString *oldHome=NSHomeDirectory(); NSString *oldTmp=NSTemporaryDirectory();
    installContext();
    for (NSUInteger round=0;round<8 && pending.count;round++) {
        BOOL progress=NO;
        for (NSString *p in pending.copy) if (dlopen(p.fileSystemRepresentation,RTLD_NOW|RTLD_GLOBAL)) {[pending removeObject:p];progress=YES;}
        if (!progress) break;
    }
    void *handle=dlopen(execPath.fileSystemRepresentation,RTLD_NOW|RTLD_GLOBAL|RTLD_FIRST);
    if (!handle) {
        const char *reason=dlerror();NSString *message=reason ? [NSString stringWithUTF8String:reason] : @"Không nạp được app.";
        restoreContext();setenv("HOME",oldHome.fileSystemRepresentation,1);setenv("CFFIXED_USER_HOME",oldHome.fileSystemRepresentation,1);setenv("TMPDIR",oldTmp.fileSystemRepresentation,1);
        fail([@"Mở app thất bại: " stringByAppendingString:message]);
        // Framework constructors may have changed process state. A fresh host
        // launch is required; do not initialize SwiftUI in this tainted process.
        return 1;
    }
    const struct mach_header_64 *header=NULL;
    for (uint32_t i=0;i<_dyld_image_count();i++) {
        const char *name=_dyld_get_image_name(i);
        if (name && [[NSString stringWithUTF8String:name].stringByResolvingSymlinksInPath isEqual:execPath]) {header=(const struct mach_header_64*)_dyld_get_image_header(i);break;}
    }
    if (!header || header->magic!=MH_MAGIC_64) {fail(@"Không tìm được ảnh Mach-O sau khi nạp.");return 1;}
    // Validate LC_MAIN's saved file offset against an executable mapped segment.
    const uint8_t *cursor=(const uint8_t*)(header+1);uintptr_t target=0;
    const struct segment_command_64 *text=NULL;
    for (uint32_t i=0;i<header->ncmds;i++) {
        const struct load_command *lc=(const struct load_command*)cursor;
        if (lc->cmd==LC_SEGMENT_64) {const struct segment_command_64 *seg=(const struct segment_command_64*)lc;if (seg->fileoff==0 && seg->filesize>0)text=seg;}
        cursor+=lc->cmdsize;
    }
    cursor=(const uint8_t*)(header+1);
    for (uint32_t i=0;text && i<header->ncmds;i++) {
        const struct load_command *lc=(const struct load_command*)cursor;
        if (lc->cmd==LC_SEGMENT_64) {
            const struct segment_command_64 *seg=(const struct segment_command_64*)lc;
            if ((seg->initprot&4) && entry>=seg->fileoff && entry-seg->fileoff<seg->filesize) target=(uintptr_t)header-text->vmaddr+seg->vmaddr+(uintptr_t)(entry-seg->fileoff);
        } cursor+=lc->cmdsize;
    }
    if (!target) {fail(@"Entry point không nằm trong vùng mã thực thi.");return 1;}
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{installReturnButton();});}];
    char *guestArgv[]={strdup(execPath.fileSystemRepresentation),NULL};
    int (*start)(int,char**,char**,char**)=(void*)target;
    extern char **environ;
    return start(1,guestArgv,environ,NULL);
}
