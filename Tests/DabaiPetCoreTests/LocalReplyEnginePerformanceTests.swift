import DabaiPetCore
import Foundation
import Testing

@Suite struct LocalReplyEnginePerformanceTests {
    private static let warmupCount = 64
    private static let samplesPerScenario = 512

    private struct ScenarioSamples: Encodable {
        let name: String
        let durationsNanoseconds: [Double]
        let p99Nanoseconds: Double
    }

    private struct BenchmarkSamples: Encodable {
        let clock = "ContinuousClock"
        let quantileMethod = "nearest rank ceil(0.99 * N)"
        let warmupsPerScenario: Int
        let samplesPerScenario: Int
        let overallP99Nanoseconds: Double
        let scenarios: [ScenarioSamples]
    }

    @Test func measuresActualReplyP99ForEachPathAndOverall() throws {
        let scenarios: [(name: String, input: String, expected: PetEmotion)] = [
            ("greeting", "你好", .happy),
            ("fatigue", "我今天有点累，想歇一会儿。", .care),
            ("catchphrase", "大白，一起说巴拉拉拉吧。", .happy),
            ("mixed", "你好！巴拉拉拉，不过现在有点累。", .care),
            ("fallback", "今天外面有风，想聊聊散步。", .neutral),
        ]
        let clock = ContinuousClock()
        let limit = Duration.milliseconds(5)
        var allSamples: [Duration] = []
        var records: [ScenarioSamples] = []

        for scenario in scenarios {
            for _ in 0..<Self.warmupCount {
                try #require(LocalReplyEngine.reply(to: scenario.input).emotion == scenario.expected)
            }

            var samples: [Duration] = []
            samples.reserveCapacity(Self.samplesPerScenario)
            var matchedReplies = 0
            for _ in 0..<Self.samplesPerScenario {
                let start = clock.now
                let reply = LocalReplyEngine.reply(to: scenario.input)
                let end = clock.now
                samples.append(start.duration(to: end))
                if reply.emotion == scenario.expected && reply.message.role == .assistant && !reply.message.content.isEmpty {
                    matchedReplies += 1
                }
            }

            #expect(matchedReplies == Self.samplesPerScenario, "\(scenario.name) should measure the expected reply path")
            let p99 = Self.nearestRankP99(samples)
            #expect(p99 < limit, "\(scenario.name) p99 was \(p99)")
            records.append(ScenarioSamples(name: scenario.name, durationsNanoseconds: samples.map(Self.nanoseconds),
                                           p99Nanoseconds: Self.nanoseconds(p99)))
            allSamples.append(contentsOf: samples)
        }

        let overallP99 = Self.nearestRankP99(allSamples)
        #expect(overallP99 < limit, "Overall p99 was \(overallP99)")
        print("LocalReplyEngine p99 (ns), \(allSamples.count) samples: \(Self.nanoseconds(overallP99))")
        for record in records {
            print("\(record.name): \(record.p99Nanoseconds)")
        }

        if let output = ProcessInfo.processInfo.environment["DABAI_LOCAL_REPLY_SAMPLES"] {
            let report = BenchmarkSamples(warmupsPerScenario: Self.warmupCount, samplesPerScenario: Self.samplesPerScenario,
                                          overallP99Nanoseconds: Self.nanoseconds(overallP99), scenarios: records)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(report).write(to: URL(fileURLWithPath: output), options: .withoutOverwriting)
        }
    }

    private static func nearestRankP99(_ samples: [Duration]) -> Duration {
        let rank = (99 * samples.count + 99) / 100
        return samples.sorted()[rank - 1]
    }

    private static func nanoseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000_000_000 + Double(parts.attoseconds) / 1_000_000_000
    }
}
