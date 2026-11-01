import CoreGraphics
import Testing
@testable import FenceCore

let optionFlag: UInt64 = 0x0008_0000
let commandFlag: UInt64 = 0x0010_0000
let capsLockFlag: UInt64 = 0x0001_0000

@Suite struct ReleaseKeyTests {
    @Test func defaultIsOption() {
        #expect(ReleaseKeys.defaultKeys == [.option])
        #expect(ReleaseKeys.defaultKeys.isHeld(flags: optionFlag))
        #expect(ReleaseKeys.defaultKeys.isHeld(flags: optionFlag | capsLockFlag | commandFlag))
        #expect(!ReleaseKeys.defaultKeys.isHeld(flags: commandFlag))
        #expect(!ReleaseKeys.defaultKeys.isHeld(flags: 0))
    }

    @Test func comboNeedsEveryKey() {
        let keys: ReleaseKeys = [.option, .command]
        #expect(!keys.isHeld(flags: optionFlag))
        #expect(!keys.isHeld(flags: commandFlag))
        #expect(keys.isHeld(flags: optionFlag | commandFlag))
    }

    @Test func functionKeyMatchesSecondaryFn() {
        #expect(ReleaseKeys.function.isHeld(flags: 0x0080_0000))
    }

    @Test func emptySetNeverReleases() {
        #expect(!ReleaseKeys().isHeld(flags: ~0))
    }

    @Test func symbolsInMenuOrder() {
        #expect(ReleaseKeys([.command, .control, .option]).symbols == "⌃⌥⌘")
    }
}

@Suite struct DeciderTests {
    func decider(_ m: Mechanism = .disassociate) -> Decider {
        Decider(geometry: fenceMSI, releaseKeys: .defaultKeys, mechanism: m, band: 200)
    }

    func hw(_ p: CGPoint, _ dx: CGFloat = 0, _ dy: CGFloat = 0, flags: UInt64 = 0, dis: Bool) -> MotionInput {
        MotionInput(location: p, delta: CGVector(dx: dx, dy: dy), isSynthetic: false, flags: flags, disassociated: dis)
    }

    @Test func engagesInsideBandOnly() {
        var d = decider()
        #expect(!d.handle(hw(CGPoint(x: 900, y: 100), dis: false)).wantDisassociated)
        #expect(d.handle(hw(CGPoint(x: 150, y: 100), dis: false)).wantDisassociated)
    }

    @Test func fastMotionWidensBand() {
        var d = decider()
        // 600pt from the zone, but moving 120pt per event: 6 × 120 = 720.
        let out = d.handle(hw(CGPoint(x: 620, y: 100), -120, 0, dis: false))
        #expect(out.wantDisassociated)
    }

    @Test func disassociatedMotionIsDrivenAndClamped() {
        var d = decider()
        d.reset(at: CGPoint(x: 60, y: 100))
        let out = d.handle(hw(CGPoint(x: 60, y: 100), -500, 3, dis: true))
        #expect(out.position == CGPoint(x: 20, y: 103))
        #expect(out.warp && out.rewrite)
        #expect(out.contact?.face == .right)
        #expect(!out.breach)
        #expect(out.wantDisassociated)
    }

    @Test func releaseKeyLetsItThroughAndReassociates() {
        var d = decider()
        let out = d.handle(hw(CGPoint(x: 60, y: 100), -500, 0, flags: optionFlag, dis: true))
        #expect(out.released)
        #expect(!out.wantDisassociated)
        #expect(!out.warp && !out.rewrite)
    }

    @Test func leavingFencedDisplayIsFree() {
        var d = decider()
        d.reset(at: CGPoint(x: -200, y: 100))  // on the MSI
        let out = d.handle(hw(CGPoint(x: 5, y: 100), dis: false))
        #expect(out.position == CGPoint(x: 5, y: 100))
        #expect(!out.warp && !out.rewrite && out.contact == nil && !out.breach)
    }

    @Test func associatedJumpIntoZoneIsABreachAndIsPulledBack() {
        var d = decider()
        d.reset(at: CGPoint(x: 900, y: 100))
        let out = d.handle(hw(CGPoint(x: -50, y: 100), dis: false))
        #expect(out.breach)
        #expect(out.warp)
        #expect(out.position == CGPoint(x: 20, y: 100))
    }

    @Test func syntheticEventIsHeldByRewriteWithoutWarp() {
        var d = decider()
        d.reset(at: CGPoint(x: 900, y: 100))
        let e = MotionInput(location: CGPoint(x: -50, y: 100), delta: .zero, isSynthetic: true, flags: 0, disassociated: true)
        let out = d.handle(e)
        #expect(out.position == CGPoint(x: 20, y: 100))
        #expect(out.rewrite && !out.warp && !out.breach)
    }

    @Test func rewriteOnlyNeverDisassociates() {
        var d = decider(.rewriteOnly)
        #expect(!d.handle(hw(CGPoint(x: 30, y: 100), dis: false)).wantDisassociated)
    }

    @Test func noGeometryMeansPassThrough() {
        var d = Decider(geometry: nil, releaseKeys: .defaultKeys, mechanism: .disassociate, band: 200)
        let out = d.handle(hw(CGPoint(x: -50, y: 100), dis: false))
        #expect(!out.wantDisassociated && !out.warp && !out.rewrite)
    }
}

@Suite struct FeedbackTests {
    @Test func glowIsClippedToWorkScreen() {
        let f = Feedback.glowFrame(seamPoint: CGPoint(x: 0, y: 150), radius: 80, workDisplay: builtIn, fenced: msi)
        #expect(f == CGRect(x: 0, y: 70, width: 80, height: 160))
        #expect(overlapArea(f!, msi) == 0)
    }

    @Test func glowNearCornerStaysOffFencedDisplay() {
        // Contact right at the bottom of the shared seam.
        let f = Feedback.glowFrame(seamPoint: CGPoint(x: 0, y: 299), radius: 80, workDisplay: builtIn, fenced: msi)!
        #expect(overlapArea(f, msi) == 0)
        #expect(builtIn.contains(f))
    }

    @Test func glowRefusesWhenWorkDisplayOverlapsFenced() {
        // Defensive: a bogus work rect that overlaps the fenced display.
        let f = Feedback.glowFrame(seamPoint: CGPoint(x: 0, y: 150), radius: 80,
                                   workDisplay: CGRect(x: -100, y: 0, width: 400, height: 400), fenced: msi)
        #expect(f == nil)
    }

    @Test func coordinateConversionRoundTrips() {
        // the dev Mac: the MSI is CG y = -1429, AppKit y = 870.
        let ak = Feedback.appKitRect(fromCG: msi, mainDisplayHeight: 1169)
        #expect(ak == CGRect(x: -4096, y: 870, width: 4096, height: 1728))
        #expect(Feedback.cgRect(fromAppKit: ak, mainDisplayHeight: 1169) == msi)
    }

    @Test func recoilEasesOut() {
        #expect(Feedback.recoilDistance(elapsed: 0, duration: 0.14, distance: 12) == 0)
        #expect(Feedback.recoilDistance(elapsed: 0.14, duration: 0.14, distance: 12) == 12)
        let half = Feedback.recoilDistance(elapsed: 0.07, duration: 0.14, distance: 12)
        #expect(half > 6)  // ease-out: more than half the way at half the time
    }
}
