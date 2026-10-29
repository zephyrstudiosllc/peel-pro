let beforeGeometryChecks = count
typealias Geometry = PeelPhoneWorkspaceGeometry
func geometry(_ width: CGFloat, _ height: CGFloat, regular: Bool = true, selected: PeelPhoneWorkspacePane = .primary, companion: Bool = true, divisions: [CGRect] = [], occlusions: [CGRect] = []) -> Geometry {
    Geometry.resolve(size: CGSize(width: width, height: height), regularWidth: regular, selected: selected, hasCompanion: companion, divisions: divisions, occlusions: occlusions)
}

let coverPortrait = geometry(390, 844, regular: false, selected: .companion)
check(coverPortrait.arrangement == .single && coverPortrait.visiblePanes == [.companion], "outer portrait retains selected companion")
check(coverPortrait.companion == CGRect(x: 0, y: 0, width: 390, height: 844), "cover pane uses its own safe-area container")
check(geometry(844, 390, regular: false).arrangement == .single, "outer landscape remains compact without assuming screen orientation")
let innerPortrait = geometry(626, 890)
check(innerPortrait.arrangement == .rows && innerPortrait.showsBoth, "flat inner portrait stacks readable panes")
check(innerPortrait.primary.width == 626 && innerPortrait.companion.minY > innerPortrait.primary.maxY, "flat rows preserve full width and separate content")
let innerLandscape = geometry(890, 626)
check(innerLandscape.arrangement == .columns && innerLandscape.showsBoth, "flat inner landscape places panes alongside each other")
check(geometry(320, 890, regular: false, selected: .companion).visiblePanes == [.companion], "narrow Split View preserves selected companion")
check(geometry(626, 320).arrangement == .columns, "short video-and-app container adapts from local geometry")
check(geometry(350, 240).arrangement == .single, "small regular window keeps one useful pane")

let bookFold = CGRect(x: 303, y: 0, width: 20, height: 890)
let book = geometry(626, 890, divisions: [bookFold])
check(book.arrangement == .book && book.showsBoth, "vertical active fold overrides portrait aspect ratio")
check(book.primary.maxX <= bookFold.minX && book.companion.minX >= bookFold.maxX, "both book panes avoid the complete reserved division")
let tableFold = CGRect(x: 0, y: 303, width: 890, height: 20)
let table = geometry(890, 626, divisions: [tableFold])
check(table.arrangement == .tabletop && table.showsBoth, "horizontal active fold overrides landscape aspect ratio")
check(table.primary.maxY <= tableFold.minY && table.companion.minY >= tableFold.maxY, "tabletop panes remain above and below hinge")
let singleBook = geometry(626, 890, companion: false, divisions: [bookFold])
check(singleBook.visiblePanes == [.primary] && singleBook.primary.minX >= bookFold.maxX, "one book pane stays wholly inside trailing usable region")
let singleTable = geometry(890, 626, companion: false, divisions: [tableFold])
check(singleTable.visiblePanes == [.primary] && singleTable.primary.maxY <= tableFold.minY, "one tabletop pane stays wholly inside upper usable region")
check(geometry(626, 890, selected: .companion, companion: false, divisions: [bookFold]).visiblePanes == [.primary], "closing companion recovers primary in a valid folded region")
let edgeFold = CGRect(x: -5, y: 0, width: 20, height: 890)
let narrowFold = geometry(626, 890, selected: .companion, divisions: [edgeFold])
check(narrowFold.visiblePanes == [.companion] && narrowFold.companion.minX == 15, "partial division intersection chooses a usable region, not a tiny second pane")
check(geometry(626, 890, divisions: [CGRect(x: 1000, y: 0, width: 20, height: 890)]).arrangement == .rows, "a division outside the app window does not change its layout")

let camera = CGRect(x: 280, y: 0, width: 64, height: 36)
let cameraLayout = geometry(626, 890, occlusions: [camera])
check(cameraLayout.primary.intersection(camera).isEmpty && cameraLayout.companion.intersection(camera).isEmpty, "active camera region never covers either visible pane")
check(cameraLayout.primary.minY == camera.maxY, "camera exclusion uses existing margins once rather than symmetric padding")
let invalid = geometry(.nan, 890)
check(invalid.visiblePanes.isEmpty, "nonfinite container does not start an invisible stream")
check(geometry(0, 0).visiblePanes.isEmpty, "zero geometry contains no visible panes")
check(geometry(626, 890, divisions: [CGRect(x: CGFloat.nan, y: 0, width: 20, height: 890)]).arrangement == .rows, "invalid reserved region is ignored")
check(geometry(626, 890, divisions: [CGRect(x: 303, y: 0, width: 0, height: 890)]).arrangement == .rows, "inactive zero-width hinge does not divide flat content")
check(geometry(626, 890, occlusions: [CGRect(x: 0, y: 0, width: 626, height: 890)]).visiblePanes.isEmpty, "fully occluded content cannot own an invisible stream")

for plan in [coverPortrait, innerPortrait, innerLandscape, book, table, singleBook, singleTable, narrowFold, cameraLayout] {
    check(plan.primary.isEmpty || plan.companion.isEmpty || plan.primary.intersection(plan.companion).isEmpty, "visible pane rectangles never overlap")
}
let selectedTransitions = [
    geometry(890, 626, selected: .companion),
    geometry(626, 890, selected: .companion, divisions: [bookFold]),
    geometry(890, 626, selected: .companion, divisions: [tableFold]),
    geometry(390, 844, regular: false, selected: .companion)
]
check(selectedTransitions.allSatisfy { $0.visiblePanes.contains(.companion) }, "selected companion remains displayed across flat, book, tabletop and closed layouts")
print("Phone workspace geometry: PASS (\(count - beforeGeometryChecks) checks)")
