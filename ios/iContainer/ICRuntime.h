#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Root is captured before a guest changes its environment.
NSString *ICContainerRoot(void);
/// One-shot ticket, consumed BEFORE dlopen so a crashing guest cannot boot-loop.
BOOL ICQueueGuest(NSString *identifier, NSError **error);
/// -1: show host, otherwise the guest process return code.
int ICBootGuest(void);
NSString * _Nullable ICLastLaunchError(void);
NS_ASSUME_NONNULL_END
