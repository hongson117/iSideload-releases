import UIKit

// No SwiftUI host or account engine is initialized in guest mode.
let result = ICBootGuest()
if result >= 0 { exit(result) }
iContainerApp.main()
