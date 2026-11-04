#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Root is captured before a guest changes its environment.
/// Uses the shared App Group (`group.com.hongson117.sicontainer.<TEAM>`) when available.
NSString *ICContainerRoot(void);
BOOL ICSharedGroupAvailable(void);
NSString * _Nullable ICSharedGroupID(void);
BOOL ICIsRunnerProcess(void);
NSString *ICCurrentRole(void);

/// Hardware Gate 1: record & inspect cross-bundle App Group + flock verification.
void ICRecordRoleProbe(void);
void ICRecordDiagnosticTrace(NSString *event, NSDictionary * _Nullable details);
NSDictionary *ICReadProbeSummary(void);
BOOL ICIsSlotAlive(NSString *slotID);
BOOL ICWaitForSlotExit(NSString *slotID, NSTimeInterval timeout);

/// One-shot local ticket (fallback when running in single-app mode).
BOOL ICQueueGuest(NSString *identifier, NSError **error);

/// Transactional multi-slot dispatch for Runner 1 (returns action & URL to open).
NSDictionary * _Nullable ICPrepareRunnerLaunch(NSString *identifier, NSString *slotID, NSError **error);
NSURL * _Nullable ICCompleteRunnerSwitchURL(NSString *slotID, NSString *requestID);
/// Consumes a runner URL in either the standby UI or a loaded guest process.
BOOL ICHandleRunnerURL(NSURL *url);

/// -1: show host/runner UI, otherwise the guest process return code.
int ICBootGuest(void);
NSString * _Nullable ICLastLaunchError(void);
NS_ASSUME_NONNULL_END
