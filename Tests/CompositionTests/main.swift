import TestKit

pinAccentColor()     // before any test makes a window (Replay.swift)
runTests([shippedTests, transcriptTests, parityTests, canvasViewTests, inspectorTests])
