<#
.SYNOPSIS
  The Windows counterpart of tools/make-demo.sh: the same fictional repos,
  branches, people and pull requests, so the Windows docs set shows what the
  Mac's does. Nothing here touches or references a real project.

.DESCRIPTION
  The repos are real git repos and the running target is a real server, so a
  run genuinely starts and health genuinely goes green (see make-demo.sh for
  why that matters). Differences from the Mac's, both forced:

  - `python`, not `python3`: the Windows installer puts python.exe on PATH.
  - -Port: the Mac's demo serves on 4173. If something already listens there,
    pass another base; the other projects keep their offsets from it
    (base+1, base+1, base+3), so Lumen UI still collides with Aperture API.

  It is written to a throwaway folder, not to the repo, and the folder is
  given in its long form: under the 8.3 name %TEMP% often holds, the app
  cannot abbreviate the home folder to ~ and a capture would show the
  account name.

.EXAMPLE
  ./tools/make-demo.ps1                      # build it
  ./tools/make-demo.ps1 -Port 4273           # when 4173 is taken
  ./tools/make-demo.ps1 -Clean               # remove it
#>
param(
    [string]$Dir = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Temp\runbranch-demo'),
    [int]$Port = 4173,
    [switch]$Clean
)
$ErrorActionPreference = 'Stop'

function Remove-Demo([string]$path) {
    if (Test-Path $path) {
        # git marks pack files read-only, which Remove-Item -Recurse trips on.
        Get-ChildItem $path -Recurse -Force -File | ForEach-Object { $_.IsReadOnly = $false }
        Remove-Item $path -Recurse -Force
    }
}

if ($Clean) { Remove-Demo $Dir; "removed $Dir"; return }

Remove-Demo $Dir
foreach ($d in 'repos', 'projects', 'state') { New-Item -ItemType Directory -Force (Join-Path $Dir $d) | Out-Null }

$Me = 'dana@example.com'

function Invoke-Git([string]$repo) {
    # Quiet and never interactive: this runs unattended.
    & git.exe -C $repo @args 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "git -C $repo $args failed" }
}

function When([int]$daysAgo) { (Get-Date).ToUniversalTime().AddDays(-$daysAgo).ToString("yyyy-MM-ddTHH:mm:ssZ") }

function With-Author([string]$name, [string]$email, [int]$ago, [scriptblock]$do) {
    $w = When $ago
    $env:GIT_AUTHOR_NAME = $name; $env:GIT_AUTHOR_EMAIL = $email
    $env:GIT_COMMITTER_NAME = $name; $env:GIT_COMMITTER_EMAIL = $email
    $env:GIT_AUTHOR_DATE = $w; $env:GIT_COMMITTER_DATE = $w
    try { & $do }
    finally {
        foreach ($v in 'GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL', 'GIT_AUTHOR_DATE', 'GIT_COMMITTER_DATE') {
            Remove-Item "env:$v" -ErrorAction SilentlyContinue
        }
    }
}

# Cut a branch from the trunk, so its ahead/behind counts mean something.
function Branch-From($r, $trunk, $br) { Invoke-Git $r checkout -q $trunk; Invoke-Git $r checkout -q -B $br }

# commit <repo> <branch> <author-name> <author-email> <days-ago> <subject>
function Commit($r, $br, $an, $ae, [int]$ago, $subj) {
    Invoke-Git $r checkout -q -B $br
    Add-Content -Path (Join-Path $r 'CHANGELOG.md') -Value $subj -Encoding utf8
    Invoke-Git $r add -A
    With-Author $an $ae $ago { Invoke-Git $r commit -q -m $subj }
}

# Land a branch on the trunk without a pull request ever recording it.
function Merge-Back($r, $trunk, $br, $an, $ae, [int]$ago) {
    Invoke-Git $r checkout -q $trunk
    With-Author $an $ae $ago { Invoke-Git $r merge -q --no-ff -m "merge: $br" $br }
}

function New-Repo($name, $default) {
    $r = Join-Path $Dir "repos\$name"
    New-Item -ItemType Directory -Force $r | Out-Null
    Invoke-Git $r init -q -b $default
    Invoke-Git $r config user.name 'Dana Okonkwo'; Invoke-Git $r config user.email $Me
    Invoke-Git $r config core.autocrlf false
    Set-Content -Path (Join-Path $r 'README.md') -Value "# $name" -Encoding utf8
    Commit $r $default 'Dana Okonkwo' $Me 20 'chore: initial commit'
    $r
}

