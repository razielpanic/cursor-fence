# Internals: how the background wall was traced and fixed

This note records how Cursor Fence comes to hold the wall even when it is not the
active application. It is the kind of detail most users never need, kept here
because it is the hard part of the problem and because the method — reading the
window server directly rather than guessing — is worth preserving.

All addresses below are from SkyLight (the private framework behind the window
server) as extracted from the dyld shared cache on an Apple silicon Mac. Offsets
are build-specific; treat them as a map, not a contract.

## The symptom

Near the wall, Cursor Fence disconnects the mouse from the cursor with
`CGAssociateMouseAndMouseCursorPosition(false)` and drives the cursor itself.
Measured with a real mouse pushed into the corner while a script brought
different apps to the front, the correction held ~99% of the time while Cursor
Fence was the active app, but only ~20–36% with another app (Finder, say) in
front. Re-asserting the disconnect on every event changed nothing.

## How macOS decides whose disconnect to honor

The disconnect is a single system-wide byte. `_CGXDecoupleCursorAndMouse`
(0x182898028) writes it with no check on the caller. What differs is who gets to
call it:

- **The `Associate` request is gated on the front process.**
  `__XAssociateMouseAndMouseCursorPosition` (0x182b396e4) records the request on
  the caller's own connection, then applies the disconnect only when the caller
  is `_CGXForegroundConnection` (0x1828d1874) — which resolves to
  `_CPXGetFrontProcessesConnectionID`, the front process. A background app's
  request is remembered but never applied.

- **App activation re-derives the state from the new front process.**
  `foregroundSwitchNotifyProc` (0x1828d0ae4) reads the incoming front
  connection's recorded bit on every switch and sets the disconnect from that.
  So when another app comes forward, its cleared bit re-couples the mouse, and
  re-asserting from the background cannot override it. The useful flip side:
  because the bit persists on Cursor Fence's own connection, its disconnect
  re-applies by itself the moment it becomes front again.

So there is no entitlement or connection property that lets a background app be
treated as the front process for this decision. (`SetsCursorInBackground` /
`kCGSSetsCursorInBackgroundTagBit` exist in the framework but are not consulted
on the associate, warp, or foreground-switch paths — verified by reading all
three. Setting that connection property changed nothing, as expected.)

## The ungated path: cursor warps

`__XWarpCursorPosition` (0x182b39474) also toggles the same system-wide
disconnect byte, and it has **no** front-process check. When a warp carries a
local-events suppression interval of 1 ms or more (threshold constant at
0x182c2b4e0), the handler disconnects the mouse and schedules the re-couple at
`now + interval`; below the threshold it re-couples. The interval is the value
`CGSetLocalEventsSuppressionInterval` stores (a SkyLight global at
0x1eb11c000 + 0xb3c); every warp reads it.

This also explained an earlier mystery: the "250 ms freeze" after a warp was this
disconnect persisting after the last warp, not event suppression — the warp path
never touches the separate local-events-suppression mechanism
(`_CGXSuppressLocalEventsForInterval`, a different routine entirely).

Because Cursor Fence already warps the cursor to drive it, it can set the
suppression interval so that each driving warp re-arms the disconnect from
whatever app is front. The pointer-move path that honors this,
`_WSHIDUpdateCursorLocationByRelativeDelta` (0x182944b08), skips the cursor move
exactly when the byte is set, with no front-process check of its own — confirmed
it is the sole gate, and that re-coupling does not teleport banked motion.

## Getting it to hold steadily

Simply re-arming on every warp got the background wall from ~40% to ~85–90%, but
left a visible twitch. Four re-couplers had to be removed or understood:

1. **Recoil warps re-coupled.** The spring-back animation warps ~34 times per
   contact; those warps were carrying a zero interval, which re-couples the
   mouse for the ~140 ms of each recoil. Fixed by carrying the keep-alive on
   recoil warps while disconnected.
2. **Band-exit re-coupled on every drift.** Brief drift past the guard band
   dropped the disconnect. Fixed so only a true disengage releases it, through a
   single zero-interval warp (which re-couples even from the background, where
   `CGAssociate(1)` is ignored).
3. **The keep-alive timer is replace, not append.**
   `_reschedule_callback_on_session` runs in replace mode — one re-couple timer
   is pushed forward on each warp, so it never fires during continuous motion.
   Ruled out as a cause.
4. **The pinned-no-warp lapse (the dominant one).** Pushing into the wall pins
   the cursor at the band edge, so the decider asks for no correction and issues
   no warp. With nothing to re-arm it, a short keep-alive lapsed between
   corrections, the byte dropped, the next push slipped, and the fence re-pinned
   — the twitch.

**The fix that shipped:** a long keep-alive. Each correction warp carries a
multi-second suppression interval (default 2 s, overridable via
`defaults write com.razielpanic.CursorFence suppressionIntervalMs -float <ms>`),
long enough to span the pinned stretches where no warp fires, so the disconnect
does not lapse between corrections. The active-app path is unchanged: with the
sticky "explicitly decoupled" flag set, the warp path skips the interval logic
entirely. The watchdog still re-couples within 150 ms if the tap is ever starved,
so a long interval fails safe.

A rejected alternative, worth recording: warping on *every* engaged event (a
no-op move while pinned) re-arms the disconnect continuously and held the wall at
99–100% with zero breaches — but setting the cursor position hundreds of times a
second reads to macOS as a pointer *shake* and triggered the shake-to-locate
magnifier during ordinary push-move-push. The long keep-alive warps only on real
corrections, which avoids that.

## Measured result of the fix

With another app in front and steady pushing into the wall: held 96–100% of
events, matching the active-app case, up from the ~40% walk-through before.
Slips fell from one to two thousand per run to a few dozen; breaches to a handful
at zero-point depth. The trade is a slightly looser wall than the warp-every-event
version — a brief breach of a few tens of points is possible during a pin that
outlasts the keep-alive — and a correspondingly longer potential stray disconnect
on disengage, bounded by the 150 ms watchdog.

## What this does and doesn't cover

This whole mechanism concerns a **local mouse**. Input arriving as posted events
(Screen Sharing, automation) moves the cursor through the absolute-position path,
not the relative-motion path gated by the disconnect byte, so none of the above
applies to it — the fence can only pull such input back, not pre-empt it. See the
README's "Remote control and Screen Sharing" section.
