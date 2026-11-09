import TestKit

runTests([grammarTests, modelTests, lookTests, commandTests, titleFieldTests, kitTests, lineTests, wholeLineTests, keyTests, foldTests, tabTests, typedKeyTests, keyLookTests, cardTests, sqlReaderTests, sqlPasteTests, yamlTests, openAPIReaderTests, apiTests, apiStructureTests, apiPathTests, rowItemTests, relationTests, rowDragTests, roomTests, agentTests, apiChangeTests, rowPanelTests], afterEach: releaseKitPasteboards)
