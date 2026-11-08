import TestKit

runTests([grammarTests, modelTests, lookTests, commandTests, titleFieldTests, kitTests, lineTests, keyTests, foldTests, tabTests, typedKeyTests, keyLookTests, sqlReaderTests, sqlPasteTests], afterEach: releaseKitPasteboards)
