import Foundation
import TestKit

let suites = [benchmarks, inspectorBenchmarks, queryBenchmarks, frameBenchmarks, standInBenchmarks, referenceBenchmarks, findBenchmarks, jumpToBenchmarks, mentionPathBenchmarks, neighborBenchmarks, typeBenchmarks, boardWriteBenchmarks, layoutBenchmarks, fieldBenchmarks, relationshipBenchmarks, fieldCheckBenchmarks, cardBenchmarks, relationRowBenchmarks, relationPickBenchmarks, relateOfferBenchmarks, relationCardBenchmarks, relationshipRuleBenchmarks, neighborListBenchmarks, accessibilityBenchmarks, slashBarBenchmarks, windowBenchmarks, saveBenchmarks, spatialBenchmarks, storageBenchmarks, restackingBenchmarks]
let pick = ProcessInfo.processInfo.environment["BENCH_SUITE"].flatMap { Int($0) }
// Scaling's suite comes last, after whatever ran, and each test starts outside any size.
runTests((pick.map { [suites[$0]] } ?? suites) + [scalingBenchmarks], afterEach: { Scaling.currentSize = nil })
