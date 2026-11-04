// SIContainer experimental multi-slot iOS runtime. Original implementation, 2026.
// Separates Manager (router & signer) from Runner (guest host), uses per-slot
// Prepared.app bundles with shared guest Data/, kernel flock() liveness/writer
// locks, and transactional request/ack LRU tracking.
#import "ICRuntime.h"
#import "SICURLInterception.h"
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
static NSString *hostDocumentsDir;
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
static volatile int bounceOpenURLSent = 0;
static NSString *activeBounceRequestID = nil;
static UIBackgroundTaskIdentifier runnerBgTask = 0;

static void endRunnerBackgroundStandby(void) {
    if (runnerBgTask != 0 && runnerBgTask != UIBackgroundTaskInvalid) {
        [UIApplication.sharedApplication endBackgroundTask:runnerBgTask];
        runnerBgTask = 0;
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
        NSString *docDir = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject.path;
        if (docDir.length) {
            hostDocumentsDir = docDir;
            [fm createDirectoryAtPath:hostDocumentsDir withIntermediateDirectories:YES attributes:nil error:nil];
        }
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
static NSString *traceLogPath(void) { return [ICContainerRoot() stringByAppendingPathComponent:@"url-trace.jsonl"]; }
static NSString *traceLockPath(void) { return [slotsDir() stringByAppendingPathComponent:@"trace.lock"]; }
NSString *ICLastLaunchError(void) { return [NSString stringWithContentsOfFile:errorPath() encoding:NSUTF8StringEncoding error:nil]; }
static void fail(NSString *message) {
    [message writeToFile:errorPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    ICRecordDiagnosticTrace(@"fail", @{@"message": message ?: @""});
}

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

static BOOL updateRegistryTransaction(void (^block)(NSMutableDictionary *registry)) {
    NSString *lockFile = registryLockPath();
    int fd = open(lockFile.fileSystemRepresentation, O_CREAT | O_RDWR, 0600);
    if (fd < 0) return NO;
    if (flock(fd, LOCK_EX) != 0) { close(fd); return NO; }
    NSData *raw = [NSData dataWithContentsOfFile:registryPath()];
    NSDictionary *existing = raw ? [NSJSONSerialization JSONObjectWithData:raw options:0 error:nil] : nil;
    NSMutableDictionary *reg = [existing isKindOfClass:NSDictionary.class] ? [existing mutableCopy] : [NSMutableDictionary new];
    if (![reg[@"slots"] isKindOfClass:NSDictionary.class]) reg[@"slots"] = @{};
    NSMutableDictionary *slots = [reg[@"slots"] mutableCopy];
    reg[@"slots"] = slots;
    reg[@"schema"] = @1;
    block(reg);
    NSData *out = [NSJSONSerialization dataWithJSONObject:reg options:NSJSONWritingPrettyPrinted error:nil];
    BOOL saved = out && [out writeToFile:registryPath() options:NSDataWritingAtomic error:nil];
    flock(fd, LOCK_UN);
    close(fd);
    return saved;
}

static void syncDiagnosticSnapshot(NSArray<NSString *> *knownLines) {
    if (!hostDocumentsDir.length) return;
    NSArray<NSString *> *lines = knownLines;
    if (!lines) {
        NSString *existing = [NSString stringWithContentsOfFile:traceLogPath() encoding:NSUTF8StringEncoding error:nil] ?: @"";
        NSMutableArray<NSString *> *arr = [NSMutableArray new];
        for (NSString *line in [existing componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            if (line.length > 0) [arr addObject:line];
        }
        lines = arr;
    }
    NSMutableArray<NSDictionary *> *parsedTraces = [NSMutableArray new];
    for (NSString *line in lines) {
        NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *obj = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        if ([obj isKindOfClass:NSDictionary.class]) [parsedTraces addObject:obj];
    }
    NSData *regData = [NSData dataWithContentsOfFile:registryPath()];
    NSDictionary *regDict = regData ? [NSJSONSerialization JSONObjectWithData:regData options:0 error:nil] : nil;
    NSDictionary *ticketDict = [NSDictionary dictionaryWithContentsOfFile:slotTicketPath(@"runner1")];
    NSDictionary *snapshot = @{
        @"updated_at": @([NSDate.date timeIntervalSince1970]),
        @"role": ICCurrentRole(),
        @"bundle_id": rawHostBundleID(),
        @"pid": @(getpid()),
        @"loaded_guest_id": loadedGuestID ?: @"",
        @"loaded_request_id": loadedRequestID ?: @"",
        @"last_launch_error": ICLastLaunchError() ?: @"",
        @"runner1_alive_in_ram": @(ICIsSlotAlive(@"runner1")),
        @"slot_registry": [regDict isKindOfClass:NSDictionary.class] ? regDict : @{},
        @"runner1_ticket": [ticketDict isKindOfClass:NSDictionary.class] ? ticketDict : @{},
        @"url_trace": parsedTraces,
    };
    NSData *snapData = [NSJSONSerialization dataWithJSONObject:snapshot options:NSJSONWritingPrettyPrinted error:nil];
    if (snapData) {
        [snapData writeToFile:[hostDocumentsDir stringByAppendingPathComponent:@"sicontainer-diag.json"] options:NSDataWritingAtomic error:nil];
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
    syncDiagnosticSnapshot(nil);
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

void ICRecordDiagnosticTrace(NSString *event, NSDictionary *details) {
    ICContainerRoot();
    NSString *lockFile = traceLockPath();
    int fd = open(lockFile.fileSystemRepresentation, O_CREAT | O_RDWR, 0600);
    if (fd >= 0) flock(fd, LOCK_EX);

    NSMutableDictionary *entry = [NSMutableDictionary new];
    entry[@"ts"] = @([NSDate.date timeIntervalSince1970]);
    entry[@"role"] = ICCurrentRole();
    entry[@"pid"] = @(getpid());
    entry[@"loaded_guest_id"] = loadedGuestID ?: @"";
    entry[@"loaded_request_id"] = loadedRequestID ?: @"";
    entry[@"event"] = event ?: @"unknown";
    if ([details isKindOfClass:NSDictionary.class]) {
        entry[@"details"] = details;
    }

    NSString *logFile = traceLogPath();
    NSString *existing = [NSString stringWithContentsOfFile:logFile encoding:NSUTF8StringEncoding error:nil] ?: @"";
    NSMutableArray<NSString *> *lines = [NSMutableArray new];
    for (NSString *line in [existing componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if (line.length > 0) [lines addObject:line];
    }
    NSData *entryData = [NSJSONSerialization dataWithJSONObject:entry options:0 error:nil];
    if (entryData) {
        NSString *entryLine = [[NSString alloc] initWithData:entryData encoding:NSUTF8StringEncoding];
        if (entryLine.length) [lines addObject:entryLine];
    }
    while (lines.count > 60) {
        [lines removeObjectAtIndex:0];
    }
    NSString *joined = [[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
    [joined writeToFile:logFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
    syncDiagnosticSnapshot(lines);

    if (fd >= 0) {
        flock(fd, LOCK_UN);
        close(fd);
    }
}

static BOOL validIdentifier(NSString *identifier) {
    if (![identifier isKindOfClass:NSString.class]) return NO;
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
    if (![@[@"runner1", @"runner2"] containsObject:targetSlot]) {
        if (error) *error = [NSError errorWithDomain:@"SIContainer" code:11 userInfo:@{NSLocalizedDescriptionKey: @"Slot không hợp lệ."}];
        return nil;
    }
    identifier = [[NSUUID alloc] initWithUUIDString:identifier].UUIDString;
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
    __block NSDictionary *plan;
    __block NSError *writeError;
    __block BOOL needsEviction = NO;
    BOOL committed = updateRegistryTransaction(^(NSMutableDictionary *registry) {
        NSMutableDictionary *slots = registry[@"slots"];
        NSMutableDictionary *entry = [slots[targetSlot] isKindOfClass:NSDictionary.class] ? [slots[targetSlot] mutableCopy] : [NSMutableDictionary new];
        NSDictionary *pending = [NSDictionary dictionaryWithContentsOfFile:slotTicketPath(targetSlot)];
        NSString *activeGuestID = entry[@"guest_id"];
        NSString *ackedRequestID = entry[@"acked_request_id"];
        NSDictionary *probe = nil;
        NSData *probeData = [NSData dataWithContentsOfFile:[probesDir() stringByAppendingPathComponent:[targetSlot stringByAppendingString:@".json"]]];
        if (probeData) probe = [NSJSONSerialization JSONObjectWithData:probeData options:0 error:nil];
        BOOL sameProcess = [probe isKindOfClass:NSDictionary.class] && [entry[@"pid"] isEqual:probe[@"pid"]];
        if (alive && sameProcess && [activeGuestID isEqual:identifier] && ackedRequestID.length && !pending) {
            NSString *url = [NSString stringWithFormat:@"%@://resume?guest=%@&req=%@", scheme, identifier, ackedRequestID];
            plan = @{@"action": @"resume", @"slot": targetSlot, @"request_id": ackedRequestID, @"url": url};
            return;
        }

        NSTimeInterval now = [NSDate.date timeIntervalSince1970];
        NSTimeInterval age = now - [pending[@"created"] doubleValue];
        NSString *requestID = pending[@"request_id"];
        BOOL reuse = [pending[@"id"] isEqual:identifier] && [pending[@"target_bundle_id"] isEqual:targetBundleID] &&
            requestID.length && age >= -5 && age <= 30 && [entry[@"pending_request_id"] isEqual:requestID];
        needsEviction = alive && sameProcess && activeGuestID.length && ![activeGuestID isEqual:identifier];
        if (!reuse) {
            requestID = NSUUID.UUID.UUIDString;
            NSDictionary *ticket = @{@"request_id": requestID, @"id": identifier, @"slot": targetSlot,
                @"target_bundle_id": targetBundleID, @"evict_previous": @(needsEviction), @"created": @(now)};
            NSData *plist = [NSPropertyListSerialization dataWithPropertyList:ticket format:NSPropertyListBinaryFormat_v1_0 options:0 error:&writeError];
            if (!plist || ![plist writeToFile:slotTicketPath(targetSlot) options:NSDataWritingAtomic error:&writeError]) return;
        }
        entry[@"slot_id"] = targetSlot;
        entry[@"bundle_id"] = targetBundleID;
        entry[@"pending_request_id"] = requestID;
        entry[@"pending_guest_id"] = identifier;
        entry[@"state"] = alive ? @"switching" : @"launching";
        slots[targetSlot] = entry;
        NSString *action = needsEviction ? @"evict" : @"launch";
        NSString *url = [NSString stringWithFormat:@"%@://%@?req=%@&guest=%@", scheme, action, requestID, identifier];
        plan = @{@"action": action, @"slot": targetSlot, @"request_id": requestID, @"url": url};
    });
    if (!committed || !plan) {
        if (error) *error = writeError ?: [NSError errorWithDomain:@"SIContainer" code:12 userInfo:@{NSLocalizedDescriptionKey: @"Không lưu được yêu cầu mở app. Hãy thử lại."}];
        return nil;
    }
    ICRecordDiagnosticTrace(@"prepare_runner_launch", @{
        @"guest_id": identifier ?: @"",
        @"slot": targetSlot ?: @"",
        @"action": plan[@"action"] ?: @"",
        @"request_id": plan[@"request_id"] ?: @"",
        @"url": plan[@"url"] ?: @"",
        @"needs_eviction": @(needsEviction),
        @"alive": @(alive),
    });
    // The runner handles its own URL on the main queue. Never wait for our own
    // alive lock or send ourselves an eviction notification here.
    if (needsEviction && ![ICCurrentRole() isEqual:targetSlot]) {
        NSString *notifyName = [NSString stringWithFormat:@"com.hongson117.sicontainer.%@.evict", targetSlot];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFStringRef)notifyName, NULL, NULL, true);
        ICWaitForSlotExit(targetSlot, 0.45);
    }
    return plan;
}

NSURL *ICCompleteRunnerSwitchURL(NSString *slotID, NSString *requestID) {
    NSString *targetSlot = slotID.length ? slotID : @"runner1";
    if (![@[@"runner1", @"runner2"] containsObject:targetSlot] || !validIdentifier(requestID)) return nil;
    if (!ICWaitForSlotExit(targetSlot, 2.0)) {
        fail(@"Phụ chưa thoát xong. Hãy mở lại shortcut để thử lại.");
        return nil;
    }
    __block NSURL *url;
    updateRegistryTransaction(^(NSMutableDictionary *registry) {
        NSDictionary *ticket = [NSDictionary dictionaryWithContentsOfFile:slotTicketPath(targetSlot)];
        NSTimeInterval age = [NSDate.date timeIntervalSince1970] - [ticket[@"created"] doubleValue];
        if (![ticket[@"request_id"] isEqual:requestID] || age < -5 || age > 30 ||
            ![registry[@"slots"][targetSlot][@"pending_request_id"] isEqual:requestID]) return;
        NSString *urlStr = [NSString stringWithFormat:@"sicontainer-%@://launch?req=%@&guest=%@", targetSlot, requestID, ticket[@"id"]];
        url = [NSURL URLWithString:urlStr];
    });
    ICRecordDiagnosticTrace(@"complete_runner_switch", @{
        @"slot": targetSlot ?: @"",
        @"request_id": requestID ?: @"",
        @"url": url.absoluteString ?: @"",
        @"success": @(url != nil),
    });
    return url;
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
    // UIKit delivers lifecycle callbacks during the bounce. Synthetic
    // notifications cannot flush an arbitrary guest's database or scene state.
    if (guestDefaults) [guestDefaults synchronize];
    CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication);
    // Keep writer/alive locks until the kernel releases them at process exit.
    // Releasing here lets the Manager reopen a process which is still alive.
}

static void cancelPendingRunnerSwitch(NSString *role, NSString *requestID) {
    if (!role.length || !requestID.length) return;
    updateRegistryTransaction(^(NSMutableDictionary *registry) {
        NSString *tPath = slotTicketPath(role);
        NSDictionary *ticket = [NSDictionary dictionaryWithContentsOfFile:tPath];
        if ([ticket isKindOfClass:NSDictionary.class] && [ticket[@"request_id"] isEqual:requestID]) {
            [NSFileManager.defaultManager removeItemAtPath:tPath error:nil];
        }
        NSMutableDictionary *slots = registry[@"slots"];
        NSMutableDictionary *entry = [slots[role] isKindOfClass:NSDictionary.class] ? [slots[role] mutableCopy] : [NSMutableDictionary new];
        if ([entry[@"pending_request_id"] isEqual:requestID]) {
            [entry removeObjectForKey:@"pending_request_id"];
            [entry removeObjectForKey:@"pending_guest_id"];
            entry[@"pid"] = @(getpid());
            if (loadedGuestID.length) {
                entry[@"guest_id"] = loadedGuestID;
                if (loadedRequestID.length) entry[@"acked_request_id"] = loadedRequestID;
                entry[@"state"] = @"running";
            } else {
                [entry removeObjectForKey:@"guest_id"];
                [entry removeObjectForKey:@"acked_request_id"];
                entry[@"state"] = @"idle";
            }
            slots[role] = entry;
        }
    });
}

static void bounceRunnerToManager(NSString *requestID, NSUInteger attempts) {
    NSString *currentReq = activeBounceRequestID ?: requestID;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        if (attempts > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                bounceRunnerToManager(currentReq, attempts - 1);
            });
        } else {
            activeBounceRequestID = nil;
            bounceOpenURLSent = 0;
            evictingInProgress = 0;
            cancelPendingRunnerSwitch(ICCurrentRole(), currentReq);
            fail(@"Phụ chưa vào trạng thái hoạt động. Hãy mở lại shortcut.");
        }
        return;
    }
    bounceOpenURLSent = 1;
    NSString *bounce = [NSString stringWithFormat:@"sicontainer://complete-switch?slot=%@&req=%@", ICCurrentRole(), currentReq];
    ICRecordDiagnosticTrace(@"bounce_runner_to_manager", @{
        @"request_id": currentReq ?: @"",
        @"bounce_url": bounce ?: @"",
        @"app_state": @(UIApplication.sharedApplication.applicationState),
    });
    [UIApplication.sharedApplication openURL:[NSURL URLWithString:bounce] options:@{} completionHandler:^(BOOL success) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ICRecordDiagnosticTrace(@"bounce_open_url_result", @{
                @"request_id": currentReq ?: @"",
                @"success": @(success),
            });
            if (!success) {
                activeBounceRequestID = nil;
                bounceOpenURLSent = 0;
                evictingInProgress = 0;
                cancelPendingRunnerSwitch(ICCurrentRole(), currentReq);
                fail(@"Không mở được SIContainer Chính để hoàn tất chuyển app. Hãy kiểm tra app Chính đã được cài và còn hạn ký.");
                return;
            }
            // Yield for the real background callbacks. The Manager waits on the
            // alive lock, so this delay is never used as proof of termination.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                flushGuestStateBeforeExit();
                _exit(0);
            });
        });
    }];
}

