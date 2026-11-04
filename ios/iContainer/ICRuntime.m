// SIContainer experimental multi-slot iOS runtime. Original implementation, 2026.
// Separates Manager (router & signer) from Runner (guest host), uses per-slot
// Prepared.app bundles with shared guest Data/, kernel flock() liveness/writer
// locks, and transactional request/ack LRU tracking.
#import "ICRuntime.h"
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <mach-o/loader.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <unistd.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <sys/file.h>
#import <errno.h>
#import <stdlib.h>
#import <string.h>

static NSString *rootPath;
static NSString *sharedGroupID;
static BOOL sharedGroupOK = NO;
static NSString *hostBundleID;
static NSBundle *guestBundle;
static NSBundle *hostBundle;
static NSDictionary *guestInfo;
static NSString *guestData;
static NSString *loadedGuestID;
static NSString *loadedRequestID;
static IMP originalMainBundle, originalInfo, originalObject, originalForClass;
static IMP originalURLs, originalURL;
static IMP originalDefaults;
static NSUserDefaults *guestDefaults;
static UIWindow *returnWindow;
static int slotAliveFD = -1;
static int guestWriterFD = -1;
static volatile int evictingInProgress = 0;
static UIBackgroundTaskIdentifier runnerBgTask = UIBackgroundTaskInvalid;

static void endRunnerBackgroundStandby(void) {
    if (runnerBgTask != UIBackgroundTaskInvalid) {
        [UIApplication.sharedApplication endBackgroundTask:runnerBgTask];
        runnerBgTask = UIBackgroundTaskInvalid;
    }
}

static void beginRunnerBackgroundStandby(void) {
    if (!ICIsRunnerProcess()) return;
    endRunnerBackgroundStandby();
    runnerBgTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"SIContainerRunnerSlotStandby" expirationHandler:^{
        endRunnerBackgroundStandby();
    }];
}

static NSString *rawHostBundleID(void) {
    if (hostBundleID) return hostBundleID;
    NSBundle *b = hostBundle ?: NSBundle.mainBundle;
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[b.bundlePath stringByAppendingPathComponent:@"Info.plist"]];
    hostBundleID = info[@"CFBundleIdentifier"] ?: b.bundleIdentifier ?: @"";
    return hostBundleID;
}

static NSString *extractTeamSuffix(NSString *bundleID) {
    NSArray<NSString *> *parts = [bundleID componentsSeparatedByString:@"."];
    for (NSString *part in [parts reverseObjectEnumerator]) {
        if (part.length == 10 &&
            ![part isEqualToString:@"sicontainer"] &&
            ![part isEqualToString:@"icontainer"] &&
            ![part hasPrefix:@"runner"]) {
            return part;
        }
    }
    return nil;
}

static NSArray<NSString *> *candidateAppGroups(void) {
    NSMutableArray<NSString *> *groups = [NSMutableArray new];
    NSString *bid = rawHostBundleID();
    NSString *team = extractTeamSuffix(bid);
    if (team.length > 0) {
        [groups addObject:[@"group.com.hongson117.sicontainer." stringByAppendingString:team]];
    }
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[(hostBundle ?: NSBundle.mainBundle).bundlePath stringByAppendingPathComponent:@"Info.plist"]];
    for (NSString *key in @[@"SICAppGroups", @"ALTAppGroups"]) {
        NSArray *arr = info[key];
        if ([arr isKindOfClass:NSArray.class]) {
            for (id item in arr) {
                if ([item isKindOfClass:NSString.class] && ![groups containsObject:item]) {
                    [groups addObject:item];
                }
            }
        }
    }
    return groups;
}

static BOOL verifyWritableDirectory(NSString *dir) {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil]) {
        return NO;
    }
    NSString *probe = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@".probe-%d", getpid()]];
    NSData *payload = [@"ok" dataUsingEncoding:NSUTF8StringEncoding];
    if (![payload writeToFile:probe options:NSDataWritingAtomic error:nil]) return NO;
    NSData *readback = [NSData dataWithContentsOfFile:probe];
    [fm removeItemAtPath:probe error:nil];
    return [readback isEqualToData:payload];
}

NSString *ICContainerRoot(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        rawHostBundleID();
        NSFileManager *fm = NSFileManager.defaultManager;
        for (NSString *group in candidateAppGroups()) {
            NSURL *url = [fm containerURLForSecurityApplicationGroupIdentifier:group];
            if (!url.path.length) continue;
            NSString *candidate = [url.path stringByAppendingPathComponent:@"SIContainer"];
            if (verifyWritableDirectory(candidate)) {
                rootPath = candidate;
                sharedGroupID = group;
                sharedGroupOK = YES;
                break;
            }
        }
        if (!rootPath) {
            NSString *base = [fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject.path;
            NSString *folder = [rawHostBundleID() containsString:@".sicontainer"] ? @"SIContainer" : @"iContainer";
            rootPath = [base stringByAppendingPathComponent:folder];
            [fm createDirectoryAtPath:rootPath withIntermediateDirectories:YES attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil];
            sharedGroupOK = NO;
        }
        for (NSString *sub in @[@"probes", @"slots"]) {
            [fm createDirectoryAtPath:[rootPath stringByAppendingPathComponent:sub] withIntermediateDirectories:YES attributes:nil error:nil];
        }
    });
    return rootPath;
}

BOOL ICSharedGroupAvailable(void) {
    ICContainerRoot();
    return sharedGroupOK;
}

NSString *ICSharedGroupID(void) {
    ICContainerRoot();
    return sharedGroupID;
}

