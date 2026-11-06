import TestKit

// The skills' tools where no app is needed (Package.swift's SkillToolsTests): nothing here touches a window, a pasteboard or the app's socket.
runTests(digestToolTests + [ingestScriptsTests, ingestLensTests, ingestBigScanTests, ingestPrepareTests, ingestLockfilesTests, ingestCheckoutTests, historyTests])
