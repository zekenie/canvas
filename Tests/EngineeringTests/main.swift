import TestKit

runTests([grammarTests, modelTests, lookTests, commandTests, titleFieldTests, kitTests, lineTests, keyTests, foldTests, tabTests, typedKeyTests, keyLookTests, cardTests, sqlReaderTests, sqlPasteTests], afterEach: releaseKitPasteboards)