NSString *ICCurrentRole(void) {
    NSString *bid = rawHostBundleID();
    if ([bid containsString:@".runner1"]) return @"runner1";
    if ([bid containsString:@".runner2"]) return @"runner2";
    return @"manager";
}

BOOL ICIsRunnerProcess(void) {
    NSString *role = ICCurrentRole();
    return [role isEqualToString:@"runner1"] || [role isEqualToString:@"runner2"];
}

static NSString *slotsDir(void) { return [ICContainerRoot() stringByAppendingPathComponent:@"slots"]; }
static NSString *probesDir(void) { return [ICContainerRoot() stringByAppendingPathComponent:@"probes"]; }
static NSString *aliveLockPath(NSString *slotID) { return [slotsDir() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.alive.lock", slotID]]; }
static NSString *slotTicketPath(NSString *slotID) { return [slotsDir() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.ticket.plist", slotID]]; }
static NSString *registryPath(void) { return [slotsDir() stringByAppendingPathComponent:@"slot-registry.json"]; }
static NSString *registryLockPath(void) { return [slotsDir() stringByAppendingPathComponent:@"registry.lock"]; }
static NSString *ticketPath(void) { return [ICContainerRoot() stringByAppendingPathComponent:@"next-launch.plist"]; }
static NSString *errorPath(void) { return [ICContainerRoot() stringByAppendingPathComponent:@"last-launch-error.txt"]; }
NSString *ICLastLaunchError(void) { return [NSString stringWithContentsOfFile:errorPath() encoding:NSUTF8StringEncoding error:nil]; }
static void fail(NSString *message) { [message writeToFile:errorPath() atomically:YES encoding:NSUTF8StringEncoding error:nil]; }

static void acquireRunnerAliveLockIfNeeded(void) {
    if (!ICIsRunnerProcess() || slotAliveFD >= 0) return;
    NSString *path = aliveLockPath(ICCurrentRole());
    int fd = open(path.fileSystemRepresentation, O_CREAT | O_RDWR, 0600);
    if (fd >= 0) {
        if (flock(fd, LOCK_EX | LOCK_NB) == 0) {
            NSString *pidText = [NSString stringWithFormat:@"%d\n", getpid()];
            ftruncate(fd, 0);
            lseek(fd, 0, SEEK_SET);
            write(fd, pidText.UTF8String, strlen(pidText.UTF8String));
            fsync(fd);
            slotAliveFD = fd;
        } else {
            close(fd);
        }
    }
}

static void releaseRunnerLocks(void) {
    if (guestWriterFD >= 0) {
        flock(guestWriterFD, LOCK_UN);
        close(guestWriterFD);
        guestWriterFD = -1;
    }
    if (slotAliveFD >= 0) {
        flock(slotAliveFD, LOCK_UN);
        close(slotAliveFD);
        slotAliveFD = -1;
    }
}

BOOL ICIsSlotAlive(NSString *slotID) {
    if (!slotID.length) return NO;
    if ([ICCurrentRole() isEqualToString:slotID] && slotAliveFD >= 0) return YES;
    NSString *path = aliveLockPath(slotID);
    int fd = open(path.fileSystemRepresentation, O_CREAT | O_RDWR, 0600);
    if (fd < 0) return NO;
    int rc = flock(fd, LOCK_EX | LOCK_NB);
    if (rc == 0) {
        flock(fd, LOCK_UN);
        close(fd);
        return NO;
    }
    BOOL alive = (errno == EWOULDBLOCK || errno == EAGAIN);
    close(fd);
    return alive;
}

BOOL ICWaitForSlotExit(NSString *slotID, NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:MAX(0.05, timeout)];
    while ([deadline timeIntervalSinceNow] > 0) {
        if (!ICIsSlotAlive(slotID)) return YES;
        usleep(25000);
    }
    return !ICIsSlotAlive(slotID);
}

static void updateRegistryTransaction(void (^block)(NSMutableDictionary *registry)) {
    NSString *lockFile = registryLockPath();
    int fd = open(lockFile.fileSystemRepresentation, O_CREAT | O_RDWR, 0600);
    if (fd >= 0) flock(fd, LOCK_EX);
    NSData *raw = [NSData dataWithContentsOfFile:registryPath()];
    NSDictionary *existing = raw ? [NSJSONSerialization JSONObjectWithData:raw options:0 error:nil] : nil;
    NSMutableDictionary *reg = [existing isKindOfClass:NSDictionary.class] ? [existing mutableCopy] : [NSMutableDictionary new];
    if (![reg[@"slots"] isKindOfClass:NSDictionary.class]) reg[@"slots"] = @{};
    NSMutableDictionary *slots = [reg[@"slots"] mutableCopy];
    reg[@"slots"] = slots;
    reg[@"schema"] = @1;
    block(reg);
    NSData *out = [NSJSONSerialization dataWithJSONObject:reg options:NSJSONWritingPrettyPrinted error:nil];
    if (out) [out writeToFile:registryPath() options:NSDataWritingAtomic error:nil];
    if (fd >= 0) {
        flock(fd, LOCK_UN);
        close(fd);
    }
}

void ICRecordRoleProbe(void) {
    ICContainerRoot();
    acquireRunnerAliveLockIfNeeded();
    NSString *role = ICCurrentRole();
    NSString *counterpartRole = [role isEqualToString:@"manager"] ? @"runner1" : @"manager";
    NSString *counterpartFile = [probesDir() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", counterpartRole]];
    NSData *counterpartData = [NSData dataWithContentsOfFile:counterpartFile];
    NSDictionary *counterpart = counterpartData ? [NSJSONSerialization JSONObjectWithData:counterpartData options:0 error:nil] : nil;
    NSDictionary *probe = @{
        @"role": role,
        @"bundle_id": rawHostBundleID(),
        @"pid": @(getpid()),
        @"shared_group_available": @(sharedGroupOK),
        @"shared_group_id": sharedGroupID ?: @"",
        @"root_path": rootPath ?: @"",
        @"counterpart_probe_readable": @([counterpart isKindOfClass:NSDictionary.class]),
        @"timestamp": @([NSDate.date timeIntervalSince1970]),
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:probe options:NSJSONWritingPrettyPrinted error:nil];
    NSString *target = [probesDir() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", role]];
    if (json) [json writeToFile:target options:NSDataWritingAtomic error:nil];
}

NSDictionary *ICReadProbeSummary(void) {
    ICRecordRoleProbe();
    NSData *mData = [NSData dataWithContentsOfFile:[probesDir() stringByAppendingPathComponent:@"manager.json"]];
    NSData *rData = [NSData dataWithContentsOfFile:[probesDir() stringByAppendingPathComponent:@"runner1.json"]];
    NSData *regData = [NSData dataWithContentsOfFile:registryPath()];
    NSDictionary *mDict = mData ? [NSJSONSerialization JSONObjectWithData:mData options:0 error:nil] : nil;
    NSDictionary *rDict = rData ? [NSJSONSerialization JSONObjectWithData:rData options:0 error:nil] : nil;
    NSDictionary *regDict = regData ? [NSJSONSerialization JSONObjectWithData:regData options:0 error:nil] : nil;
    BOOL runner1Alive = ICIsSlotAlive(@"runner1");
    return @{
        @"shared_group_available": @(sharedGroupOK),
        @"shared_group_id": sharedGroupID ?: @"",
        @"root_path": rootPath ?: @"",
        @"current_role": ICCurrentRole(),
        @"current_bundle_id": rawHostBundleID(),
        @"manager_probe": [mDict isKindOfClass:NSDictionary.class] ? mDict : @{},
        @"runner1_probe": [rDict isKindOfClass:NSDictionary.class] ? rDict : @{},
        @"runner1_alive_in_ram": @(runner1Alive),
        @"slot_registry": [regDict isKindOfClass:NSDictionary.class] ? regDict : @{},
    };
}

static BOOL validIdentifier(NSString *identifier) {
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:identifier];
    return uuid != nil && [uuid.UUIDString caseInsensitiveCompare:identifier] == NSOrderedSame;
}

static NSString *verifiedPath(NSString *path, NSString *parent) {
    NSString *p = path.stringByResolvingSymlinksInPath.stringByStandardizingPath;
    NSString *r = [parent.stringByResolvingSymlinksInPath.stringByStandardizingPath stringByAppendingString:@"/"];
    return [p hasPrefix:r] ? p : nil;
}

static NSString *expectedBundleIDForSlot(NSString *slotID) {
    NSData *rData = [NSData dataWithContentsOfFile:[probesDir() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", slotID]]];
    NSDictionary *rDict = rData ? [NSJSONSerialization JSONObjectWithData:rData options:0 error:nil] : nil;
    NSString *probed = [rDict isKindOfClass:NSDictionary.class] ? rDict[@"bundle_id"] : nil;
    if ([probed isKindOfClass:NSString.class] && probed.length > 0) return probed;
    NSString *team = extractTeamSuffix(rawHostBundleID());
    if ([slotID isEqualToString:@"runner1"] || [slotID isEqualToString:@"runner2"]) {
        if (team.length > 0) {
            return [NSString stringWithFormat:@"com.hongson117.sicontainer.%@.%@", team, slotID];
        }
        return [NSString stringWithFormat:@"com.hongson117.sicontainer.%@", slotID];
    }
    return rawHostBundleID();
}

static NSString *preparedAppPathForBundle(NSString *guestDir, NSString *targetBundleID) {
    NSString *preparedRoot = [guestDir stringByAppendingPathComponent:@"Prepared"];
    NSString *perSlot = [preparedRoot stringByAppendingPathComponent:targetBundleID];
    NSString *candidate = [perSlot stringByAppendingPathComponent:@"Prepared.app"];
    if ([NSFileManager.defaultManager fileExistsAtPath:[candidate stringByAppendingPathComponent:@"iContainerLaunch.json"]]) {
        return candidate;
    }
    NSString *team = extractTeamSuffix(targetBundleID);
    for (NSString *role in @[@"runner1", @"runner2"]) {
        if ([targetBundleID containsString:[@"." stringByAppendingString:role]] && team.length > 0) {
            NSArray<NSString *> *altIDs = @[
                [NSString stringWithFormat:@"com.hongson117.sicontainer.%@.%@", team, role],
                [NSString stringWithFormat:@"com.hongson117.sicontainer.%@.%@", role, team],
            ];
            for (NSString *alt in altIDs) {
                NSString *altApp = [[preparedRoot stringByAppendingPathComponent:alt] stringByAppendingPathComponent:@"Prepared.app"];
                if ([NSFileManager.defaultManager fileExistsAtPath:[altApp stringByAppendingPathComponent:@"iContainerLaunch.json"]]) {
                    return altApp;
                }
            }
        }
    }
    return [guestDir stringByAppendingPathComponent:@"Prepared.app"];
}

BOOL ICQueueGuest(NSString *identifier, NSError **error) {
    if (!validIdentifier(identifier)) {
        if (error) *error = [NSError errorWithDomain:@"SIContainer" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Danh tính app không hợp lệ."}];
        return NO;
    }
    NSString *dir = [ICContainerRoot() stringByAppendingPathComponent:identifier];
    NSString *prepared = preparedAppPathForBundle(dir, rawHostBundleID());
    NSData *data = [NSData dataWithContentsOfFile:[prepared stringByAppendingPathComponent:@"iContainerLaunch.json"]];
    NSDictionary *manifest = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:error] : nil;
    if (![manifest isKindOfClass:NSDictionary.class] || ![manifest[@"prepared"] boolValue] || ![manifest[@"id"] isEqual:identifier]) {
        if (error && !*error) *error = [NSError errorWithDomain:@"SIContainer" code:2 userInfo:@{NSLocalizedDescriptionKey: @"App chưa được chuẩn bị. Chọn nguồn ký rồi chuẩn bị lại."}];
        return NO;
    }
    if ([manifest[@"preparation_revision"] integerValue] < 3) {
        if (error) *error = [NSError errorWithDomain:@"SIContainer" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Chọn Chuẩn bị lại để sửa bản chạy cũ. App gốc và dữ liệu được giữ nguyên."}];
        return NO;
    }
    NSDictionary *ticket = @{@"id": identifier, @"created": @([NSDate.date timeIntervalSince1970])};
    NSData *plist = [NSPropertyListSerialization dataWithPropertyList:ticket format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    return plist && [plist writeToFile:ticketPath() options:NSDataWritingAtomic error:error];
}

NSDictionary *ICPrepareRunnerLaunch(NSString *identifier, NSString *slotID, NSError **error) {
    if (!validIdentifier(identifier)) {
        if (error) *error = [NSError errorWithDomain:@"SIContainer" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Danh tính app không hợp lệ."}];
        return nil;
    }
    if (!ICSharedGroupAvailable()) {
        if (error) *error = [NSError errorWithDomain:@"SIContainer" code:10 userInfo:@{NSLocalizedDescriptionKey: @"Chưa có quyền App Group dùng chung giữa Chính và Phụ. Hãy kiểm tra chứng chỉ ký hoặc chạy trực tiếp ở chế độ Ghim Slot."}];
        return nil;
    }
    NSString *targetSlot = slotID.length ? slotID : @"runner1";
    NSString *targetBundleID = expectedBundleIDForSlot(targetSlot);
    NSString *dir = [ICContainerRoot() stringByAppendingPathComponent:identifier];
    NSString *prepared = preparedAppPathForBundle(dir, targetBundleID);
    NSData *data = [NSData dataWithContentsOfFile:[prepared stringByAppendingPathComponent:@"iContainerLaunch.json"]];
    NSDictionary *manifest = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:error] : nil;
    if (![manifest isKindOfClass:NSDictionary.class] || ![manifest[@"prepared"] boolValue] || ![manifest[@"id"] isEqual:identifier]) {
        if (error && !*error) *error = [NSError errorWithDomain:@"SIContainer" code:2 userInfo:@{NSLocalizedDescriptionKey: @"App chưa được chuẩn bị cho Slot Phụ. Bấm Chuẩn bị trước khi chạy."}];
        return nil;
    }
    if ([manifest[@"preparation_revision"] integerValue] < 3 || ![manifest[@"host_bundle_id"] isEqual:targetBundleID]) {
        if (error) *error = [NSError errorWithDomain:@"SIContainer" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Bản chuẩn bị chưa khớp danh tính của SIContainer Phụ 1. Hãy chọn Chuẩn bị lại."}];
        return nil;
    }
    if ([manifest[@"certificate_expires"] doubleValue] <= [NSDate.date timeIntervalSince1970]) {
        if (error) *error = [NSError errorWithDomain:@"SIContainer" code:4 userInfo:@{NSLocalizedDescriptionKey: @"Chứng chỉ đã hết hạn. Hãy gia hạn và Chuẩn bị lại."}];
        return nil;
    }

    NSString *scheme = [NSString stringWithFormat:@"sicontainer-%@", targetSlot];
    BOOL alive = ICIsSlotAlive(targetSlot);
    __block NSString *activeGuestID = nil;
    __block NSString *ackedRequestID = nil;
    updateRegistryTransaction(^(NSMutableDictionary *registry) {
        NSDictionary *slotEntry = registry[@"slots"][targetSlot];
        if ([slotEntry isKindOfClass:NSDictionary.class]) {
            activeGuestID = slotEntry[@"guest_id"];
            ackedRequestID = slotEntry[@"acked_request_id"];
        }
    });

    // If Runner 1 is already alive in RAM and running this exact guest, resume without reloading.
    if (alive && [activeGuestID isEqualToString:identifier] && ackedRequestID.length > 0 && ![[NSFileManager defaultManager] fileExistsAtPath:slotTicketPath(targetSlot)]) {
        NSString *urlStr = [NSString stringWithFormat:@"%@://resume?guest=%@&req=%@", scheme, identifier, ackedRequestID];
        return @{@"action": @"resume", @"slot": targetSlot, @"request_id": ackedRequestID, @"url": urlStr};
    }

    NSString *requestID = [NSUUID UUID].UUIDString;
    NSTimeInterval now = [NSDate.date timeIntervalSince1970];
    NSDictionary *ticket = @{
        @"request_id": requestID,
        @"id": identifier,
        @"slot": targetSlot,
        @"target_bundle_id": targetBundleID,
        @"evict_previous": @(alive && activeGuestID != nil && ![activeGuestID isEqualToString:identifier]),
        @"created": @(now),
    };
    NSData *plist = [NSPropertyListSerialization dataWithPropertyList:ticket format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!plist || ![plist writeToFile:slotTicketPath(targetSlot) options:NSDataWritingAtomic error:error]) {
        return nil;
    }

    // Record pending request in slot-registry WITHOUT updating last_active_at.
    updateRegistryTransaction(^(NSMutableDictionary *registry) {
        NSMutableDictionary *slots = registry[@"slots"];
        NSMutableDictionary *entry = [slots[targetSlot] isKindOfClass:NSDictionary.class] ? [slots[targetSlot] mutableCopy] : [NSMutableDictionary new];
        entry[@"slot_id"] = targetSlot;
        entry[@"bundle_id"] = targetBundleID;
        entry[@"pending_request_id"] = requestID;
        entry[@"pending_guest_id"] = identifier;
        entry[@"state"] = alive ? @"switching" : @"launching";
        slots[targetSlot] = entry;
    });

    if (alive && activeGuestID != nil && ![activeGuestID isEqualToString:identifier]) {
        NSString *notifyName = [NSString stringWithFormat:@"com.hongson117.sicontainer.%@.evict", targetSlot];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFStringRef)notifyName, NULL, NULL, true);
        if (ICWaitForSlotExit(targetSlot, 0.45)) {
            NSString *urlStr = [NSString stringWithFormat:@"%@://launch?req=%@&guest=%@", scheme, requestID, identifier];
            return @{@"action": @"launch_after_darwin_exit", @"slot": targetSlot, @"request_id": requestID, @"url": urlStr};
        }
        NSString *urlStr = [NSString stringWithFormat:@"%@://evict?req=%@&guest=%@", scheme, requestID, identifier];
        return @{@"action": @"wake_to_evict", @"slot": targetSlot, @"request_id": requestID, @"url": urlStr};
    }

    NSString *urlStr = [NSString stringWithFormat:@"%@://launch?req=%@&guest=%@", scheme, requestID, identifier];
    return @{@"action": @"launch", @"slot": targetSlot, @"request_id": requestID, @"url": urlStr};
}

NSURL *ICCompleteRunnerSwitchURL(NSString *slotID, NSString *requestID) {
    NSString *targetSlot = slotID.length ? slotID : @"runner1";
    ICWaitForSlotExit(targetSlot, 1.5);
    NSString *scheme = [NSString stringWithFormat:@"sicontainer-%@", targetSlot];
    NSString *urlStr = [NSString stringWithFormat:@"%@://launch?req=%@", scheme, requestID ?: @""];
    return [NSURL URLWithString:urlStr];
}

static NSBundle *mainBundle(id self, SEL cmd) { return guestBundle; }
static NSDictionary *infoDictionary(id self, SEL cmd) {
    if (self == hostBundle) return guestInfo;
    return ((NSDictionary *(*)(id, SEL))originalInfo)(self, cmd);
}
static id objectForKey(id self, SEL cmd, NSString *key) {
    if (self == hostBundle) return guestInfo[key];
    return ((id (*)(id, SEL, id))originalObject)(self, cmd, key);
}
static NSBundle *bundleForClass(id self, SEL cmd, Class cls) {
    const char *path = class_getImageName(cls);
    if (path && [[NSString stringWithUTF8String:path] hasPrefix:[guestBundle.bundlePath stringByAppendingString:@"/"]]) return guestBundle;
    return ((NSBundle *(*)(id, SEL, Class))originalForClass)(self, cmd, cls);
}
static NSURL *directoryURL(NSSearchPathDirectory directory) {
    NSString *sub = nil;
    switch (directory) {
        case NSDocumentDirectory: sub = @"Documents"; break;
        case NSLibraryDirectory: sub = @"Library"; break;
        case NSApplicationSupportDirectory: sub = @"Library/Application Support"; break;
        case NSCachesDirectory: sub = @"Library/Caches"; break;
        default: return nil;
    }
    NSString *path = [guestData stringByAppendingPathComponent:sub];
    [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    return [NSURL fileURLWithPath:path isDirectory:YES];
}
static NSArray *URLsForDirectory(id self, SEL cmd, NSSearchPathDirectory dir, NSSearchPathDomainMask domain) {
    NSURL *url = (domain & NSUserDomainMask) ? directoryURL(dir) : nil;
    return url ? @[url] : ((id (*)(id, SEL, NSUInteger, NSUInteger))originalURLs)(self, cmd, dir, domain);
}
static NSURL *URLForDirectory(id self, SEL cmd, NSSearchPathDirectory dir, NSSearchPathDomainMask domain, NSURL *appropriate, BOOL create, NSError **error) {
    NSURL *url = (domain & NSUserDomainMask) ? directoryURL(dir) : nil;
    return url ?: ((id (*)(id, SEL, NSUInteger, NSUInteger, id, BOOL, NSError **))originalURL)(self, cmd, dir, domain, appropriate, create, error);
}
static NSUserDefaults *standardDefaults(id self, SEL cmd) { return guestDefaults; }

static void installContext(void) {
    hostBundle = NSBundle.mainBundle;
    originalMainBundle = method_setImplementation(class_getClassMethod(NSBundle.class, @selector(mainBundle)), (IMP)mainBundle);
    originalInfo = method_setImplementation(class_getInstanceMethod(NSBundle.class, @selector(infoDictionary)), (IMP)infoDictionary);
    originalObject = method_setImplementation(class_getInstanceMethod(NSBundle.class, @selector(objectForInfoDictionaryKey:)), (IMP)objectForKey);
    originalForClass = method_setImplementation(class_getClassMethod(NSBundle.class, @selector(bundleForClass:)), (IMP)bundleForClass);
    originalURLs = method_setImplementation(class_getInstanceMethod(NSFileManager.class, @selector(URLsForDirectory:inDomains:)), (IMP)URLsForDirectory);
    originalURL = method_setImplementation(class_getInstanceMethod(NSFileManager.class, @selector(URLForDirectory:inDomain:appropriateForURL:create:error:)), (IMP)URLForDirectory);
    NSString *identity = guestData.stringByDeletingLastPathComponent.lastPathComponent;
    NSString *suite = sharedGroupOK && sharedGroupID.length
        ? [NSString stringWithFormat:@"%@.guest.%@", sharedGroupID, identity]
        : [@"com.hongson117.sicontainer.guest." stringByAppendingString:identity];
    guestDefaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    originalDefaults = method_setImplementation(class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults)), (IMP)standardDefaults);
    setenv("HOME", guestData.fileSystemRepresentation, 1);
    setenv("CFFIXED_USER_HOME", guestData.fileSystemRepresentation, 1);
    setenv("TMPDIR", [guestData stringByAppendingPathComponent:@"tmp"].fileSystemRepresentation, 1);
    chdir(guestData.fileSystemRepresentation);
}

static void restoreContext(void) {
    if (!originalMainBundle) return;
    method_setImplementation(class_getClassMethod(NSBundle.class, @selector(mainBundle)), originalMainBundle);
    method_setImplementation(class_getInstanceMethod(NSBundle.class, @selector(infoDictionary)), originalInfo);
    method_setImplementation(class_getInstanceMethod(NSBundle.class, @selector(objectForInfoDictionaryKey:)), originalObject);
    method_setImplementation(class_getClassMethod(NSBundle.class, @selector(bundleForClass:)), originalForClass);
    method_setImplementation(class_getInstanceMethod(NSFileManager.class, @selector(URLsForDirectory:inDomains:)), originalURLs);
    method_setImplementation(class_getInstanceMethod(NSFileManager.class, @selector(URLForDirectory:inDomain:appropriateForURL:create:error:)), originalURL);
    method_setImplementation(class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults)), originalDefaults);
}

static void flushGuestStateBeforeExit(void) {
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationWillResignActiveNotification object:UIApplication.sharedApplication];
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidEnterBackgroundNotification object:UIApplication.sharedApplication];
    if (guestDefaults) [guestDefaults synchronize];
    CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
    releaseRunnerLocks();
}

static void checkPendingEvictionOrTouchLRU(BOOL isForegroundWakeup) {
    if (!ICIsRunnerProcess() || !loadedGuestID.length) return;
    NSString *role = ICCurrentRole();
    NSDictionary *pending = [NSDictionary dictionaryWithContentsOfFile:slotTicketPath(role)];
    NSString *pendingReq = [pending isKindOfClass:NSDictionary.class] ? pending[@"request_id"] : nil;
    NSString *pendingGuest = [pending isKindOfClass:NSDictionary.class] ? pending[@"id"] : nil;
    if (pendingReq.length > 0 && ![pendingReq isEqualToString:loadedRequestID ?: @""] && pendingGuest.length > 0) {
        if (!isForegroundWakeup && UIApplication.sharedApplication.applicationState == UIApplicationStateInactive) {
            // Process is mid-transition to foreground via sicontainer-runner1://evict; let DidBecomeActive bounce cleanly.
            return;
        }
        if (__sync_bool_compare_and_swap(&evictingInProgress, 0, 1)) {
            flushGuestStateBeforeExit();
            if (isForegroundWakeup || UIApplication.sharedApplication.applicationState != UIApplicationStateBackground) {
                NSString *bounce = [NSString stringWithFormat:@"sicontainer://complete-switch?slot=%@&req=%@", role, pendingReq];
                NSURL *url = [NSURL URLWithString:bounce];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL success) {
                        _exit(0);
                    }];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        _exit(0);
                    });
                });
            } else {
                _exit(0);
            }
        }
        return;
    }
    if (isForegroundWakeup) {
        NSTimeInterval now = [NSDate.date timeIntervalSince1970];
        updateRegistryTransaction(^(NSMutableDictionary *registry) {
            NSMutableDictionary *slots = registry[@"slots"];
            NSMutableDictionary *entry = [slots[role] isKindOfClass:NSDictionary.class] ? [slots[role] mutableCopy] : [NSMutableDictionary new];
            if ([entry[@"guest_id"] isEqual:loadedGuestID]) {
                entry[@"last_active_at"] = @(now);
                entry[@"state"] = @"running";
                slots[role] = entry;
            }
        });
    }
}

