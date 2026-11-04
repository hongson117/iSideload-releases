#import <Foundation/Foundation.h>

/// Install before entering the guest's main function. Only internal runner URLs
/// are consumed. Other URLs and lifecycle callbacks retain their original path.
void SICInstallURLInterception(BOOL (^isInternalURL)(NSURL *), void (^handleURL)(NSURL *));
void SICRefreshURLInterceptionForActiveObjects(void);
