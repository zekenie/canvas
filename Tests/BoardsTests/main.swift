import Foundation
import TestKit

// The menu test puts a real pop-up menu on screen for a moment, so it's opt-in: TEST_UI_MENUS=1.
let onScreen = ProcessInfo.processInfo.environment["TEST_UI_MENUS"] == "1"
runTests([openingTests, goingUpTests, pathTests, crumbMenuTests, windowTests, menuWindowTests] + (onScreen ? [menuTests] : []))
