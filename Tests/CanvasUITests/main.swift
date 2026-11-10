import Foundation
import TestKit

// The minimap marks what the canvas outlines in the accent color: blue here, whatever this Mac's is,
// before any window asks for it.
UserDefaults.standard.setVolatileDomain(["AppleAccentColor": 4], forName: UserDefaults.argumentDomain)
runTests([minimapTests, zoomIndicatorTests, pointerTests, popoverTests, cardViewTests, boardWindowTests, displayTests, toolPickerTests, menuPopUpTests, chromeTests, titleRowTests, keyboardShortcutsTests, menuBarTests, keyDriverTests, canvasAccessibilityTests, kitWindowTests, viewMemoryTests])
