import Foundation
import Testing
@testable import DigUpKit

@Suite struct SearchMathTests {
    @Test func fixedModalitySlotsMatchTheOriginalCalibration() {
        let modalities = Array(repeating: Modality.text, count: 140) + Array(repeating: .image, count: 60)
            + Array(repeating: .audio, count: 7) + Array(repeating: .none, count: 3)
        let scores = modalities.indices.map { Float(($0 * 37) % 101) / 137 - 0.25 }
        func reference(_ scale: [Bool]) -> [Double] {
            var sum: [Modality: Double] = [:], count: [Modality: Int] = [:]
            for row in scores.indices where scale[row] {
                sum[modalities[row], default: 0] += Double(scores[row])
                count[modalities[row], default: 0] += 1
            }
            let all = sum.values.reduce(0, +) / Double(max(count.values.reduce(0, +), 1))
            var means: [Modality: Double] = [:]
            for modality in Modality.allCases {
                means[modality] = count[modality, default: 0] >= 20
                    ? sum[modality, default: 0] / Double(count[modality]!) : all
            }
            let centered = scores.indices.map { Double(scores[$0]) - means[modalities[$0], default: 0] }
            var total = 0.0, n = 0.0
            for row in centered.indices where scale[row] { total += centered[row]; n += 1 }
            let mean = total / max(n, 1)
            var squares = 0.0
            for row in centered.indices where scale[row] { squares += (centered[row] - mean) * (centered[row] - mean) }
            let deviation = max(sqrt(squares / max(n, 1)), 0.02)
            return centered.map { ($0 - mean) / deviation }
        }
        for scale in [scores.indices.map { $0 % 5 != 0 }, Array(repeating: true, count: scores.count),
                      Array(repeating: false, count: scores.count)] {
            let actual = Searcher.meaning(scores, modalities, setsScale: scale), expected = reference(scale)
            #expect(zip(actual, expected).allSatisfy { abs($0 - $1) < 0.0000000001 })
        }
    }
}
