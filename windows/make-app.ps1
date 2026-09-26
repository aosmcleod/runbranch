# Runbranch — run any branch of any project on a real port.
# Copyright (C) 2026 Alec McLeod
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. It is distributed WITHOUT ANY WARRANTY; without even the
# implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
# See the GNU General Public License for more details:
# <https://www.gnu.org/licenses/>.

<#
.SYNOPSIS
Builds Runbranch for Windows into dist\windows\Runbranch\: the WinUI app,
self-contained, with the Go engine in bin\ beside it.

.DESCRIPTION
The Windows counterpart of make-app.sh. Builds are development builds unless
you say otherwise, as on the Mac: a development build carries the inverted
mark and says so in About, because the copy you are working on and the one
you use are otherwise identical on the taskbar. Shipping is the deliberate
act, so it is the one that needs a word:

  .\windows\make-app.ps1            a development build
  .\windows\make-app.ps1 -Release   the shipping build, plus
                                    dist\windows\Runbranch-<version>-windows-x64.zip,
                                    the asset the updater looks for (spec F10)

The version comes from make-app.sh, where docs/VERSIONING.md says it lives,
so the zip's name, About and the Mac cannot disagree.

Needs the .NET 10 SDK. Go builds the engine; without it (or while the engine
does not compile) a development build still produces the app, with no engine,
and says so. A release refuses: an app with nothing to run is not a release.
#>

param(
    [switch]$Release
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$channel = if ($Release) { 'release' } else { 'development' }
$dist = Join-Path $repo 'dist\windows'
$out = Join-Path $dist 'Runbranch'
$project = Join-Path $PSScriptRoot 'Runbranch\Runbranch.csproj'

function Find-Tool([string]$name, [string]$fallback) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    if ($fallback -and (Test-Path $fallback)) { return $fallback }
    return $null
}

# --- version ---------------------------------------------------------------
$makeApp = Get-Content -Raw (Join-Path $repo 'make-app.sh')
$m = [regex]::Match($makeApp, 'CFBundleShortVersionString</key>\s*<string>([^<]+)</string>')
if (-not $m.Success) { throw "could not read the version from make-app.sh" }
$version = $m.Groups[1].Value
Write-Host "==> building $out ($channel, $version)"

$dotnet = Find-Tool 'dotnet' 'C:\Program Files\dotnet\dotnet.exe'
if (-not $dotnet) { throw "dotnet is not on PATH. Install the .NET 10 SDK: winget install Microsoft.DotNet.SDK.10" }
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'

# A clean folder each time, as make-app.sh rebuilds the bundle from nothing:
# a file left over from an older build would ship in the zip.
if (Test-Path $out) { Remove-Item -Recurse -Force $out }
New-Item -ItemType Directory -Force $out | Out-Null

# --- app -------------------------------------------------------------------
# Release configuration for both channels: a development build is still the
# app you run every day, and it should be as fast as the one you ship. The
# channel is what differs, not the optimiser.
& $dotnet publish $project -c Release -r win-x64 --self-contained true `
    "-p:Version=$version" "-p:RBBuildChannel=$channel" -o $out -nologo -v quiet
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }
Write-Host "    app built"

# --- release notes ---------------------------------------------------------
# The changelog, as data, for "What's new" — bundled rather than fetched, so
# it works offline and for a build from source. CHANGELOG.md stays the only
# copy anyone edits. Same shape as make-app.sh writes for the Mac.
$entries = @()
$current = $null
$body = New-Object System.Collections.Generic.List[string]
# UTF-8 said out loud: Windows PowerShell reads a file with no BOM as the ANSI
# code page, and every em dash in the changelog would arrive as three letters.
foreach ($line in Get-Content -Encoding UTF8 (Join-Path $repo 'CHANGELOG.md')) {
    $h = [regex]::Match($line.TrimEnd(), '^##\s+v?(\d+(?:\.\d+)*)\s*$')
    if ($h.Success) {
        if ($current) { $entries += [ordered]@{ version = $current; notes = ($body -join "`n").Trim() } }
        $current = $h.Groups[1].Value
        $body.Clear()
        continue
    }
    if ($current) { $body.Add($line.TrimEnd()) }
}
if ($current) { $entries += [ordered]@{ version = $current; notes = ($body -join "`n").Trim() } }
$json = ConvertTo-Json -InputObject $entries -Depth 3
[System.IO.File]::WriteAllText((Join-Path $out 'ReleaseNotes.json'), $json, (New-Object System.Text.UTF8Encoding $false))
Write-Host "    release notes: $($entries.Count) versions"

