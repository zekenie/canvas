import TestKit

runTests([grammarTests, modelTests, lookTests, commandTests, titleFieldTests, kitTests, lineTests, keyTests, foldTests, tabTests, typedKeyTests, keyLookTests, cardTests, sqlReaderTests, sqlPasteTests, yamlTests, openAPIReaderTests, apiTests, apiStructureTests, rowItemTests, relationTests, rowDragTests, agentTests, apiChangeTests, rowPanelTests], afterEach: releaseKitPasteboards)
