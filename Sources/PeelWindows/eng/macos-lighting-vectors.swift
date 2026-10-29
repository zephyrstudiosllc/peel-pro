// Compile beside the read-only Mac SidePulse Models, LightingEngine, ProfileLibrary,
// LEDProgramRenderer and NearbySignalModels. This executable uses fixtures only;
// it does not open UserDefaults, hardware, sockets or app windows.
import Foundation

private struct InputAgent: Codable {
    let id: String
    let state: String
    let provider: String
    let updatedAt: Double
}
private struct Vector: Encodable {
    let group: String
    let name: String
    let profile: LightingProfile
    let agents: [InputAgent]
    let mode: String
    let ledCount: Int
    let now: Double
    let state: String
    let program: String
    let slots: [String?]
}
@main
enum LightingVectors {
    static func main() throws {
        if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "roundtrip" {
            let input = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
            let profiles = try ProfileLibrary.importProfiles(from: input)
            try ProfileLibrary.exportData(profiles: profiles).write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
            print("PASS Mac imported and re-exported \(profiles.count) Windows lighting profiles")
            return
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let compiler = LightingSceneCompiler()
        var vectors: [Vector] = []
        func agent(_ id: String, _ state: AgentState, age: Double = 0, provider: AgentProvider = .codex) -> AgentSession {
            AgentSession(id: id, provider: provider, sessionID: id, name: "Fixture", project: "Fixture", cwd: nil,
                         state: state, eventName: "Fixture", toolName: nil, updatedAt: now.addingTimeInterval(-age), message: nil)
        }
        func record(_ name: String, profile: LightingProfile, agents: [AgentSession], count: Int,
                    mode: AgentDisplayMode = .perAgent, group: String? = nil, time: Date? = nil,
                    allocator: inout StableSlotAllocator) {
            let instant = time ?? now
            let scene = compiler.compile(profile: profile, agents: AgentDisplayPolicy.lightingSessions(from: agents, mode: mode), allocator: &allocator, ledCount: count, now: instant)
            vectors.append(Vector(group: group ?? name, name: name, profile: profile,
                agents: agents.map { InputAgent(id: $0.id, state: $0.state.rawValue, provider: $0.provider.rawValue, updatedAt: $0.updatedAt.timeIntervalSince1970) },
                mode: mode.rawValue, ledCount: count, now: instant.timeIntervalSince1970,
                state: AgentDisplayPolicy.aggregateState(for: agents, mode: mode).rawValue,
                program: scene.program, slots: scene.slots.map { $0.agent?.id }))
        }
        for profile in [LightingProfile.factoryDefault, .quietNight, .highSignal] {
            for state in AgentState.allCases {
                for count in [2, 8] {
                    var allocator = StableSlotAllocator()
                    record("\(profile.name)-\(state)-\(count)", profile: profile, agents: [agent("a", state)], count: count, allocator: &allocator)
                }
            }
        }
        for motion in LightMotion.allCases {
            for color in LightColorMode.allCases {
                for count in [2, 8] {
                    var profile = LightingProfile.factoryDefault
                    profile.updateStyle(StateLightStyle(state: .working, colorHex: "#1255AF", secondaryColorHex: "#EE6721", colorMode: color, motion: motion, cycleSeconds: 2.345, intensity: 0.73))
                    var allocator = StableSlotAllocator()
                    record("\(motion)-\(color)-\(count)", profile: profile, agents: [agent("a", .working)], count: count, allocator: &allocator)
                }
            }
        }
        for strategy in SlotStrategy.allCases {
            for count in [2, 8] {
                var profile = LightingProfile.factoryDefault
                profile.strategy = strategy
                var allocator = StableSlotAllocator()
                let group = "\(strategy)-\(count)"
                let stages: [[AgentSession]] = [[], [agent("a", .working, age: 10)],
                    [agent("b", .waiting), agent("a", .working, age: 10)],
                    [agent("a", .error), agent("b", .completed, age: 5), agent("c", .toolRunning, age: 2)],
                    [agent("c", .toolRunning, age: 2)], [], [agent("a", .working)],
                    (0..<10).map { agent("s\($0)", $0 % 2 == 0 ? .working : .waiting, age: Double($0)) }]
                for (index, agents) in stages.enumerated() {
                    record("\(group)-step\(index)", profile: profile, agents: agents, count: count, group: group,
                           time: now.addingTimeInterval(Double(index * 75)), allocator: &allocator)
                }
            }
        }
        for count in [2, 8] {
            for states in [[AgentState.toolRunning], [.completed, .toolRunning], [.working, .waiting], [.error, .waiting], [.idle]] {
                var allocator = StableSlotAllocator()
                record("simple-\(count)-\(states)", profile: .factoryDefault, agents: states.enumerated().map { agent("a\($0.offset)", $0.element) }, count: count, mode: .simple, allocator: &allocator)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(vectors))
    }
}
