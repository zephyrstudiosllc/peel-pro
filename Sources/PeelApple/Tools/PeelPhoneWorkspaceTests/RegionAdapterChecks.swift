import Foundation
import CoreGraphics

enum TestSizeClass { case compact, regular }
enum TestRegionKind: Hashable { case division, occlusion }
enum TestDirection: Equatable { case fixed, mirrors }
struct TestRegion {
    let frame: CGRect
    let isActive: Bool
}
final class GeometryProxy {
    let size: CGSize
    let regions: [TestRegionKind: [TestRegion]]
    let rightToLeft: Bool
    var queries: [(TestRegionKind, Set<Int>, TestDirection)] = []
    init(size: CGSize, regions: [TestRegionKind: [TestRegion]] = [:], rightToLeft: Bool = false) {
        self.size = size; self.regions = regions; self.rightToLeft = rightToLeft
    }
    func reservedRegions(kind: TestRegionKind, options: Set<Int>, layoutDirectionBehavior: TestDirection) -> [TestRegion] {
        queries.append((kind, options, layoutDirectionBehavior))
        let physical = regions[kind] ?? []
        guard rightToLeft && layoutDirectionBehavior == .mirrors else { return physical }
        return physical.map { region in
            TestRegion(frame: CGRect(x: size.width - region.frame.maxX, y: region.frame.minY, width: region.frame.width, height: region.frame.height), isActive: region.isActive)
        }
    }
}
struct RegionAdapterHarness {
    var horizontalSizeClass: TestSizeClass? = .regular
    var effectiveSelectedPane: PeelPhoneWorkspacePane = .companion
    var distinctCompanion: Int? = 1
    // REGION ADAPTER
}

var adapterCount = 0
func adapterCheck(_ value: @autoclosure () -> Bool, _ message: String) {
    adapterCount += 1
    guard value() else { fatalError(message) }
}
let adapter = RegionAdapterHarness()
let bookGap = CGRect(x: 303, y: 0, width: 20, height: 890)
let cameraGap = CGRect(x: 590, y: 30, width: 36, height: 54)
let bookProxy = GeometryProxy(size: CGSize(width: 626, height: 890), regions: [
    .division: [TestRegion(frame: bookGap, isActive: true)],
    .occlusion: [TestRegion(frame: cameraGap, isActive: true)]
])
let bookAdapter = adapter.geometryPlan(in: bookProxy)
adapterCheck(bookProxy.queries.map { $0.0 } == [.division, .occlusion], "query both real region kinds")
adapterCheck(bookProxy.queries.allSatisfy { $0.1.isEmpty }, "do not request inactive regions")
adapterCheck(bookProxy.queries.allSatisfy { $0.2 == .mirrors }, "query frames in the same mirrored coordinates as SwiftUI position placement")
adapterCheck(bookAdapter.arrangement == .book && bookAdapter.showsBoth, "native proxy division reaches the production resolver")
adapterCheck(bookAdapter.primary.maxX == bookGap.minX && bookAdapter.companion.minX == bookGap.maxX, "local region coordinates and included margins are used once")
adapterCheck(bookAdapter.companion.intersection(cameraGap).isEmpty, "asymmetric native camera occlusion reaches the production resolver")
let inactive = GeometryProxy(size: bookProxy.size, regions: [
    .division: [TestRegion(frame: bookGap, isActive: false)],
    .occlusion: [TestRegion(frame: CGRect(origin: .zero, size: bookProxy.size), isActive: false)]
])
adapterCheck(adapter.geometryPlan(in: inactive).arrangement == .rows, "inactive fold and camera frames do not displace a flat layout")
let tableGap = CGRect(x: 0, y: 303, width: 890, height: 20)
let tableProxy = GeometryProxy(size: CGSize(width: 890, height: 626), regions: [.division: [TestRegion(frame: tableGap, isActive: true)]])
adapterCheck(adapter.geometryPlan(in: tableProxy).arrangement == .tabletop, "native horizontal division selects upper/lower layout")
let compactAdapter = RegionAdapterHarness(horizontalSizeClass: .compact)
adapterCheck(compactAdapter.geometryPlan(in: GeometryProxy(size: CGSize(width: 390, height: 844))).visiblePanes == [.companion], "native adapter preserves compact selected pane")
let oneAdapter = RegionAdapterHarness(distinctCompanion: nil)
adapterCheck(oneAdapter.geometryPlan(in: bookProxy).visiblePanes == [.primary], "native folded single-window layout retains the available primary")
// Real native RTL validation found that .position mirrors its numeric x value.
// An asymmetric viewport exposes a fixed-query/mirrored-placement mismatch.
let rtlFold = CGRect(x: 371.5, y: 0, width: 40, height: 553)
let rtlProxy = GeometryProxy(size: CGSize(width: 735, height: 553), regions: [.division: [TestRegion(frame: rtlFold, isActive: true)]], rightToLeft: true)
let rtlPlan = adapter.geometryPlan(in: rtlProxy)
func nativeRTLPlacement(_ frame: CGRect, width: CGFloat) -> CGRect {
    CGRect(x: width - frame.maxX, y: frame.minY, width: frame.width, height: frame.height)
}
let rtlPrimary = nativeRTLPlacement(rtlPlan.primary, width: rtlProxy.size.width)
let rtlCompanion = nativeRTLPlacement(rtlPlan.companion, width: rtlProxy.size.width)
adapterCheck(rtlPlan.showsBoth, "asymmetric RTL folded viewport retains both useful windows")
adapterCheck(rtlPrimary.intersection(rtlFold).isEmpty && rtlCompanion.intersection(rtlFold).isEmpty, "native RTL placement avoids the actual unmirrored physical hinge")
adapterCheck(rtlPrimary.minX == rtlFold.maxX && rtlCompanion.maxX == rtlFold.minX, "unequal RTL panes align with the correct physical region edges")
let rtlCamera = CGRect(x: 12, y: 0, width: 40, height: 120)
let cameraProxy = GeometryProxy(size: rtlProxy.size, regions: [.division: [TestRegion(frame: rtlFold, isActive: true)], .occlusion: [TestRegion(frame: rtlCamera, isActive: true)]], rightToLeft: true)
let rtlCameraPlan = adapter.geometryPlan(in: cameraProxy)
let actualCameraFrames = [rtlCameraPlan.primary, rtlCameraPlan.companion].map { nativeRTLPlacement($0, width: cameraProxy.size.width) }
adapterCheck(actualCameraFrames.allSatisfy { $0.intersection(rtlCamera).isEmpty && $0.intersection(rtlFold).isEmpty }, "RTL camera avoidance stays on its real physical side in an asymmetric window")
print("Phone native region adapter: PASS (\(adapterCount) checks)")
