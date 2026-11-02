# Changelog

All notable changes to Cursor Fence are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims to
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] — 2026-11-01

First public release.

### Added
- Hard cursor wall at a chosen display's edge, by disconnecting the mouse from
  the cursor near the wall and driving the cursor directly, so the pointer never
  crosses — rather than pulling it back after it crosses.
- Whole-cursor-image clearance, so the arrow never paints across the display
  seam, scaled with the accessibility cursor size.
- Background wall: holds even when another application is in front, via the
  cursor-warp disconnect path (see `docs/INTERNALS.md`).
- Release keys (any combination of ⌃ ⌥ ⇧ ⌘ fn) to cross on demand.
- Guard band that widens with pointer speed.
- Rebound spring-back and an edge glow, clipped so it never touches the fenced
  display.
- Posted-click blocking on the fenced display (for Screen Sharing / remote
  control), with release-key override.
- Failsafes: reconnects the mouse on release, band exit, tap disable, display
  reconfiguration, sleep, screen lock, quit, termination signals, and crashes; a
  watchdog and a guardian child process cover a wedged tap or a hard kill.
- `FenceHarness` measurement tool and a unit-tested `FenceCore` geometry/decision
  library.

### Known limitations
- Very fast flicks from a standing start, drags, macOS shake-to-locate, and
  oversized custom app cursors are documented in the README.
- Input that arrives as posted events (Screen Sharing, automation) is pulled
  back, not pre-empted.
