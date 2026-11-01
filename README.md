# Cursor Fence

Keeps the mouse pointer off one display. The pointer stops at that display's edge as if it hit a wall: it springs back a few points and a short glow appears on your side of the edge. Hold the release key (⌥ by default) to cross. Leaving the fenced display is always free.

Built for the a broadcast installation broadcast compositor, where the fullscreen program output sits beside the operator's work monitor. In native fullscreen, macOS shows the menu bar and title bar only when the pointer reaches that screen's top edge. So keeping the pointer off the broadcast screen keeps cursors, menus and window chrome off the air.

**Measured on the dev Mac (2026-11-01), real mouse, final build:** 0 frames with a cursor on the fenced display, and 0 times hardware motion reached it. That's 3,793 events over 20 seconds of hard flicks and slides, including single moves of several hundred points. Details and limits are under [Measured results](#measured-results).

## How it works

Every tool surveyed (CursorBridge, CursorConfine, MouseLock) moves the pointer back *after* it crosses, so a frame of cursor can reach the other display. Cursor Fence stops the mouse from moving the cursor in the first place:

1. Far from the wall, the mouse behaves normally.
2. Within a guard band of the wall (240pt by default, wider when the pointer is moving fast), Cursor Fence disconnects the mouse from the cursor (`CGAssociateMouseAndMouseCursorPosition(false)`). It then moves the cursor itself from each mouse event's motion, through a HID-level event tap, stopping at the wall and sliding along it.
3. Once the pointer leaves the band, or a release key goes down, the mouse is reconnected.

Details that turned out to matter, each measured on the dev Mac:

- **The wall keeps the whole cursor image off the display, not just its tip.** macOS draws the cursor across a display seam: with the hotspot 3pt onto one display, the arrow still paints on its neighbour. The hotspot is held back by the cursor image's reach, 20–40pt scaled with the accessibility cursor size.
- **While disconnected, mouse motion is reported in pixels of the display under the cursor**, not points. On a 2x Retina panel, using the raw values doubled every move. Motion is divided by the display's backing scale.
- **Each warp normally freezes real mouse motion for 250ms.** It went unnoticed while the mouse was disconnected, but froze the pointer at the band's edge on hand-back. Cursor Fence sets the suppression interval to zero (the deprecated `CGSetLocalEventsSuppressionInterval`, called through `dlsym`), which cuts the freeze to 4ms.
- **Warps land on whole points**, so the app keeps the fractional position itself; slow trackpad drags near the wall don't stick.

Every way out reconnects the mouse: release key, leaving the band, the tap being disabled (it is re-enabled immediately), display reconfiguration, sleep, screen lock, ⌘Q, SIGTERM/SIGINT/SIGHUP, and crash signals. A watchdog also lets go if the tap stops hearing motion the HID system is still producing, or Accessibility is revoked. A guardian child process (`CursorFence --guardian <pid>`) reconnects the mouse if the app is killed outright.

The glow is a borderless, click-through, non-activating panel. Its frame is cut to the work display before it is shown, and checked again after AppKit has placed it; a frame that would touch the fenced display is never shown. The Settings window is moved off the fenced display too.

## Using it

Cursor Fence is a regular Dock app; it is active the whole time it runs. ⌘Q turns it off. Click the Dock icon, or press ⌘, for Settings:

- **Fenced display.** Stored by the display's own UUID, so the choice survives reconnecting and rearranging. If that display is unplugged, the fence is off until it returns.
- **Release keys.** Any combination of ⌃ ⌥ ⇧ ⌘ fn; all chosen keys must be held. Default ⌥. With none chosen, the pointer can never cross.
- **Guard band.** How far from the wall the app takes over. Wider is safer against very fast flicks; within it, the pointer feels the same as anywhere else.
- **Mechanism.** *Rewrite only* is a test mode that stays connected and pulls the pointer back after it crosses, the way other tools do. It exists for comparison; leave it on the default.
- **Diagnostics.** Rebounds, breaches (times hardware motion reached the wall while connected; should be 0), glows shown and refused, tap restarts and watchdog trips.

## Building

Needs Xcode 27 (Swift 6) on Apple silicon. The deployment target is macOS 26.0, which covers the compositor (macOS 26.6.2, arm64).

```bash
scripts/build-app.sh
```

This builds `build/CursorFence.app` and signs it with `Apple Development: you@example.com`; set `SIGN_IDENTITY` to override. A stable signing identity keeps the Accessibility grant across rebuilds, because macOS ties it to the bundle ID and certificate.

```bash
swift test
```

