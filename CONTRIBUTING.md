# Contributing

Thanks for looking. This is a small tool with a narrow job — *put a branch on
a port and tell you when it is up* — and the fastest way to get a change merged
is to keep it inside that job.

## Getting set up

```bash
git clone https://github.com/aosmcleod/runbranch
cd runbranch
./make-app.sh          # needs only the Xcode command line tools
./tests/engine.sh      # 34 assertions, ~40s
```

No package manager, no project file, no dependencies to install.

## The shape of the thing

```
runbranch.sh          the engine. bash 3.2, no UI of its own
app/                  the front end. A window over the engine, one file per area
projects/*.conf       one file per project
tools/                trim/centre, crop, demo data, screenshots, lint
tests/engine.sh       engine tests
```

**The engine is the contract.** The app only ever calls subcommands —
`projects`, `branches`, `state`, `get`, `set`, `run`, `stop`, `paths`. If you
find the app reaching around the engine to do something itself, that is a bug
even if it works.

## Principles a change should respect

- **Never touch the working checkout.** No `checkout`, no `stash`, no
  `fetch` unless the user asked. If a feature needs to, the design is wrong.
- **No daemon.** Nothing runs in the background when the app is closed, beyond
  a run the user deliberately started.
- **Fail loudly, with the fix.** Every error names the command that resolves
  it. `die "what happened" "the command that fixes it"`.
- **The engine stays readable.** bash 3.2, no associative arrays, no `mapfile`,
  no here-documents inside `$( )`. `python3` is fair for parsing; a new
  runtime dependency is not.

## Before you open a pull request

```bash
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

Include `./runbranch.sh doctor` output and the relevant project's `.conf`
(with secrets removed — `COPY_FILES` names files that may contain them, though
the config itself should not).
