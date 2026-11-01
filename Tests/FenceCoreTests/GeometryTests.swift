import CoreGraphics
import Testing
@testable import FenceCore

// the dev Mac as measured 2026-11-01: built-in main display, MSI ultrawide up-left,
// sharing only the seam x = 0 for y in [0, 299).
let builtIn = CGRect(x: 0, y: 0, width: 1800, height: 1169)
let msi = CGRect(x: -4096, y: -1429, width: 4096, height: 1728)
let ext = CursorExtent(left: 20, up: 20, right: 40, down: 40)

/// Fence the MSI; work on the built-in.
let fenceMSI = FenceGeometry(fenced: msi, others: [builtIn], extent: ext)
/// Fence the built-in; work on the MSI.
let fenceBuiltIn = FenceGeometry(fenced: builtIn, others: [msi], extent: ext)

/// The cursor image's bounds for a hotspot, under the extent above.
func imageRect(_ p: CGPoint) -> CGRect {
    CGRect(x: p.x - ext.left, y: p.y - ext.up, width: ext.left + ext.right, height: ext.up + ext.down)
}

@Suite struct ZoneTests {
    @Test func zoneCoversCursorImageReach() {
        // MSI is left of the built-in: the hotspot must stay `left` (20pt)
        // clear of x = 0, because the image reaches 20pt left of it.
        #expect(fenceMSI.isInZone(CGPoint(x: 19, y: 100)))
        #expect(!fenceMSI.isInZone(CGPoint(x: 20, y: 100)))
        // Built-in is right of the MSI: the image reaches 40pt right.
        #expect(fenceBuiltIn.isInZone(CGPoint(x: -39, y: 100)))
        #expect(!fenceBuiltIn.isInZone(CGPoint(x: -40, y: 100)))
    }

    @Test func boundaryHotspotKeepsImageOffFencedDisplay() {
        for p in [CGPoint(x: 20, y: 100), CGPoint(x: 20, y: 0), CGPoint(x: 500, y: 299 + 20)] {
            #expect(!fenceMSI.isInZone(p))
            #expect(overlapArea(imageRect(p), msi) == 0)
        }
    }

    @Test func distanceAndDepth() {
        #expect(fenceMSI.distanceToZone(CGPoint(x: 120, y: 100)) == 100)
        #expect(fenceMSI.distanceToZone(CGPoint(x: 10, y: 100)) == 0)
        #expect(fenceMSI.depthInZone(CGPoint(x: 10, y: 100)) == 10)
        #expect(fenceMSI.depthInZone(CGPoint(x: 30, y: 100)) == 0)
    }
}

@Suite struct StepTests {
    @Test func freeMotionAwayFromWall() {
        let s = fenceMSI.step(from: CGPoint(x: 400, y: 400), to: CGPoint(x: 410, y: 390))
        #expect(s.point == CGPoint(x: 410, y: 390))
        #expect(s.contact == nil)
    }

    @Test func hardPushStopsAtWallAndSlides() {
        // A fast flick from the work side deep into the MSI.
        let s = fenceMSI.step(from: CGPoint(x: 200, y: 100), to: CGPoint(x: -900, y: 150))
        #expect(s.point == CGPoint(x: 20, y: 150))
        #expect(s.contact?.face == .right)
        #expect(s.contact?.seamPoint == CGPoint(x: 0, y: 150))
        #expect(s.contact?.normal == CGVector(dx: 1, dy: 0))
        #expect(overlapArea(imageRect(s.point), msi) == 0)
    }

    @Test func diagonalIntoCornerNeverOverlaps() {
        // Approach the MSI's bottom-right corner (0, 299) diagonally.
        let from = CGPoint(x: 300, y: 600)
        for target in [CGPoint(x: -50, y: 250), CGPoint(x: 5, y: 310), CGPoint(x: -3000, y: -900)] {
            let s = fenceMSI.step(from: from, to: target)
            #expect(!fenceMSI.isInZone(s.point))
            #expect(overlapArea(imageRect(s.point), msi) == 0)
            #expect(builtIn.contains(s.point))
        }
    }

    @Test func belowSharedSeamIsNotAWall() {
        // At y = 700 the built-in's left edge borders nothing: the OS-style
        // display clamp applies, and there is no contact.
        let s = fenceMSI.step(from: CGPoint(x: 100, y: 700), to: CGPoint(x: -200, y: 700))
        #expect(s.point == CGPoint(x: 0, y: 700))
        #expect(s.contact == nil)
    }

    @Test func fencedBuiltInFromMSISide() {
        let s = fenceBuiltIn.step(from: CGPoint(x: -300, y: 50), to: CGPoint(x: 600, y: 80))
        #expect(s.point == CGPoint(x: -40, y: 80))
        #expect(s.contact?.face == .left)
        #expect(s.contact?.seamPoint == CGPoint(x: 0, y: 80))
        #expect(overlapArea(imageRect(s.point), builtIn) == 0)
    }

    @Test func insideClearanceStripCannotGoDeeper() {
        // Pointer sits 10pt inside the zone (it just came off the MSI).
        let p = CGPoint(x: 10, y: 100)
        let deeper = fenceMSI.step(from: p, to: CGPoint(x: -100, y: 120))
        #expect(deeper.point.x >= 10)
        #expect(!fenceMSI.isInFenced(deeper.point))
        let out = fenceMSI.step(from: p, to: CGPoint(x: 60, y: 100))
        #expect(out.point == CGPoint(x: 60, y: 100))
    }

    @Test func clampsToOuterDisplayEdge() {
        let s = fenceMSI.step(from: CGPoint(x: 1700, y: 1000), to: CGPoint(x: 2500, y: 1500))
        #expect(s.point == CGPoint(x: 1799, y: 1168))
    }

    /// Random walks with huge, fast steps: the image never overlaps the
    /// fenced display, whatever the arrangement.
    @Test(arguments: [
        (msi, builtIn),
        (builtIn, msi),
        // Vertically offset side by side, as RP will arrange the compositor.
        (CGRect(x: 1920, y: 400, width: 1920, height: 1080), CGRect(x: 0, y: 0, width: 1920, height: 1080)),
        // Stacked: fenced display above the work display.
        (CGRect(x: 200, y: -1080, width: 1920, height: 1080), CGRect(x: 0, y: 0, width: 2560, height: 1440)),
    ])
    func fuzzNeverEnters(fenced: CGRect, work: CGRect) {
        let g = FenceGeometry(fenced: fenced, others: [work], extent: ext)
        var rng = SystemRandomNumberGenerator()
        var p = CGPoint(x: work.midX, y: work.midY)
        for _ in 0..<20_000 {
            let target = CGPoint(x: p.x + .random(in: -2500...2500, using: &rng),
                                 y: p.y + .random(in: -2500...2500, using: &rng))
            p = g.step(from: p, to: target).point
            #expect(!g.isInZone(p))
            #expect(overlapArea(imageRect(p), fenced) == 0)
            #expect(work.contains(p))
        }
    }
}
