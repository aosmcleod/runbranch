# Contributing

Thanks for looking. This is a small tool with a narrow job — *put a branch on
a port and tell you when it is up* — and the fastest way to get a change merged
is to keep it inside that job.

## Getting set up

```bash
git clone https://github.com/aosmcleod/runbranch
cd runbranch
./make-app.sh          # the Xcode command line tools, and Go for the engine
./tests/engine.sh      # ~40s
```

On Windows, with Go and the .NET 10 SDK:

```powershell
.\windows\make-app.ps1   # engine + app into dist\windows\Runbranch\
```

No package manager beyond Go's and NuGet's, and nothing to install by hand.

That gives you a **development build**: the mark with its colours inverted, a
badge in About, and no update check — because an update would replace the build
you are working on with whatever was last released. It is the default because
the alternative is remembering a flag, and forgetting one is silent.

`./make-app.sh --release` gives the shipping build. `make-dmg.sh` and
`tools/screenshot.sh` both refuse anything else, so a development build cannot
reach a disk image or the documentation by accident.

## The shape of the thing

```
engine/               the engine, in Go. One binary for macOS and Windows, no UI
runbranch.sh          the previous engine, kept as the Mac fallback until retired
app/                  the Mac front end. A window over the engine, one file per area
windows/              the Windows front end. The same window, in WinUI 3
projects/*.conf       one file per project
tools/                trim/centre, crop, demo data, screenshots, lint
tests/engine.sh       engine tests
```

**The engine is the contract.** Both apps only ever call subcommands —
`projects`, `branches`, `state`, `get`, `set`, `run`, `stop`, `paths` — and
parse what they print, as pinned in
[docs/specs/windows-port-engine-contract.md](docs/specs/windows-port-engine-contract.md).
If you find an app reaching around the engine to do something itself, that is
a bug even if it works. A change to what the engine prints is a change to both
apps.

## Principles a change should respect

- **Never touch the working checkout.** No `checkout`, no `stash`, no
  `fetch` unless the user asked. If a feature needs to, the design is wrong.
- **No daemon.** Nothing runs in the background when the app is closed, beyond
  a run the user deliberately started.
- **Fail loudly, with the fix.** Every error names the command that resolves
  it. `die "what happened" "the command that fixes it"`.
- **The engine stays readable.** The standard library plus `golang.org/x/sys`
  and `x/term`, and nothing else. Per-OS code lives in `engine/internal/proc`
  and in `_windows.go` / `_darwin.go` files beside what needs it; everything
  else is written once.

## Before you open a pull request

```bash
(cd engine && go vet ./... && go test ./...)
./tools/lint.sh && ./tests/engine.sh
```

`lint.sh` checks bash syntax and one specific mistake — reading a variable in
the same `local` statement that declares it — because that one has bitten this
file three times.

**Add a test if you fixed a bug.** See [docs/TESTING.md](docs/TESTING.md): the
bar is that a test remembers something that actually went wrong, not that
coverage went up.

## Commit messages

Say what changed and why it was wrong before. The *why* is the part worth
writing; a diff already shows the what. If you found the cause surprising, say
so — the next person will find it surprising too.

## Things likely to be turned down

- **Sharing or tunnelling a run.** What is running is on your machine, for you.
  See the argument in [docs/ROADMAP.md](docs/ROADMAP.md); it is a deliberate
  boundary rather than an oversight.
- **A configuration UI that replaces the file.** The file is the point: it is
  versioned, diffable, and reviewable in a pull request.
- **Anything that makes the engine unreadable** in exchange for elegance.

## Reporting a bug

Include `runbranch doctor` output and the relevant project's `.conf`
(with secrets removed — `COPY_FILES` names files that may contain them, though
the config itself should not).