static void darwinEvictCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    checkPendingEvictionOrTouchLRU(NO);
}

@interface ICReturnController : UIViewController
@end
@interface ICReturnWindow : UIWindow
@end
@implementation ICReturnWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (!self.rootViewController.presentedViewController && (hit == self.rootViewController.view || hit == self)) return nil;
    return hit;
}
@end
@implementation ICReturnController
- (void)viewDidLoad {
    [super viewDidLoad];
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    self.view.backgroundColor = UIColor.clearColor;
    button.frame = CGRectMake(12, 70, 146, 38);
    NSString *title = ICIsRunnerProcess() ? @"↩ SIContainer" : @"↩ Container";
    [button setTitle:title forState:UIControlStateNormal];
    button.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.88];
    button.tintColor = UIColor.whiteColor;
    button.layer.cornerRadius = 18;
    [button addTarget:self action:@selector(back) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:button];
}
- (void)back {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"SIContainer"
                                                                   message:@"Bạn có thể chuyển nhanh về trình quản lý SIContainer (giữ nguyên app này chạy nền trong RAM) hoặc đóng hẳn app này."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    if (ICIsRunnerProcess()) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Về SIContainer (Giữ chạy nền)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            NSURL *url = [NSURL URLWithString:@"sicontainer://"];
            [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Đóng hẳn app này" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        NSString *role = ICCurrentRole();
        updateRegistryTransaction(^(NSMutableDictionary *registry) {
            NSMutableDictionary *slots = registry[@"slots"];
            NSMutableDictionary *entry = [slots[role] isKindOfClass:NSDictionary.class] ? [slots[role] mutableCopy] : [NSMutableDictionary new];
            entry[@"state"] = @"idle";
            [entry removeObjectForKey:@"guest_id"];
            slots[role] = entry;
        });
        flushGuestStateBeforeExit();
        _exit(0);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end

static void installReturnButton(void) {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        returnWindow = [[ICReturnWindow alloc] initWithWindowScene:(UIWindowScene *)s];
        break;
    }
    if (!returnWindow) returnWindow = [[ICReturnWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    returnWindow.backgroundColor = UIColor.clearColor;
    returnWindow.windowLevel = UIWindowLevelAlert + 1;
    returnWindow.rootViewController = [ICReturnController new];
    returnWindow.hidden = NO;
}

static BOOL acquireExclusiveGuestWriterLock(NSString *dataPath) {
    NSString *lockPath = [dataPath stringByAppendingPathComponent:@".writer.lock"];
    int fd = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDWR, 0600);
    if (fd < 0) return NO;
    for (int attempt = 0; attempt < 80; attempt++) {
        if (flock(fd, LOCK_EX | LOCK_NB) == 0) {
            NSString *info = [NSString stringWithFormat:@"%@:%d\n", rawHostBundleID(), getpid()];
            ftruncate(fd, 0);
            lseek(fd, 0, SEEK_SET);
            write(fd, info.UTF8String, strlen(info.UTF8String));
            fsync(fd);
            guestWriterFD = fd;
            return YES;
        }
        usleep(25000);
    }
    close(fd);
    return NO;
}

int ICBootGuest(void) {
    NSString *root = ICContainerRoot();
    ICRecordRoleProbe();
    NSString *role = ICCurrentRole();
    NSString *activeTicketFile = ICIsRunnerProcess() ? slotTicketPath(role) : ticketPath();
    NSDictionary *ticket = [NSDictionary dictionaryWithContentsOfFile:activeTicketFile];
    if (!ticket) return -1;
    // Consume first, even if any following validation or guest initialization fails.
    [NSFileManager.defaultManager removeItemAtPath:activeTicketFile error:nil];

    NSString *identifier = ticket[@"id"];
    NSString *requestID = [ticket[@"request_id"] isKindOfClass:NSString.class] ? ticket[@"request_id"] : [NSUUID UUID].UUIDString;
    NSTimeInterval age = [NSDate.date timeIntervalSince1970] - [ticket[@"created"] doubleValue];
    if (![identifier isKindOfClass:NSString.class] || !validIdentifier(identifier) || age < -5 || age > 600) {
        fail(@"Yêu cầu mở app đã hết hạn. Chọn Chạy lại.");
        return -1;
    }

    NSString *myBundleID = rawHostBundleID();
    NSString *dir = verifiedPath([root stringByAppendingPathComponent:identifier], root);
    NSString *preparedCandidate = dir ? preparedAppPathForBundle(dir, myBundleID) : nil;
    NSString *app = (dir && preparedCandidate) ? verifiedPath(preparedCandidate, dir) : nil;
    NSData *data = app ? [NSData dataWithContentsOfFile:[app stringByAppendingPathComponent:@"iContainerLaunch.json"]] : nil;
    NSDictionary *manifest = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![manifest isKindOfClass:NSDictionary.class] || ![manifest[@"id"] isEqual:identifier] || ![manifest[@"prepared"] boolValue]) {
        fail(@"Không đọc được bản app đã chuẩn bị.");
        return -1;
    }
    if ([manifest[@"preparation_revision"] integerValue] < 3) {
        fail(@"Bản chạy cũ cần Chuẩn bị lại. App gốc và dữ liệu được giữ nguyên.");
        return -1;
    }
    if (![manifest[@"host_bundle_id"] isEqual:myBundleID] || [manifest[@"certificate_expires"] doubleValue] <= [NSDate.date timeIntervalSince1970]) {
        fail(@"Chứng chỉ hoặc danh tính Slot host đã thay đổi/hết hạn. Chọn Chuẩn bị lại bằng nguồn ký hiện tại.");
        return -1;
    }

    guestBundle = [NSBundle bundleWithPath:app];
    guestInfo = [NSDictionary dictionaryWithContentsOfFile:[app stringByAppendingPathComponent:@"Info.plist"]];
    NSString *exe = manifest[@"executable"];
    if (![exe isKindOfClass:NSString.class] || ![exe isEqual:exe.lastPathComponent]) {
        fail(@"Executable không hợp lệ.");
        return -1;
    }
    NSString *execPath = verifiedPath([app stringByAppendingPathComponent:exe], app);
    uint64_t entry = [manifest[@"entry_offset"] unsignedLongLongValue];
    if (!execPath || !guestBundle || !guestInfo || entry == 0) {
        fail(@"Thiếu executable hoặc entry point.");
        return -1;
    }
    guestData = verifiedPath([dir stringByAppendingPathComponent:@"Data"], dir);
    if (!guestData) {
        fail(@"Vùng dữ liệu không hợp lệ.");
        return -1;
    }
    if (!acquireExclusiveGuestWriterLock(guestData)) {
        fail(@"Dữ liệu của app đang được giữ bởi một tiến trình khác. Vui lòng thử lại sau giây lát.");
        return -1;
    }

    [NSFileManager.defaultManager removeItemAtPath:errorPath() error:nil];
    loadedGuestID = identifier;
    loadedRequestID = requestID;

    NSString *frameworks = [app stringByAppendingPathComponent:@"Frameworks"];
    NSMutableArray<NSString *> *pending = [NSMutableArray new];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:frameworks error:nil]) {
        NSString *p = [frameworks stringByAppendingPathComponent:name];
        if ([name.pathExtension isEqual:@"framework"]) p = [[NSBundle bundleWithPath:p] executablePath];
        if (p && ([name.pathExtension isEqual:@"framework"] || [name.pathExtension isEqual:@"dylib"])) [pending addObject:p];
    }

    NSString *oldHome = NSHomeDirectory();
    NSString *oldTmp = NSTemporaryDirectory();
    installContext();
    for (NSUInteger round = 0; round < 8 && pending.count; round++) {
        BOOL progress = NO;
        for (NSString *p in pending.copy) {
            if (dlopen(p.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL)) {
                [pending removeObject:p];
                progress = YES;
            }
        }
        if (!progress) break;
    }
    void *handle = dlopen(execPath.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL | RTLD_FIRST);
    if (!handle) {
        const char *reason = dlerror();
        NSString *message = reason ? [NSString stringWithUTF8String:reason] : @"Không nạp được app.";
        restoreContext();
        setenv("HOME", oldHome.fileSystemRepresentation, 1);
        setenv("CFFIXED_USER_HOME", oldHome.fileSystemRepresentation, 1);
        setenv("TMPDIR", oldTmp.fileSystemRepresentation, 1);
        releaseRunnerLocks();
        fail([@"Mở app thất bại: " stringByAppendingString:message]);
        return 1;
    }

    const struct mach_header_64 *header = NULL;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && [[NSString stringWithUTF8String:name].stringByResolvingSymlinksInPath isEqual:execPath]) {
            header = (const struct mach_header_64 *)_dyld_get_image_header(i);
            break;
        }
    }
    if (!header || header->magic != MH_MAGIC_64) {
        releaseRunnerLocks();
        fail(@"Không tìm được ảnh Mach-O sau khi nạp.");
        return 1;
    }

    const uint8_t *cursor = (const uint8_t *)(header + 1);
    uintptr_t target = 0;
    const struct segment_command_64 *text = NULL;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (seg->fileoff == 0 && seg->filesize > 0) text = seg;
        }
        cursor += lc->cmdsize;
    }
    cursor = (const uint8_t *)(header + 1);
    for (uint32_t i = 0; text && i < header->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if ((seg->initprot & 4) && entry >= seg->fileoff && entry - seg->fileoff < seg->filesize) {
                target = (uintptr_t)header - text->vmaddr + seg->vmaddr + (uintptr_t)(entry - seg->fileoff);
            }
        }
        cursor += lc->cmdsize;
    }
    if (!target) {
        releaseRunnerLocks();
        fail(@"Entry point không nằm trong vùng mã thực thi.");
        return 1;
    }

    // Commit transactional ack and accurate LRU timestamp ONLY after runner verified & mapped the guest.
    NSTimeInterval now = [NSDate.date timeIntervalSince1970];
    NSString *guestName = [manifest[@"name"] isKindOfClass:NSString.class] ? manifest[@"name"] : identifier;
    updateRegistryTransaction(^(NSMutableDictionary *registry) {
        NSMutableDictionary *slots = registry[@"slots"];
        NSMutableDictionary *entryDict = [slots[role] isKindOfClass:NSDictionary.class] ? [slots[role] mutableCopy] : [NSMutableDictionary new];
        entryDict[@"slot_id"] = role;
        entryDict[@"bundle_id"] = myBundleID;
        entryDict[@"guest_id"] = identifier;
        entryDict[@"guest_name"] = guestName;
        entryDict[@"acked_request_id"] = requestID;
        entryDict[@"state"] = @"running";
        entryDict[@"last_active_at"] = @(now);
        entryDict[@"pid"] = @(getpid());
        [entryDict removeObjectForKey:@"pending_request_id"];
        [entryDict removeObjectForKey:@"pending_guest_id"];
        slots[role] = entryDict;
    });

    if (ICIsRunnerProcess()) {
        NSString *notifyName = [NSString stringWithFormat:@"com.hongson117.sicontainer.%@.evict", role];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, darwinEvictCallback, (__bridge CFStringRef)notifyName, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            beginRunnerBackgroundStandby();
        }];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            endRunnerBackgroundStandby();
            checkPendingEvictionOrTouchLRU(YES);
        }];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            endRunnerBackgroundStandby();
            checkPendingEvictionOrTouchLRU(YES);
        }];
    }

    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            installReturnButton();
        });
    }];

    char *guestArgv[] = {strdup(execPath.fileSystemRepresentation), NULL};
    int (*start)(int, char **, char **, char **) = (void *)target;
    extern char **environ;
    return start(1, guestArgv, environ, NULL);
}
