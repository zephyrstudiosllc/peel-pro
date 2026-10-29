import Foundation
import QuartzCore
import AVFoundation

// Exact production container code is appended by run-renderer-ownership-checks.py.
// These small UIKit stand-ins supply lifecycle/screen values on macOS; CALayer,
// AVSampleBufferDisplayLayer and their reparenting/layout are the real frameworks.
// No window is displayed and no application is controlled by this fixture.
enum UIColor { case clear }
final class UIScreen { var maximumFramesPerSecond: Int; init(_ fps: Int) { maximumFramesPerSecond = fps } }
final class UIWindowScene { var screen: UIScreen; init(_ screen: UIScreen) { self.screen = screen } }
final class UIWindow { var windowScene: UIWindowScene?; init(_ fps: Int) { windowScene = UIWindowScene(UIScreen(fps)) } }
class UIView: NSObject, CALayerDelegate {
    let layer = CALayer()
    var bounds: CGRect
    var backgroundColor: UIColor?
    var isOpaque = true
    var window: UIWindow?
    init(frame: CGRect) { bounds = frame; super.init(); layer.delegate = self }
    required init?(coder: NSCoder) { bounds = .zero; super.init(); layer.delegate = self }
    func layoutSubviews() {}
}

@main struct RendererOwnershipChecks {
    static func main() {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
        let firstView = VideoLayerContainerView(frame: CGRect(x: 0, y: 0, width: 100, height: 80))
        let secondView = VideoLayerContainerView(frame: CGRect(x: 0, y: 0, width: 240, height: 180))
        firstView.window = UIWindow(120)
        secondView.window = UIWindow(60)
        let firstLayer = AVSampleBufferDisplayLayer()
        firstView.attach(firstLayer, fillsAvailableBounds: false)
        check(firstLayer.superlayer === firstView.layer, "Initial attachment")
        secondView.attach(firstLayer, fillsAvailableBounds: true)
        check(firstLayer.superlayer === secondView.layer && firstLayer.frame == secondView.bounds, "New owner attaches/layouts")
        check(firstLayer.videoGravity == .resizeAspectFill, "New owner controls content mode")
        firstView.bounds = CGRect(x: 0, y: 0, width: 900, height: 600)
        firstView.layoutSubviews()
        check(firstLayer.frame == secondView.bounds, "Stale view must not resize the new owner's layer")
        check(firstLayer.videoGravity == .resizeAspectFill, "Stale view must not change the new owner's content mode")
        let secondLayer = AVSampleBufferDisplayLayer()
        firstView.attach(secondLayer, fillsAvailableBounds: false)
        check(firstLayer.superlayer === secondView.layer, "Replacing a stale attachment must not remove the new owner's layer")
        firstView.detachCurrentLayerIfStillOwned()
        check(firstLayer.superlayer === secondView.layer && secondLayer.superlayer == nil, "Detach only own layer")
        secondView.detachCurrentLayerIfStillOwned()
        check(firstLayer.superlayer == nil, "Current owner can detach")

        // SCREEN_CHECKS_BEGIN
        firstView.attach(firstLayer, fillsAvailableBounds: false)
        check(VideoLayerContainerView.screenMaximumFPS(for: firstLayer) == 120, "Actual first hosting screen")
        secondView.attach(firstLayer, fillsAvailableBounds: false)
        check(VideoLayerContainerView.screenMaximumFPS(for: firstLayer) == 60, "Reparenting switches the reported screen")
        firstView.detachCurrentLayerIfStillOwned()
        check(VideoLayerContainerView.screenMaximumFPS(for: firstLayer) == 60, "Stale teardown does not clear current screen")
        secondView.window?.windowScene?.screen.maximumFramesPerSecond = 144
        check(VideoLayerContainerView.screenMaximumFPS(for: firstLayer) == 144, "Read current scene after display migration")
        secondView.window?.windowScene?.screen.maximumFramesPerSecond = 0
        check(VideoLayerContainerView.screenMaximumFPS(for: firstLayer) == nil, "Invalid capability stays unavailable")
        secondView.window?.windowScene = nil
        check(VideoLayerContainerView.screenMaximumFPS(for: firstLayer) == nil, "No hosting scene stays unavailable")
        secondView.window = nil
        check(VideoLayerContainerView.screenMaximumFPS(for: firstLayer) == nil, "Offscreen is not a main-screen assumption")
        secondView.detachCurrentLayerIfStillOwned()
        check(VideoLayerContainerView.screenMaximumFPS(for: firstLayer) == nil, "Detached layer has no display capability")
        // SCREEN_CHECKS_END

        if !failures.isEmpty { failures.forEach { print("FAIL: \($0)") }; exit(1) }
        print("PASS: exact container ownership and current-screen lookup; UIKit lifecycle stubbed, real CoreAnimation layers, no UI")
    }
}
