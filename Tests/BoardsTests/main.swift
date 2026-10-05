import Foundation
import TestKit

// The menu test puts the real "…" menu on screen for a moment, so it's opt-in: TEST_UI_MENUS=1.
let onScreen = ProcessInfo.processInfo.environment["TEST_UI_MENUS"] == "1"
runTests([openingTests, goingUpTests, boardPlaceholderTests, pathTests, crumbMenuTests, windowTests, menuWindowTests, followTests] + (onScreen ? [menuTests] : []))
