import UIKit

// No SwiftUI host or account engine is initialized in guest mode.
let result = ICBootGuest()
if result >= 0 { exit(result) }
#if SICONTAINER_RUNNER
SIRunnerApp.main()
#else
iContainerApp.main()
#endif
