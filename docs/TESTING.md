# Testing

## What is tested, and why those things

`tests/engine.sh` — 34 assertions against a throwaway fixture repo and a
throwaway state directory. Never against real projects.

```bash
./tests/engine.sh        # run
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

## What is not tested, honestly

- **The SwiftUI layer.** No tests. Every UI bug this project has had was found
  by looking at it, and several of my "fixes" were wrong until someone did.
  `swiftc` catching zero warnings is the only automated check.
- **The install path.** `pnpm install` against a real registry is slow and
  network-dependent; the fixture uses `python3 -m http.server` instead.
- **Per-run databases.** Needs a live Postgres. Covered manually against
  Studio, and the result recorded in `PLAN.md`.
- **`gh` interaction.** The PR cache is seeded directly in tests and in the
  demo, so nothing here needs a GitHub token.

## Before committing

```bash
./tools/lint.sh && ./tests/engine.sh && swiftc -parse-as-library -O app/RunBranch.swift -o /tmp/rb
```

Roughly 40 seconds, most of it the lifecycle test starting and stopping a
real server.

## Adding a test

Add it when something breaks, and make the name say what broke. `is`, `has` and
`ok` are the whole framework; there is deliberately no more than that.