static void startRunnerBounce(NSString *requestID) {
    activeBounceRequestID = requestID;
    if (__sync_bool_compare_and_swap(&evictingInProgress, 0, 1)) {
        bounceOpenURLSent = 0;
        bounceRunnerToManager(requestID, 40);
    }
}

static void checkPendingEvictionOrTouchLRU(BOOL isForegroundWakeup) {
    if (!ICIsRunnerProcess() || !loadedGuestID.length) return;
    NSString *role = ICCurrentRole();
    NSDictionary *pending = [NSDictionary dictionaryWithContentsOfFile:slotTicketPath(role)];
    NSString *pendingReq = [pending isKindOfClass:NSDictionary.class] ? pending[@"request_id"] : nil;
    NSString *pendingGuest = [pending isKindOfClass:NSDictionary.class] ? pending[@"id"] : nil;
    NSTimeInterval pendingAge = [NSDate.date timeIntervalSince1970] - [pending[@"created"] doubleValue];
    if (validIdentifier(pendingReq) && ![pendingReq isEqualToString:loadedRequestID ?: @""] && validIdentifier(pendingGuest) && pendingAge >= -5 && pendingAge <= 30) {
        ICRecordDiagnosticTrace(@"pending_eviction_detected", @{
            @"pending_request_id": pendingReq ?: @"",
            @"pending_guest_id": pendingGuest ?: @"",
            @"loaded_guest_id": loadedGuestID ?: @"",
            @"is_foreground": @(isForegroundWakeup),
            @"app_state": @(UIApplication.sharedApplication.applicationState),
        });
        if (!isForegroundWakeup && UIApplication.sharedApplication.applicationState == UIApplicationStateInactive) {
            // Process is mid-transition to foreground via sicontainer-runner1://evict; let DidBecomeActive bounce cleanly.
            return;
        }
        if (isForegroundWakeup || UIApplication.sharedApplication.applicationState != UIApplicationStateBackground) {
            startRunnerBounce(pendingReq);
        } else {
            if (__sync_bool_compare_and_swap(&evictingInProgress, 0, 1)) {
                flushGuestStateBeforeExit();
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
                if ([entry[@"pending_request_id"] isEqual:loadedRequestID]) {
                    [entry removeObjectForKey:@"pending_request_id"];
                    [entry removeObjectForKey:@"pending_guest_id"];
                }
                slots[role] = entry;
            }
        });
        ICRecordDiagnosticTrace(@"guest_running_ack", @{
            @"guest_id": loadedGuestID ?: @"",
            @"request_id": loadedRequestID ?: @"",
        });
    }
}

