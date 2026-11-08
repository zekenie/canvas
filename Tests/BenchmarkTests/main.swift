import Foundation
import TestKit

let suites = [benchmarks, sidebarBenchmarks, queryBenchmarks, frameBenchmarks, standInBenchmarks, referenceBenchmarks, findBenchmarks, jumpToBenchmarks, mentionPathBenchmarks, neighborBenchmarks, typeBenchmarks, boardWriteBenchmarks, layoutBenchmarks, fieldBenchmarks, relationshipBenchmarks, fieldCheckBenchmarks, cardBenchmarks, relationRowBenchmarks, relationPickBenchmarks, relateOfferBenchmarks, relationCardBenchmarks, relationshipRuleBenchmarks, neighborListBenchmarks, accessibilityBenchmarks, slashBarBenchmarks, windowBenchmarks, saveBenchmarks, spatialBenchmarks, storageBenchmarks, restackingBenchmarks, issueWalkBenchmarks, connectPickerBenchmarks, moveBenchmarks, lineBenchmarks, tableBenchmarks, keyBenchmarks, rowCatalogBenchmarks]
let pick = ProcessInfo.processInfo.environment["BENCH_SUITE"].flatMap { Int($0) }
// Scaling's suite comes last, after whatever ran (in every share of a run test.sh splits, over that
// share's lines: each benchmark reports every size in one test), and each test starts outside any size.
runTests(pick.map { [suites[$0]] } ?? suites, closing: [scalingBenchmarks], holdsBudgets: holdsToBudgets, afterEach: { Scaling.currentSize = nil })
