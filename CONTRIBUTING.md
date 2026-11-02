# Contributing

Thanks for your interest in Cursor Fence. Issues and pull requests are welcome.

## Scope

Cursor Fence is deliberately focused: keep the mouse pointer off one display,
reliably enough for live broadcast output. Changes that serve that goal — or the
items on the README's roadmap (rebound ballistics, push-through, visual-indication
preferences) — are the easiest to land. Broader "mouse utility" features are
likely out of scope; please open an issue to discuss before building one.

## Building and testing

Requires Xcode 27 (Swift 6) on Apple silicon; deployment target macOS 26.0.

```bash
swift build                  # debug build of all products
swift test                   # unit tests for the FenceCore geometry/decision logic
scripts/build-app.sh         # signed build/CursorFence.app (set SIGN_IDENTITY)
```

The decision and geometry logic lives in `Sources/FenceCore` and is pure (no
system calls), so it is fully unit-tested — please add or update tests there for
any change to the fencing behavior. The app layer (`Sources/CursorFence`) and the
measurement harness (`Sources/FenceHarness`) exercise the system APIs.

## Measuring a change

Behavior near the wall is easy to get subtly wrong, so measure rather than eyeball.
`FenceHarness` and the scripts in `scripts/` record what actually reaches the
fenced display:

```bash
.build/release/FenceHarness leak --drive manual --seconds 20
scripts/hand-tests.sh
```

If you touch the background-wall path, read `docs/INTERNALS.md` first — it explains
why the obvious approaches don't hold and how the current one was arrived at.

## Pull requests

- Keep commits focused and explain *why* in the message, not just what.
- Note what you measured and on what display arrangement.
- By contributing, you agree your contributions are licensed under the MIT License.