"==> repos"

# 1. The one that actually runs. A real static server on a real port.
$R1 = New-Repo 'northwind-web' 'main'
New-Item -ItemType Directory -Force (Join-Path $R1 'public') | Out-Null
Set-Content -Path (Join-Path $R1 'public\index.html') -Encoding utf8 -Value @'
<!doctype html><meta charset="utf-8"><title>Northwind</title>
<style>body{font:16px/1.6 "Segoe UI",sans-serif;margin:0;display:grid;place-items:center;
height:100vh;background:#111318;color:#e8eaf0}h1{font-weight:600}</style>
<h1>Northwind &mdash; demo branch</h1>
'@
Commit $R1 main 'Dana Okonkwo' $Me 12 'feat(web): landing page shell'

Branch-From $R1 main 'feat/checkout-summary'
Commit $R1 'feat/checkout-summary' 'Dana Okonkwo' $Me 0 'feat(checkout): show tax and shipping before payment'
Commit $R1 'feat/checkout-summary' 'Dana Okonkwo' $Me 0 'feat(checkout): itemise the tax lines'
Commit $R1 'feat/checkout-summary' 'Dana Okonkwo' $Me 0 'test(checkout): cover the zero-shipping case'
Branch-From $R1 main 'fix/cart-quantity-race'
Commit $R1 'fix/cart-quantity-race' 'Priya Raman' 'priya@example.com' 1 'fix(cart): debounce quantity updates so the last write wins'
Branch-From $R1 main 'feat/saved-addresses'
Commit $R1 'feat/saved-addresses' 'Dana Okonkwo' $Me 2 'feat(account): let customers save more than one address'
Commit $R1 'feat/saved-addresses' 'Dana Okonkwo' $Me 2 'feat(account): default address per customer'
Branch-From $R1 main 'chore/bump-deps'
Commit $R1 'chore/bump-deps' 'Marco Silva' 'marco@example.com' 9 'chore: bump minor dependencies'
# Merged by hand and never opened as a pull request (hidden until Show merged).
Branch-From $R1 main 'chore/tidy-imports'
Commit $R1 'chore/tidy-imports' 'Aisha Bello' 'aisha@example.com' 3 'chore: sort imports'
Merge-Back $R1 main 'chore/tidy-imports' 'Aisha Bello' 'aisha@example.com' 12
# The trunk moves on after the branches are cut, so "behind" means something.
Commit $R1 main 'Aisha Bello' 'aisha@example.com' 12 'fix(build): pin the toolchain'
Commit $R1 main 'Dana Okonkwo' $Me 12 'chore: drop the unused polyfill'
Invoke-Git $R1 checkout -q main

$R2 = New-Repo 'aperture-api' 'main'
Commit $R2 main 'Dana Okonkwo' $Me 14 'feat(api): health and readiness probes'
Branch-From $R2 main 'feat/webhook-retries'
Commit $R2 'feat/webhook-retries' 'Dana Okonkwo' $Me 0 'feat(webhooks): retry with exponential backoff and a dead-letter queue'
Branch-From $R2 main 'fix/timezone-drift'
Commit $R2 'fix/timezone-drift' 'Priya Raman' 'priya@example.com' 3 "fix(reports): compute day boundaries in the tenant's timezone"
Branch-From $R2 main 'perf/batch-inserts'
Commit $R2 'perf/batch-inserts' 'Marco Silva' 'marco@example.com' 5 'perf(ingest): batch inserts, 40k rows/s to 180k'
Invoke-Git $R2 checkout -q main
Commit $R2 main 'Marco Silva' 'marco@example.com' 14 'refactor(api): one error envelope'
Invoke-Git $R2 checkout -q main

$R3 = New-Repo 'lumen-ui' 'main'
Commit $R3 main 'Dana Okonkwo' $Me 16 'docs: component gallery'
Branch-From $R3 main 'feat/date-picker'
Commit $R3 'feat/date-picker' 'Dana Okonkwo' $Me 1 'feat(date-picker): keyboard navigation and range selection'
Commit $R3 'feat/date-picker' 'Dana Okonkwo' $Me 1 'fix(date-picker): clamp the range to the month'
Branch-From $R3 main 'fix/focus-ring-contrast'
Commit $R3 'fix/focus-ring-contrast' 'Aisha Bello' 'aisha@example.com' 4 'fix(a11y): focus ring now passes contrast on tinted surfaces'
Invoke-Git $R3 checkout -q main
Commit $R3 main 'Aisha Bello' 'aisha@example.com' 16 'docs: token reference'
Invoke-Git $R3 checkout -q main

$R4 = New-Repo 'ledger-service' 'main'
Commit $R4 main 'Dana Okonkwo' $Me 18 'feat: double-entry primitives'
Branch-From $R4 main 'feat/reconciliation'
Commit $R4 'feat/reconciliation' 'Marco Silva' 'marco@example.com' 2 'feat(recon): match statement lines against postings'
Invoke-Git $R4 checkout -q main
Commit $R4 main 'Dana Okonkwo' $Me 18 'feat: posting rules'
Invoke-Git $R4 checkout -q main

"==> projects"
$P = Join-Path $Dir 'projects'
$web = $Port; $api = $Port + 1; $svc = $Port + 3
# No BOM: Windows PowerShell's -Encoding utf8 writes one, and a config is
# read as KEY="value" from its first byte.
function Conf($id, $body) { [IO.File]::WriteAllText((Join-Path $P "$id.conf"), ($body -replace "`r`n", "`n") + "`n") }
Conf 'northwind-web' @"
NAME="Northwind Web"
REPO="$R1"
DEFAULT_BRANCH="main"
# A real server, so Start actually works and health actually goes green.
TARGETS="web:${web}:/:python -m http.server $web --directory public"
SYMBOL="cart"
"@
Conf 'aperture-api' @"
NAME="Aperture API"
REPO="$R2"
DEFAULT_BRANCH="main"
TARGETS="api:${api}:/health:python -m http.server $api"
SYMBOL="server.rack"
"@
Conf 'lumen-ui' @"
NAME="Lumen UI"
REPO="$R3"
DEFAULT_BRANCH="main"
# Deliberately the same port as the api above, so the Ports sheet's overlap
# section has something to show.
TARGETS="docs:${api}:/:python -m http.server {port}"
SYMBOL="paintpalette"
"@
Conf 'ledger-service' @"
NAME="Ledger Service"
REPO="$R4"
DEFAULT_BRANCH="main"
TARGETS="svc:${svc}:/:python -m http.server $svc"
SYMBOL="building.columns"
"@

# Pull request data the engine would normally get from gh. Same TSV shape:
#   branch  state  number  title
"==> pull requests"
$S = Join-Path $Dir 'state'
function PRs($id, [string[]]$rows) {
    $d = Join-Path $S $id; New-Item -ItemType Directory -Force $d | Out-Null
    # LF endings and no BOM, as the Mac's heredoc writes them.
    [IO.File]::WriteAllText((Join-Path $d 'prcache'), (($rows -join "`n") + "`n"))
}
$t = "`t"
PRs 'northwind-web' @(
    "feat/checkout-summary${t}OPEN${t}412${t}Show tax and shipping before payment",
    "fix/cart-quantity-race${t}OPEN${t}410${t}Debounce cart quantity updates",
    "feat/saved-addresses${t}OPEN${t}407${t}Multiple saved addresses per customer",
    "chore/bump-deps${t}MERGED${t}399${t}Bump minor dependencies")
PRs 'aperture-api' @(
    "feat/webhook-retries${t}OPEN${t}288${t}Retry webhooks with backoff and a dead-letter queue",
    "fix/timezone-drift${t}OPEN${t}285${t}Compute day boundaries in the tenant timezone",
    "perf/batch-inserts${t}MERGED${t}279${t}Batch ingest inserts")
PRs 'lumen-ui' @(
    "feat/date-picker${t}OPEN${t}96${t}Date picker keyboard navigation and ranges",
    "fix/focus-ring-contrast${t}OPEN${t}94${t}Focus ring contrast on tinted surfaces")
PRs 'ledger-service' @(
    "feat/reconciliation${t}OPEN${t}51${t}Match statement lines against postings")

""
"Demo built in $Dir (northwind-web serves on $web)"
