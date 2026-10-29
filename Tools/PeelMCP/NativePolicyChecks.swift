import Foundation

@main
struct NativePolicyChecks {
    static func main() throws {
        let request = PeelVideoStreamRequest(maximumFPS: 90, receiverDisplay: nil, visionOS90Experiment: true)
        precondition(request.isValid)
        let fallback = PeelStreamingSettings.StreamPolicy(fps: 60, scale: 0.9, bitRate: 120_000_000)
        func policy(_ request: PeelVideoStreamRequest, sourceFPS: Int = 90, count: Int = 1,
                    profile: PeelStreamingSettings.DesktopProfile = .fullQuality, enabled: Bool = true,
                    width: Int = 5120, height: Int = 2880) -> PeelStreamingSettings.StreamPolicy {
            PeelStreamingSettings.nativePolicy(request: request,
                source: .init(width: width, height: height, maximumFPS: sourceFPS),
                streamCount: count, profile: profile, experimentEnabled: enabled, fallback: fallback)
        }
        precondition(policy(request).fps == 90 && policy(request).scale == 1)
        precondition(policy(request).nativeFramePixelLimit == 5120 * 2880)
        precondition(policy(request, sourceFPS: 60).fps == 60)
        precondition(policy(request, count: 2).scale == fallback.scale)
        precondition(policy(request, profile: .responsive).nativeFramePixelLimit == nil)
        precondition(policy(request, enabled: false).nativeFramePixelLimit == nil)
        precondition(policy(request, width: 5121).nativeFramePixelLimit == nil)
        precondition(policy(request, width: 5120, height: 5120).nativeFramePixelLimit == nil)
        precondition(policy(request, sourceFPS: 0).nativeFramePixelLimit == nil)
        for fps in [-1, 0, 91, 120, Int.max] {
            let bad = PeelVideoStreamRequest(maximumFPS: fps, receiverDisplay: nil, visionOS90Experiment: true)
            precondition(!bad.isValid)
            precondition(policy(bad).nativeFramePixelLimit == nil)
        }
        let ordinary = PeelStreamingSettings.videoPolicies(forSourcePixelSizes: [7: (5120, 2880)],
                                                            profile: .fullQuality, experimentEnabled: true)[7]!
        precondition(ordinary.fps == 60 && ordinary.scale < 1 && ordinary.nativeFramePixelLimit == nil)
        let oldHello = #"{"type":"videoStreamHello","windowId":7,"protocolVersion":2,"minimumSupportedProtocolVersion":2}"#
        let hello = try JSONDecoder().decode(VideoStreamHelloMessage.self, from: Data(oldHello.utf8))
        precondition(hello.streamRequest == nil)
        let roundTrip = try JSONDecoder().decode(VideoStreamHelloMessage.self, from:
            JSONEncoder().encode(VideoStreamHelloMessage(windowId: 7, streamRequest: request)))
        precondition(roundTrip.streamRequest == request)
        print("Native 5K90 policy checks passed: exact raster, FPS, old hello, opt-in, bounds, default profile preservation")
    }
}
