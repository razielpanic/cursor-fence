# Cursor Fence

![Platform: macOS 26+](https://img.shields.io/badge/platform-macOS%2026%2B-blue)
![Architecture: Apple silicon](https://img.shields.io/badge/arch-Apple%20silicon-black)
![License: MIT](https://img.shields.io/badge/license-MIT-green)

**Keeps the mouse pointer off one display — a hard wall, built and tested for live broadcast output.**

The pointer stops at the fenced display's edge as if it hit a wall: it springs back a few points and a short glow appears on your side of the edge. Hold a release key (⌥ by default) to cross. Leaving the fenced display is always free.

Cursor Fence was built for a live-broadcast setup, where a full-screen program output sits beside the operator's work monitor. In native full-screen, macOS reveals the menu bar and window title bar only when the pointer reaches that screen's top edge — so keeping the pointer off the broadcast screen keeps stray cursors, menus and window chrome off the air.

- **A real wall, not a pull-back.** Most tools let the cursor cross and then move it back, so a frame of cursor reaches the other display. Cursor Fence stops the mouse from moving the cursor in the first place (see [How it works](#how-it-works)).
- **Tested against Screen Sharing and remote control.** Broadcast machines are often driven headless over Screen Sharing, where the input model is different. Cursor Fence documents exactly what holds and what doesn't on that path (see [Remote control and Screen Sharing](#remote-control-and-screen-sharing)).
- **Honest about its limits.** Every measured result, failure mode and open question is written down, with the method to reproduce it.
- **Open source, MIT-licensed, no account, no network.** Runs entirely on-device.

Requires macOS 26 (Tahoe) or later on Apple silicon. Tested on macOS 26 and 27.

## How it compares

Other macOS tools that confine the cursor to one display — **EdgeCase**, **Virtual Wall**, **MouseLock**, **CursorConfine** — generally work by repositioning the pointer *after* it crosses the edge. That is fine for everyday "don't drift onto the other monitor" use, but for broadcast it means a cursor can flash onto the program output, and a fast move can reach the top edge and trip the menu bar before the pull-back lands.

Cursor Fence takes a different approach — it disconnects the mouse from the cursor near the wall and drives the cursor itself, so the pointer never crosses to begin with — and it is the only one of these written specifically around the broadcast case and measured against Screen Sharing. It is also free and open source; the App Store options are paid and closed, and CursorConfine is open but unsigned and uses the reposition-after approach.

This is a factual summary of published behavior, not a knock on those tools; they solve a different, broader problem well. If your need is "keep the pointer off the program display during a live show," Cursor Fence is built for exactly that.

## How it works

1. Far from the wall, the mouse behaves normally.
2. Within a guard band of the wall (240 pt by default, wider when the pointer is moving fast), Cursor Fence disconnects the mouse from the cursor with `CGAssociateMouseAndMouseCursorPosition(false)`. It then moves the cursor itself from each mouse event's motion, through a session-level event tap, stopping at the wall and sliding along it.
3. Once the pointer leaves the band, or a release key goes down, the mouse is reconnected.

Details that turned out to matter, each measured on hardware:

- **The wall keeps the whole cursor image off the display, not just its tip.** macOS draws the cursor across a display seam: with the hotspot 3 pt onto one display, the arrow still paints on its neighbour. The hotspot is held back by the cursor image's reach, 20–40 pt scaled with the accessibility cursor size.
- **While disconnected, mouse motion is reported in pixels of the display under the cursor,** not points. On a 2× Retina panel, using the raw values doubled every move. Motion is divided by the display's backing scale.
- **Each warp normally freezes real mouse motion for 250 ms.** It goes unnoticed while the mouse is disconnected, but froze the pointer at the band's edge on hand-back. Cursor Fence sets the suppression interval (the deprecated `CGSetLocalEventsSuppressionInterval`, called through `dlsym`), which removes the freeze.
- **Warps land on whole points,** so the app keeps the fractional position itself; slow trackpad drags near the wall don't stick.

A background app also holds the wall. macOS honors the mouse disconnect for the *active* application only, so when another app is in front the disconnect alone is not enough. Cursor Fence re-arms the disconnect through the cursor-warp path, which is not tied to the active app, so the wall stays hard whichever app has focus. The full account of how this was traced through the window server is in [`docs/INTERNALS.md`](docs/INTERNALS.md).

Every way out reconnects the mouse: release key, leaving the band, the tap being disabled (it is re-enabled immediately), display reconfiguration, sleep, screen lock, ⌘Q, `SIGTERM`/`SIGINT`/`SIGHUP`, and crash signals. A watchdog also lets go if the tap stops hearing motion the HID system is still producing, or if Accessibility is revoked. A guardian child process (`CursorFence --guardian <pid>`) reconnects the mouse if the app is killed outright. The design invariant is that the mouse is disconnected *only* while the fence is actively holding the pointer at the wall.

The glow is a borderless, click-through, non-activating panel, clipped to the work display and re-checked after the window server places it; a frame that would touch the fenced display is never shown.

## Install and build

Cursor Fence is not notarized or distributed on the App Store; build it from source.

**Requirements:** Xcode 27 (Swift 6) on Apple silicon. Deployment target macOS 26.0.

```bash
scripts/build-app.sh
```

This builds `build/CursorFence.app` and code-signs it. Set `SIGN_IDENTITY` to your own Apple Development identity:

```bash
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" scripts/build-app.sh
```

A stable signing identity keeps the Accessibility grant across rebuilds, because macOS ties the grant to the bundle ID and signing certificate. Copy `build/CursorFence.app` to `/Applications` to install.

```bash
swift test
```

The unit tests cover the geometry and decision logic in `FenceCore` (edges, corners, offset and stacked arrangements, a 20,000-step random fuzz, release keys, pixel-to-point scaling, glow clipping).

## Permissions

- **Accessibility** — System Settings › Privacy & Security › Accessibility (on macOS 27, "Device Control and Data Access"). The app asks on first launch and starts fencing within a second of the grant; no relaunch needed. Without it the app does nothing.
- **Screen Recording** — needed only by the test harness, not by the app itself.

## Using it

Cursor Fence is a regular Dock app; it is active the whole time it runs, and ⌘Q turns it off. Click the Dock icon, or press ⌘, for Settings:

- **Fenced display** — stored by the display's own UUID, so the choice survives reconnecting and rearranging. If that display is unplugged, the fence is off until it returns.
- **Release keys** — any combination of ⌃ ⌥ ⇧ ⌘ fn; all chosen keys must be held. Default ⌥. With none chosen, the pointer can never cross.
- **Guard band** — how far from the wall the app takes over. Wider is safer against very fast flicks; within it, the pointer feels normal.
- **Mechanism** — *Rewrite only* is a comparison/test mode that stays connected and pulls the pointer back after it crosses, the way other tools do. Leave it on the default (*Disassociate*).
- **Open at login** — registers the app as a login item.
- **Diagnostics** — rebounds, breaches (times hardware motion reached the wall while connected; should be 0), glows shown and refused, tap restarts, watchdog trips.

## Roadmap

Planned, not yet built:

- **Rebound ballistics preferences** — tune the spring-back feel (distance, duration, curve) rather than the current fixed recoil.
- **Push-through preference** — an option to cross by pushing hard and steadily into the wall for a moment, as an alternative to holding a release key.
- **Visual indication preferences** — control the glow (color, size, intensity, or off), for operators who want a quieter or louder edge.

Contributions and issues welcome.

## Testing and measured results

Cursor Fence ships with a harness, `FenceHarness`, that covers the fenced display with a black window, records it with ScreenCaptureKit (cursor shown, up to 120 fps), counts frames containing any cursor, and watches the window list for any Cursor Fence window on the fenced display.

```bash
swift build -c release --product FenceHarness
.build/release/FenceHarness leak --drive manual --seconds 20       # you flick the real mouse
.build/release/FenceHarness leak --drive synthetic --seconds 15    # synthetic stress
.build/release/FenceHarness leak --drive synthetic --hold option   # positive control
scripts/hand-tests.sh                                              # voice-cued hand and failsafe tests
```

On a two-display Apple silicon Mac (built-in Retina panel at 2× beside an external 1× monitor), with the external display fenced:

| Run | Pointer moved by | Events | Breaches | Frames with cursor on fenced display |
|---|---|---:|---:|---:|
| Hand flicks and slides, 20 s | real mouse | 3,793 | 0 | **0** of 48 |
| Rewrite-only mode (pull-back), 15 s | real mouse | 3,052 | 16, up to 25 pt inside | 0 of 52 |
| Synthetic stress, ~1,000 events/s, 15 s | `CGEventPost` | 11,989 | n/a | 179 of 869 |
| Positive control: synthetic with ⌥ held | `CGEventPost` | 6,481 | n/a | 292 of 501 |

How to read it:

- **With the default mechanism, a real mouse never carried the cursor into the fenced display.** "0 breaches" is the stronger statement: every hardware event passes through the tap, and the tap never saw the cursor reach the wall's zone. In rewrite-only (pull-back) mode under the same flicks, hardware motion put the cursor up to 25 pt inside the fenced display 16 times and was yanked back — which is what the disconnect approach avoids.
- **Synthetic (posted) events cannot be fenced by any event tap.** A posted event moves the cursor when it is posted, before any tap sees it. Cursor Fence corrects such events immediately, but they show briefly. The positive control confirms the detector sees a cursor when one is present.
- **Background wall:** with another app in front, steady pushing into the wall holds the pointer in place 96–100% of events, matching the active-app case, after the fix described in [`docs/INTERNALS.md`](docs/INTERNALS.md).

### Remote control and Screen Sharing

A broadcast machine is often run headless over Screen Sharing. Screen Sharing input arrives as **posted** events (absolute cursor positions), which move the cursor before any event tap sees them — so on that path Cursor Fence can only pull the pointer back, not pre-empt it, and the disconnect approach does not apply. In testing, the pointer briefly showed on the fenced display between pull-backs, but the on-air goal still held: the pointer could not sit at the display's top edge long enough to bring down the menu bar or title bar, and a broadcast capture that excludes the cursor never showed it. Posted clicks that land on the fenced display are dropped (with their releases) unless a release key is held.

If you drive a broadcast machine this way, the most reliable configuration is to have the Screen Sharing viewer show only the work display, so it never sends a cursor position onto the program display at all.

### Known limits

- **Very fast flicks from a standing start.** The guard band widens with pointer speed, but a single move larger than the band, from rest, could land inside before the app takes over. It is counted as a breach and pulled back.
- **Drags.** macOS ignores a warp while a mouse button is held, so the wall is soft during a drag.
- **Shake-to-locate.** macOS's "shake the pointer to enlarge it" feature is triggered by rapid pointer motion and degrades the fence while it is active, for any front app.
- **Custom oversized app cursors** (some brush cursors) can reach past the cursor-image allowance.
- **Small slips.** About 1–2% of driven events report the cursor 2–3 pt from where the app last placed it.

A diagnostic trace is available for debugging: create `~/Library/Application Support/CursorFence/dump-trace` and within a second the app writes `trace.csv` beside it (event type, connected or not, location, motion, resulting position, app switches). Live counters are in `stats.json` in the same folder.

## How it's organized

- `Sources/FenceCore` — pure geometry and decision logic (no system calls); fully unit-tested.
- `Sources/CursorFence` — the app: event tap, cursor driving, glow, settings, failsafes.
- `Sources/FenceHarness` — the measurement harness.
- `docs/INTERNALS.md` — the window-server investigation behind the background-wall fix.

## License

MIT — see [LICENSE](LICENSE).