static BOOL isInternalRunnerURL(NSURL *url) {
    NSString *scheme = [@"sicontainer-" stringByAppendingString:ICCurrentRole()];
    return ICIsRunnerProcess() && [url.scheme.lowercaseString isEqual:scheme];
}

BOOL ICHandleRunnerURL(NSURL *url) {
    if (!isInternalRunnerURL(url)) return NO;
    ICRecordDiagnosticTrace(@"handle_runner_url_received", @{
        @"url": url.absoluteString ?: @"",
        @"loaded_guest_id": loadedGuestID ?: @"",
        @"loaded_request_id": loadedRequestID ?: @"",
        @"evicting": @(evictingInProgress),
    });
    NSString *action = url.host.lowercaseString;
    if (![@[@"launch", @"resume", @"evict"] containsObject:action]) return YES;
    if (evictingInProgress && bounceOpenURLSent) return YES;
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSMutableDictionary *query = [NSMutableDictionary new];
    for (NSURLQueryItem *item in components.queryItems) {
        if (query[item.name]) { fail(@"Link mở app có tham số trùng lặp."); return YES; }
        query[item.name] = item.value ?: @"";
    }
    NSString *guest = query[@"guest"];
    NSString *requestID = query[@"req"];
    if (guest && !validIdentifier(guest)) { fail(@"Danh tính app trong shortcut không hợp lệ."); return YES; }
    if (guest) guest = [[NSUUID alloc] initWithUUIDString:guest].UUIDString;
    if (requestID) {
        // A delayed URL from an earlier switch must never recreate an old ticket.
        if (!validIdentifier(requestID)) return YES;
        if ([requestID isEqual:loadedRequestID] && (!guest || [guest isEqual:loadedGuestID])) return YES;
        NSDictionary *pending = [NSDictionary dictionaryWithContentsOfFile:slotTicketPath(ICCurrentRole())];
        if (![pending[@"request_id"] isEqual:requestID] || (guest && ![pending[@"id"] isEqual:guest])) return YES;
        NSTimeInterval age = [NSDate.date timeIntervalSince1970] - [pending[@"created"] doubleValue];
        if (age < -5 || age > 30) return YES;
        guest = pending[@"id"];
    }
    if (!validIdentifier(guest)) { fail(@"Shortcut thiếu danh tính app."); return YES; }
    if ([guest isEqual:loadedGuestID] && !requestID && !evictingInProgress) {
        // UIKit has already brought the existing guest forward. No Manager hop,
        // ticket write, re-sign, or new guest process is needed.
        ICRecordDiagnosticTrace(@"handle_runner_url_decision", @{
            @"decision": @"resume_in_place",
            @"guest_id": guest ?: @"",
            @"loaded_guest_id": loadedGuestID ?: @"",
        });
        checkPendingEvictionOrTouchLRU(YES);
        return YES;
    }
    if (!requestID) {
        NSError *error;
        NSDictionary *plan = ICPrepareRunnerLaunch(guest, ICCurrentRole(), &error);
        if (!plan) { fail(error.localizedDescription ?: @"Không chuẩn bị được yêu cầu mở app."); return YES; }
        requestID = plan[@"request_id"];
    }
    ICRecordDiagnosticTrace(@"handle_runner_url_decision", @{
        @"decision": @"start_runner_bounce",
        @"guest_id": guest ?: @"",
        @"request_id": requestID ?: @"",
        @"loaded_guest_id": loadedGuestID ?: @"",
    });
    startRunnerBounce(requestID);
    return YES;
}

