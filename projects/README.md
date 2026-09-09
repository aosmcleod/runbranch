# Project definitions

One `.conf` per project. The file name, minus the extension, is the project's
name everywhere else.

`example.conf` is a documented template — copy it rather than starting from
nothing. Or let Runbranch write one for you: **Add a Project…** reads a
repository and proposes a config from what it finds, which is usually closer
than a hand-written first draft.

Every key is described in [docs/config.md](../docs/config.md). Check any
project with `./runbranch.sh doctor`, which names the command that fixes
whatever it finds.

Your own configs are gitignored. They name real repositories on your machine
and are nobody else's starting state. If you want a project definition to
travel with its repository instead — reviewable in a pull request, and present
on a fresh clone — put a `.runbranch` file at the repository root; a local
`.conf` still wins over it.
