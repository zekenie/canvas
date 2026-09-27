import Foundation
import TestKit

// The menu routing test puts a real context menu on screen for a moment, so it's opt-in: TEST_UI_MENUS=1.
let onScreen = ProcessInfo.processInfo.environment["TEST_UI_MENUS"] == "1"
pinAccentColor()     // before any test makes a window (Replay.swift)
runTests([shippedTests, persistenceTests, boardDocumentTests, transcriptTests, parityTests, canvasViewTests, inspectorTests, contentsPanelTests] + (onScreen ? [menuRoutingTests] : []))
