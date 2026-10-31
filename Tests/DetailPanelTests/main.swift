import Foundation
import TestKit

// A table's own paging (Page Down with no `pages:`) scrolls by animation, which runs on the display's clock, and that
// stops while the screen is locked or asleep: here it scrolls at once.
UserDefaults.standard.setVolatileDomain(["NSScrollAnimationEnabled": false], forName: UserDefaults.argumentDomain)
runTests([layoutTests, bindingTests, propertySectionTests, stateTests, windowTests, readOnlyPanelTests, textViewTests, coalescingTests, boardPanelTests,
          textBoxTests, shownWhileTests, completionTests, takeoverTests, listRowTests, panelWalkTests, boardHeadingTests, tabViewTests])