The unit tests cover the geometry and decision logic in `FenceCore` (edges, corners, offset and stacked arrangements, a 20,000-step random fuzz, release keys, pixel-to-point scaling, glow clipping).

## Permissions

- **Accessibility** for Cursor Fence: System Settings › Privacy & Security › Accessibility. The app asks on first launch and starts fencing within a second of the grant; no relaunch needed. Without it the app does nothing.
- **Screen Recording** is needed only by the test harness, not by the app.

On the compositor, the Accessibility click has to be made on site.

## Testing

`FenceHarness` covers the fenced display with a black window and records it with ScreenCaptureKit (cursor shown, up to 120 fps, capturing only that window plus the cursor). It counts frames with any bright pixels, i.e. a cursor, and also watches the window list for any Cursor Fence window on the fenced display.

```bash
swift build -c release --product FenceHarness
.build/release/FenceHarness leak --drive manual --seconds 20       # you flick the real mouse
.build/release/FenceHarness leak --drive synthetic --seconds 15    # synthetic stress
.build/release/FenceHarness leak --drive synthetic --hold option   # positive control
.build/release/FenceHarness feedback                               # recoil and glow
scripts/hand-tests.sh                                              # voice-cued hand and failsafe tests
```

For a trace of recent events (CSV: event type, connected or not, location, motion, resulting position, app switches), create the file `~/Library/Application Support/CursorFence/dump-trace`. Within a second the app replaces it with `trace.csv` beside it. Live counters are in `stats.json` in the same folder.

## Measured results

the dev Mac, 2026-11-01: built-in Liquid Retina XDR (main, 2x) and MSI PS341WU (1x), sharing a 299pt seam. MSI fenced, release key ⌥. Result files are in `test-results/`.

| Run | Pointer moved by | Events | Rebounds | Breaches | Frames with cursor on fenced display |
|---|---|---:|---:|---:|---:|
| Final build, hand flicks and slides (20s) | real mouse | 3,793 | 33 | 0 | **0** of 48 |
| Rewrite-only test mode, hand flicks (15s) | real mouse | 3,052 | 16 | 16, up to 25pt inside | 0 of 52 |
| Synthetic stress, ~1,000 events/s (15s) | `CGEventPost` | 11,989 | 50 | n/a | 179 of 869 |
| Positive control: synthetic with ⌥ held (8s) | `CGEventPost` | 6,481 | 0 | n/a | 292 of 501 |

How to read it:

- **The recording alone cannot prove the wall.** In rewrite-only mode, hardware motion put the cursor's hotspot up to 25pt inside the fenced display 16 times, and the warp-back pulled it out before any captured frame showed it. So "0 frames" says the capture saw nothing, and "0 breaches" says more. Every hardware event passes through the tap, which sees where the cursor is. With the default mechanism, the tap never saw the cursor reach the wall's zone.
- **Synthetic events cannot be fenced, by any event tap.** A posted event moves the cursor when it is posted, before any tap sees it; even dropping the event in the tap does not stop that. Cursor Fence corrects such events at once, but briefly they show. On air, that only matters for software that drives the pointer: remote-control tools and automation. The positive control proves the detector sees a cursor when one is there.
- **Recoil** measured 14pt on every push. **Glow** appeared on every rebound, always on the built-in, with no Cursor Fence window ever on the fenced display.
- **Failsafes, checked by hand:** after `kill -9` (mouse disconnected at the time), after quit, and after turning off Accessibility mid-session, the mouse moved normally each time.
- **Release key:** the ⌥ positive control crossed freely.

### Open questions

- **Small unexplained slips.** About 1.5% of driven events report the cursor up to 2–3pt from where the app last put it. They do not cross the wall, because the wall check runs on positions the app computes.
- **App switches may reconnect the mouse.** One earlier session, with clicking between apps inside a wide band, showed slips of up to 247pt. That looks like macOS reconnecting the mouse on an app switch, before the app re-asserts (it does so every 100ms while in the band). That session was also affected by the since-fixed 2x scaling; it has not been re-measured on the final build.
- **Very fast flicks from far away.** The band widens to six times the latest move. The closest any engagement came to the wall was 53pt across all hand runs, and 180pt in the final one. A single move larger than the band from a standing start could still land inside before the app takes over. It would be counted as a breach and pulled back.
- **Custom app cursors** larger than the system cursors (some brush cursors) can reach past the image allowance.

## Deploying to the compositor

Deployment is a separate on-site step: copy `CursorFence.app` to `/Applications`, launch it, grant Accessibility, choose the broadcast display, and confirm the rebound against the shared edge. Launch-at-login is not built in yet.