static void darwinEvictCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{ checkPendingEvictionOrTouchLRU(NO); });
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
    __block NSDictionary *ticket;
    // Consumption and dispatch share the same lock, preventing a read/remove
    // race from deleting a newer launch request.
    BOOL consumed = updateRegistryTransaction(^(NSMutableDictionary *registry) {
        ticket = [NSDictionary dictionaryWithContentsOfFile:activeTicketFile];
        if (ticket && ![NSFileManager.defaultManager removeItemAtPath:activeTicketFile error:nil]) ticket = nil;
        if (ICIsRunnerProcess()) {
            NSMutableDictionary *slots = registry[@"slots"];
            NSMutableDictionary *entry = [slots[role] isKindOfClass:NSDictionary.class] ? [slots[role] mutableCopy] : [NSMutableDictionary new];
            NSTimeInterval tAge = [NSDate.date timeIntervalSince1970] - [ticket[@"created"] doubleValue];
            if (ticket && (![entry[@"pending_request_id"] isEqual:ticket[@"request_id"]] || tAge < -5 || tAge > 30)) {
                if ([entry[@"pending_request_id"] isEqual:ticket[@"request_id"]]) {
                    [entry removeObjectForKey:@"pending_request_id"];
                    [entry removeObjectForKey:@"pending_guest_id"];
                }
                ticket = nil;
            }
            if (!ticket) {
                [entry removeObjectForKey:@"guest_id"];
                [entry removeObjectForKey:@"acked_request_id"];
                entry[@"state"] = @"idle";
                entry[@"pid"] = @(getpid());
                slots[role] = entry;
            }
        }
    });
    if (!consumed) return -1;
    if (!ticket) return -1;

    NSString *identifier = ticket[@"id"];
    NSString *requestID = [ticket[@"request_id"] isKindOfClass:NSString.class] ? ticket[@"request_id"] : [NSUUID UUID].UUIDString;
    NSTimeInterval age = [NSDate.date timeIntervalSince1970] - [ticket[@"created"] doubleValue];
    NSTimeInterval maxAge = ICIsRunnerProcess() ? 30 : 600;
    if (![identifier isKindOfClass:NSString.class] || !validIdentifier(identifier) || age < -5 || age > maxAge) {
        fail(@"Yêu cầu mở app đã hết hạn. Chọn Chạy lại.");
        return -1;
    }

    NSString *myBundleID = rawHostBundleID();
    if (ICIsRunnerProcess() && (![ticket[@"slot"] isEqual:role] || ![ticket[@"target_bundle_id"] isEqual:myBundleID])) {
        fail(@"Vé mở app không khớp Slot hiện tại.");
        return -1;
    }
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
    if (ICIsRunnerProcess()) SICInstallURLInterception(^BOOL(NSURL *url) {
        return isInternalRunnerURL(url);
    }, ^(NSURL *url) {
        ICHandleRunnerURL(url);
    });
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

    // Record Mach-O mapped ACK before entering guest main(); state transitions
    // to "running" and updates last_active_at when UIApplicationDidBecomeActive fires.
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
        entryDict[@"state"] = ICIsRunnerProcess() ? @"loaded" : @"running";
        if (!ICIsRunnerProcess() || !entryDict[@"last_active_at"]) {
            entryDict[@"last_active_at"] = @(now);
        }
        entryDict[@"pid"] = @(getpid());
        if ([entryDict[@"pending_request_id"] isEqual:requestID]) {
            [entryDict removeObjectForKey:@"pending_request_id"];
            [entryDict removeObjectForKey:@"pending_guest_id"];
        }
        slots[role] = entryDict;
    });
    ICRecordDiagnosticTrace(@"boot_guest_loaded", @{
        @"guest_id": identifier ?: @"",
        @"guest_name": guestName ?: @"",
        @"request_id": requestID ?: @"",
    });

    if (ICIsRunnerProcess()) {
        NSString *notifyName = [NSString stringWithFormat:@"com.hongson117.sicontainer.%@.evict", role];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, darwinEvictCallback, (__bridge CFStringRef)notifyName, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            beginRunnerBackgroundStandby();
        }];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            SICRefreshURLInterceptionForActiveObjects();
            endRunnerBackgroundStandby();
            checkPendingEvictionOrTouchLRU(YES);
        }];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            SICRefreshURLInterceptionForActiveObjects();
            endRunnerBackgroundStandby();
            checkPendingEvictionOrTouchLRU(YES);
        }];
    }

    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        if (ICIsRunnerProcess()) {
            SICRefreshURLInterceptionForActiveObjects();
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (ICIsRunnerProcess()) {
                SICRefreshURLInterceptionForActiveObjects();
            }
            installReturnButton();
        });
    }];

    char *guestArgv[] = {strdup(execPath.fileSystemRepresentation), NULL};
    int (*start)(int, char **, char **, char **) = (void *)target;
    extern char **environ;
    return start(1, guestArgv, environ, NULL);
}
