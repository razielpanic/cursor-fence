# Cursor Fence

Keeps the mouse pointer off one display. The pointer stops at that display's edge as if it hit a wall: it springs back a few points and a short glow appears on your side of the edge. Hold the release key (⌥ by default) to cross. Leaving the fenced display is always free.

Built for the a broadcast installation broadcast compositor, where the fullscreen program output sits beside the operator's work monitor. In native fullscreen, macOS shows the menu bar and title bar only when the pointer reaches that screen's top edge. So keeping the pointer off the broadcast screen keeps cursors, menus and window chrome off the air.

**Measured on the dev Mac (2026-11-01), real mouse, final build:** 0 frames with a cursor on the fenced display, and 0 times hardware motion reached it. That's 3,793 events over 20 seconds of hard flicks and slides, including single moves of several hundred points. Details and limits are under [Measured results](#measured-results).

**The hard wall was front-app-only; a warp-based route now holds it as hard from the background.** The window server honors the `CGAssociateMouseAndMouseCursorPosition` request for the active app alone. A warp that carries a suppression interval decouples the mouse too, and that path has no active-app check, so driving warps keep the pointer off the fenced display even when another app is in front. Warping on every engaged event (a no-op move while the cursor is pinned at the wall) re-arms the decouple continuously, which holds the background wall at 99–100%, matching the front app. Measured and explained under [The wall needs Cursor Fence in front](#the-wall-needs-cursor-fence-in-front-relix-2026-11-01). Remote input over Screen Sharing never used the disconnect, so the compositor is unaffected.

## How it works

Every tool surveyed (CursorBridge, CursorConfine, MouseLock) moves the pointer back *after* it crosses, so a frame of cursor can reach the other display. Cursor Fence stops the mouse from moving the cursor in the first place:

1. Far from the wall, the mouse behaves normally.
2. Within a guard band of the wall (240pt by default, wider when the pointer is moving fast), Cursor Fence disconnects the mouse from the cursor (`CGAssociateMouseAndMouseCursorPosition(false)`). It then moves the cursor itself from each mouse event's motion, through a session-level event tap, stopping at the wall and sliding along it.
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
- **Open at login.** Registers the app as a login item.
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

### Clicking breaks the wall (explained: clicks switched apps)

The hand runs above were flicks and slides with no clicks. A run with clicks and short drags between two apps beside the wall gave a different result: `test-results/appswitch2.json`. With the mouse supposedly disconnected, 586 of 1,085 events showed the mouse moving the cursor anyway. Each crossing was caught and pulled back: 235 breaches, up to 57pt inside the fenced display. The capture recorded 0 leaked frames, but the rewrite-only comparison above shows it misses warp-back transients, so read that 0 as unproven.

Those clicks made other apps active, and that is what dropped the disconnection: see [The wall needs Cursor Fence in front](#the-wall-needs-cursor-fence-in-front-relix-2026-11-01). Whether a click with Cursor Fence itself in front affects it hasn't been tested.

### Remote control

The broadcast show is run entirely over Screen Sharing on a headless compositor. If Screen Sharing input arrives as posted events, like the synthetic runs above, the cursor moves before any event tap sees it. Cursor Fence can then only pull it back, and the disconnection path does not apply. The Settings window's diagnostics name the process that last posted pointer motion, which settles this on the compositor. A likely configuration-level fix to test there: have the Screen Sharing client show only the work display, so it never sends a position on the broadcast display.

### Other open questions

- **Small unexplained slips.** In the flick-only runs, about 1.5% of driven events report the cursor up to 2–3pt from where the app last put it.
- **Very fast flicks from far away.** The band widens to six times the latest move. The closest any engagement came to the wall was 53pt across all hand runs, and 180pt in the final one. A single move larger than the band from a standing start could still land inside before the app takes over. It would be counted as a breach and pulled back.
- **Custom app cursors** larger than the system cursors (some brush cursors) can reach past the image allowance.

### Clicks over Screen Sharing (2026-11-01)

Screen Sharing posts each click at the viewer's pointer, which can sit over Broadcast between pull-backs. Posted clicks on the fenced display are now dropped, along with their releases, unless a release key is held. RP confirmed on the compositor that clicks are blocked and that ⌥ lets them through.

### The wall needs Cursor Fence in front (the dev Mac, 2026-11-01)

The corner escapes on the dev Mac come from which app is active. macOS honors `CGAssociateMouseAndMouseCursorPosition(false)` only while Cursor Fence is the active app. With any other app in front, the local mouse stays connected to the cursor, and calling it again on every event changes nothing. The fence then works the way rewrite-only mode does: it pulls the pointer back after the mouse moves it. About half of those pull-backs are overrun by motion already on its way, and that is how the pointer walks through the corner.

Measured with `scripts/corner-windows.sh`: RP pushed the real mouse into the corner without clicking while the script brought a different app to the front for each 15-second window. `scripts/trace-windows.py` scores each window. A correction counts as held when the next event finds the cursor where Cursor Fence put it.

| Front app | Run 1 held | Run 2 held |
|---|---|---|
| Cursor Fence | 99%, 99%, 99% (5,239 of 5,292) | 99% (2,005 of 2,020) |
| Finder | 30%, 32% | 36%, 24% |
| Claude | 33% | 34%, 20% |

The traces are `test-results/corner-20261101-143557.csv` and `corner-20261101-144755.csv`. Run 2 was a build that also set the window server's `SetsCursorInBackground` connection property; it made no difference and was dropped. The disassembly below shows why: that property is not consulted on the associate, warp, or foreground-switch paths. The slipped events carry motion in points, as connected motion does, where disconnected motion arrives in pixels. In the background windows, most of the corrections that "held" were the cursor pinned at the screen's top edge.

This accounts for the earlier mixed results. Re-scored by front app, the older app-switch traces show the mouse connected under FenceHarness, System Settings and Claude alike. `scripts/build-app.sh --install` relaunches the app, which puts it in front, so a test run right after an install sees the hard wall until something else is clicked. That probably explains the split build's 0-breach run and its 314-breach run that followed, but those runs left no trace, so it isn't confirmed.

#### What the window server checks (SkyLight, disassembled 2026-11-01)

SkyLight was pulled from the dyld shared cache on the dev Mac and read. The decouple is one system-wide byte that `_CGXDecoupleCursorAndMouse` writes with no caller check. What differs is who gets to call it.

- **The decouple is one system-wide byte.** `_CGXDecoupleCursorAndMouse` (0x182898028) writes it with no caller check. What differs is who may call it.
- **The Associate request is gated on the front process.** `__XAssociateMouseAndMouseCursorPosition` (0x182b396e4) records the request on the caller's own connection, then calls the decouple only when the caller is `_CGXForegroundConnection` (0x1828d1874), which resolves to `_CPXGetFrontProcessesConnectionID` — the front process. A background app's request is remembered but never applied.
- **App activation re-derives the decouple from the new front process.** `foregroundSwitchNotifyProc` (0x1828d0ae4) reads the incoming front connection's recorded bit on every switch and sets the decouple from that. So when Finder or Claude comes forward its cleared bit re-couples the mouse, and re-asserting from the background cannot override it. The flip side is useful: because the bit persists on Cursor Fence's connection, its decouple re-applies by itself the moment it is front again.
- **The warp path is not gated.** `__XWarpCursorPosition` (0x182b39474) decouples whenever the warp carries a suppression interval of 1ms or more (threshold constant 0x182c2b4e0), with no front-process check, and reschedules the release at now plus the interval. The interval is the value `CGSetLocalEventsSuppressionInterval` stores (SkyLight global 0x1eb11c000+0xb3c); every warp reads it. So the 250ms freeze seen earlier was this decouple persisting after the last warp, not event suppression — the warp path never touches the separate local-events-suppression mechanism. The full branch logic is in the shared session notes.

#### The background fix (2026-11-01): the warp path now holds as hard as the front app

A background app cannot set the decouple the way the front app does. The front app's `CGAssociate(0)` sets the server's sticky "explicitly decoupled" flag, and the byte then stays set for the whole engagement with no renewal. A background app has only the warp path, which decouples for the warp's suppression interval and must be re-armed by further warps. The catch is that pushing into the wall pins the cursor at the band edge, so the decider asks for no correction and issues no warp — and with nothing to re-arm it, the decouple lapsed between corrections, the byte dropped, the next push slipped the cursor, and Cursor Fence re-pinned it. That cycle was a visibly twitchy pointer in the background.

The fix is one change in `FenceEngine`: warp on **every** engaged event, not only when the cursor needs correcting. A warp to the cursor's current position is a no-op move that carries the keep-alive (`suppressSeconds`, default 80ms, `defaults write com.razielpanic.CursorFence suppressionIntervalMs -float <n>`), so the decouple is renewed continuously while pinned and never lapses. Front behavior is unchanged (with the explicit flag set, the warp path skips the interval logic). The one release is a true disengage, through a single zero-interval warp that re-couples even from the background. The watchdog still re-associates within 150ms if the tap is starved, so the interval fails safe.

Measured across two clean hardware runs with the fix installed (steady pushing, no clicks):

| Front app | held % (trace-windows) | Cursor on the fenced display |
|---|---|---|
| Cursor Fence | 99–100% | none |
| Finder | 99–100% | none |
| Claude | 100% | none |

Slips fell from ~1,000–2,000 per run to 34 of 15,262 driven events, breaches to 2 at 0pt depth. The background pointer now feels as solid as the front-app wall. Getting here meant eliminating four re-couplers in turn: recoil warps that re-coupled for ~140ms per contact, a band-exit re-couple on every drift past the band, the keep-alive fuse (ruled out — `_reschedule_callback_on_session` runs in replace mode, one fuse pushed forward per warp), and finally the pinned-no-warp lapse above, which was the dominant one.

**Shake-to-locate is a separate gap.** macOS's "Shake mouse pointer to locate" enlarges the cursor on a rapid shake. Triggering it repeatedly drops held to ~87–92% for the front app and the background alike (a third run where it fired a lot), so it degrades the fence regardless of which app is front — a distinct interaction from the one fixed here, not a regression. It does not reach the compositor, whose input is posted events.

Consequences:

- **The compositor is unaffected.** Its input is Screen Sharing's posted events, which the disconnect never covered.
- **On a Mac with a local mouse**, the wall is now hard and smooth whether or not Cursor Fence is in front, up from the old state where the background walked through at ~40% held. Activating Cursor Fence near the wall stays ruled out: it would take keyboard focus from the user.
- **Drags are a separate known gap:** macOS ignores a warp while a button is held. Posting a corrected drag instead didn't move the cursor and broke later warps.
- **Shake-to-locate is a separate gap:** triggering macOS's shake-to-enlarge-cursor repeatedly drops held to ~90% for any front app, background or not.

## Deploying to the compositor

Both Macs run Cursor Fence from `/Applications`. On the dev Mac, `scripts/build-app.sh --install` builds it, replaces the installed copy and relaunches it. On the compositor, copy the built app to `/Applications` and remove the copy in `build/`. Launch it, grant Accessibility, choose the broadcast display, switch on Settings › Startup › Open at login (approve it in System Settings › General › Login Items if asked), and confirm the rebound against the shared edge.

### Compositor results so far (2026-11-01, macOS 26.6.2, off-air)

Run over SSH with `open -W build/FenceHarness.app --args leak … --json PATH` (FenceHarness.app holds Screen Recording, so sshd doesn't need it). Broadcast is fenced, directly left of Main.

| Run | Leaked frames | Notes |
|---|---|---|
| Synthetic stress, fenced | 70 of 470 | Every leak is the cursor image straddling the seam: 2–6 px at Broadcast's right edge, the hotspot was on Main. The app saw 2,933 of 11,881 posted moves (session-level coalescing); 12 rebounds, glows on Main only, 0 windows on Broadcast. |
| ⌥ control | 0 of 255 | **Unexplained.** The control should show a cursor on Broadcast, and the app counted 0 events during it, though the engine counts synthetic moves before checking release keys. Until this is explained the control doesn't validate the detector on this Mac. |

| RP flicking over Screen Sharing, viewer showing all displays | 90 of 769 | The pointer's tip landed 160–500 px inside Broadcast, 110–150 px below its top edge. |
| The same, viewer showing only Main | 210 of 765 | The tip still landed up to ~240 px inside Broadcast, 47–83 px below its top edge. |

Screen Sharing input arrives from ScreensharingAgent at the session level, as posted absolute positions. The app pulls the pointer back on every event, and the agent's next position puts it straight back onto Broadcast, so the cursor shows there between events. Showing only Main in the viewer doesn't stop it. The on-air goal still held in both runs: the tip never reached Broadcast's top edge, and RP saw no menu bar or presentation chrome slide down. The show's OBS capture leaves the cursor out, and RP couldn't see the brief incursions at that frame rate. So what matters on air is that the pointer can't sit at Broadcast's top edge long enough to bring down the menu bar or title bar, and the fence achieves that. Breaches from posted events aren't counted yet (`app.breaches` counts local mouse motion only).
