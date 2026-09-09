# Testing

## What is tested, and why those things

`tests/engine.sh` — 112 assertions against a throwaway fixture repo and a
throwaway state directory. Never against real projects.

`tests/ui.sh` — 8 assertions against the real app, launched over the demo data.

```bash
./tests/engine.sh        # the engine
./tests/ui.sh            # the app
./tests/engine.sh -v     # show every assertion
./tools/lint.sh          # bash syntax, and the mistakes this file has made
```

**Every case corresponds to a bug that actually happened.** That is the
admission bar: a test that has never caught anything is a guess about where
bugs live, and this project has better evidence than guesses. Examples:

| Test | The bug it remembers |
|---|---|
| `row has every column` | `git for-each-ref` does not interpret `\t`, so every branch row collapsed into one field |
| `set survives a multi-line value` | `set` passed values through `awk -v`, which cannot carry a newline, and **emptied a config file** |
| `set reverts a config that will not load` | a failed write used to leave the broken file behind |
| `the checkout did not move` | the whole premise of the tool; worth asserting rather than trusting |
| `admits when it cannot tell` | `propose` used to emit a plausible command that did not exist, failing minutes into a run |
| `reclaim removes the file` | a crash left state behind that read as a phantom run |
| `refuses while running` | removal would have deleted the config from under a live run, orphaning servers with nothing left that knew how to stop them |

## What is not tested, honestly

- **The SwiftUI layer.** No tests, and this is the real gap rather than an
  acceptable one. On 2026-09-08 it cost two bugs that both nearly shipped: the
  run strip held the health monitor as a plain property instead of an
  `@ObservedObject`, so a healthy run read "Starting" indefinitely while the
  poll returned 200 to nobody; and applying the saved presentation at launch
  called through to `openWindow`, so every start opened a duplicate window.

  Neither was found by looking for it — the first showed up as an amber dot next
  to a server that was demonstrably up, the second as a screenshot crop region
  that inexplicably spanned two windows. Both were in `@Published` and
  window-lifecycle wiring rather than in logic a unit test would reach, so the
  fix is a smoke test that launches the real app and asserts a few facts about
  the result. `tools/screenshot.sh` already does the hard part. Tracked as 1.9
  in [ROADMAP.md](ROADMAP.md).
- **The install path.** `pnpm install` against a real registry is slow and
  network-dependent; the fixture uses `python3 -m http.server` instead.
- **Per-run databases.** Needs a live Postgres, so it is verified by hand
  rather than in the suite. The check that matters: run a branch whose
  migrations differ from the shared database and confirm the two diverge. Done
  against a real project — the run database took the branch's 169 migrations
  while the shared one kept its 173, which is the whole point of the feature.
- **`gh` interaction.** The PR cache is seeded directly in tests and in the
  demo, so nothing here needs a GitHub token.

## Before committing

```bash
./tools/lint.sh && ./tests/engine.sh && swiftc -parse-as-library -O app/*.swift -o /tmp/rb
```

Roughly 40 seconds, most of it the lifecycle test starting and stopping a
real server.

## Adding a test

Add it when something breaks, and make the name say what broke. `is`, `has` and
`ok` are the whole framework; there is deliberately no more than that.