# --- engine ----------------------------------------------------------------
# In bin\, not beside Runbranch.exe: runbranch.exe and Runbranch.exe are the
# same file name on Windows (see Engine.EnginePath). bin\ can go on PATH, so
# the engine is also the `runbranch` command in a terminal. It is also what
# swaps the next update in (`runbranch install-update`, spec F17), so there is
# no separate update helper to bundle any more.
$go = Find-Tool 'go' 'C:\Program Files\Go\bin\go.exe'
$engineOut = Join-Path $out 'bin\runbranch.exe'
$engineBuilt = $false
if ($go) {
    New-Item -ItemType Directory -Force (Split-Path $engineOut) | Out-Null
    Push-Location (Join-Path $repo 'engine')
    $saved = @{ CGO_ENABLED = $env:CGO_ENABLED; GOOS = $env:GOOS; GOARCH = $env:GOARCH }
    try {
        # CGO off, so it needs no C toolchain and links nothing but the system.
        $env:CGO_ENABLED = '0'; $env:GOOS = 'windows'; $env:GOARCH = 'amd64'
        & $go build -trimpath -ldflags "-s -w -X main.version=$version" -o $engineOut ./cmd/runbranch
        $engineBuilt = ($LASTEXITCODE -eq 0) -and (Test-Path $engineOut)
    }
    finally {
        Pop-Location
        foreach ($k in $saved.Keys) { Set-Item "Env:$k" -Value $saved[$k] -ErrorAction SilentlyContinue; if (-not $saved[$k]) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue } }
    }
    if ($engineBuilt) { Write-Host "    engine built ($version, windows/amd64)" }
    else { Write-Warning "the engine in engine\ did not build; see the go output above" }
}
else {
    Write-Warning "go is not on PATH, so there is no engine. Install Go: winget install GoLang.Go"
}
if (-not $engineBuilt) {
    if ($Release) { throw "a release needs the engine; not packaging an app with nothing to run" }
    Write-Warning "built the app without an engine. It opens, and says so; set RB_ENGINE to point it at one"
}

# --- package ---------------------------------------------------------------
if ($Release) {
    # The folder itself at the top of the zip, so extracting it anywhere gives
    # a Runbranch\ folder rather than a spray of DLLs, and the updater's swap
    # replaces one folder with one folder.
    $zip = Join-Path $dist "Runbranch-$version-windows-x64.zip"
    if (Test-Path $zip) { Remove-Item -Force $zip }
    # Entry by entry, naming each with forward slashes. Compress-Archive and
    # ZipFile.CreateFromDirectory both write backslashes under Windows
    # PowerShell 5.1, and other unzippers then make files with backslashes in
    # their names instead of folders.
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::Open($zip, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        $root = (Resolve-Path $out).Path.TrimEnd('\') + '\'
        foreach ($file in Get-ChildItem -Recurse -File $out) {
            $name = 'Runbranch/' + $file.FullName.Substring($root.Length).Replace('\', '/')
            [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $archive, $file.FullName, $name, [System.IO.Compression.CompressionLevel]::Optimal)
        }
    }
    finally { $archive.Dispose() }
    $hash = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant()
    Write-Host "    packaged $zip"
    Write-Host "    sha256 $hash"
}

Write-Host "    done"
Write-Host ""
Write-Host "Run it:"
Write-Host "  $(Join-Path $out 'Runbranch.exe')"
