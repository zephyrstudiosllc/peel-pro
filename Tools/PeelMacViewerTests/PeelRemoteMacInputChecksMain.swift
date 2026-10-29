import CoreGraphics
import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

private func gates(
    stream: String? = "pair/7",
    hasVideo: Bool = true,
    isPaused: Bool = false,
    windowIsKey: Bool = true,
    appIsActive: Bool = true,
    controlEnabled: Bool = false
) -> PeelRemoteMacAutoControlIntent.Gates {
    .init(stream: stream, isConnected: true, hasVideo: hasVideo, isPaused: isPaused,
          windowIsKey: windowIsKey, appIsActive: appIsActive, controlEnabled: controlEnabled)
}

@main
enum PeelRemoteMacInputChecks {
    static func main() {
        var intent = PeelRemoteMacAutoControlIntent()
        require(!intent.consume(gates()), "unarmed intent never enables control")

        intent.armForExplicitSelection(stream: "pair/7")
        require(!intent.consume(gates(hasVideo: false)), "waits for video")
        require(!intent.consume(gates(windowIsKey: false)), "waits for key stream window")
        require(!intent.consume(gates(appIsActive: false)), "waits for foreground app")
        require(!intent.consume(gates(isPaused: true)), "paused placeholder never enables")
        require(intent.armedStream == "pair/7", "focus gates keep the intent armed")
        require(intent.consume(gates()), "explicit selection enables once ready")
        require(!intent.consume(gates()), "consumed once; routine updates never re-enable")

        intent.armForExplicitSelection(stream: "pair/7")
        intent.cancel()
        require(!intent.consume(gates()), "explicit Off/Escape/Stop cancels")

        intent.armForExplicitSelection(stream: "pair/7")
        require(!intent.consume(gates(stream: "pair/8")), "another stream never inherits intent")
        require(!intent.consume(gates()), "stale intent is dropped")

        intent.armForExplicitSelection(stream: "pair/7")
        require(!intent.consume(gates(controlEnabled: true)), "already-on control consumes without change")
        require(intent.armedStream == nil, "already-on control drops intent")

        // Pointer mapping: aspect-fit content, top-left origin, letterbox inert.
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let stream = CGSize(width: 1600, height: 1000)
        require(PeelRemoteMacStreamGeometry.contentRect(in: bounds, stream: stream)
            == CGRect(x: 100, y: 0, width: 800, height: 500), "centered aspect fit")
        require(PeelRemoteMacStreamGeometry.normalizedPoint(CGPoint(x: 100, y: 0), in: bounds, stream: stream)
            == CGPoint(x: 0, y: 1), "AppKit bottom-left maps to Host bottom-left")
        require(PeelRemoteMacStreamGeometry.normalizedPoint(CGPoint(x: 300, y: 375), in: bounds, stream: stream)
            == CGPoint(x: 0.25, y: 0.25), "upper content maps toward Host top-left")
        require(PeelRemoteMacStreamGeometry.normalizedPoint(CGPoint(x: 700, y: 125), in: bounds, stream: stream)
            == CGPoint(x: 0.75, y: 0.75), "interior point maps proportionally with y flipped")
        require(PeelRemoteMacStreamGeometry.normalizedPoint(CGPoint(x: 50, y: 250), in: bounds, stream: stream)
            == nil, "letterbox is inert")

        print("PeelRemoteMacInputChecks: PASS")
    }
}
