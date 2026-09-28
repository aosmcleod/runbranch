; Runbranch — run any branch of any project on a real port.
; Copyright (C) 2026 Alec McLeod
;
; This program is free software: you can redistribute it and/or modify it
; under the terms of the GNU General Public License as published by the Free
; Software Foundation, either version 3 of the License, or (at your option)
; any later version. It is distributed WITHOUT ANY WARRANTY; without even the
; implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
; See the GNU General Public License for more details:
; <https://www.gnu.org/licenses/>.
;
; The Windows installer (spec F16): one setup.exe that puts the app in
; %LOCALAPPDATA%\Programs\Runbranch, adds it to Start and to Settings > Apps,
; and never asks for an administrator (F17). Built by make-app.ps1 -Release
; from the folder it has just published; not meant to be compiled by hand:
;
;   ISCC.exe /DAppVersion=1.6.0 /DSourceDir=...\dist\windows\Runbranch
;            /DOutputDir=...\dist\windows windows\installer\Runbranch.iss

#ifndef AppVersion
  #error AppVersion is required; build with windows\make-app.ps1 -Release
#endif
#ifndef SourceDir
  #error SourceDir is required; build with windows\make-app.ps1 -Release
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif

[Setup]
; Fixed forever: it is how a later setup.exe finds this install to upgrade,
; and how the app finds its entry in Settings > Apps (Updates.cs,
; InstalledEntry). Inno names the registry key "Runbranch_is1".
AppId=Runbranch
AppName=Runbranch
AppVersion={#AppVersion}
AppVerName=Runbranch {#AppVersion}
AppPublisher=Alec McLeod
AppPublisherURL=https://github.com/aosmcleod/runbranch
AppSupportURL=https://github.com/aosmcleod/runbranch/issues
AppUpdatesURL=https://github.com/aosmcleod/runbranch/releases

; Per user, no elevation. {autopf} is %LOCALAPPDATA%\Programs for a per-user
; install, where VS Code's and Cursor's user installers go too. Not
; %LOCALAPPDATA%\Runbranch: that is the app's settings and logs.
PrivilegesRequired=lowest
DefaultDirName={autopf}\Runbranch
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.22000

; The uninstaller lives outside the app folder. The in-app updater replaces
; that folder whole (runbranch install-update), and an uninstaller inside it
; would go with the first update.
UninstallFilesDir={localappdata}\Runbranch\Uninstall
UninstallDisplayName=Runbranch
UninstallDisplayIcon={app}\Runbranch.exe

; As few pages as there are decisions, which is none: no folder, no Start
; group, no "ready to install". Run it, and the next page is "Launch".
DisableWelcomePage=yes
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
WizardStyle=modern
SetupIconFile=..\Runbranch\Assets\Runbranch.ico

; A running Runbranch holds its own files; close it, rather than failing
; halfway or asking for a restart. The engine's dev servers are separate
; processes that hold nothing in here, and keep running.
CloseApplications=force
RestartApplications=no

OutputDir={#OutputDir}
OutputBaseFilename=Runbranch-{#AppVersion}-windows-x64-setup
Compression=lzma2/max
SolidCompression=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

; Anything an update brought that this setup did not install: the uninstall
; log only knows the files of the version first installed.
[InstallDelete]
Type: filesandordirs; Name: "{app}\*"

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Icons]
Name: "{autoprograms}\Runbranch"; Filename: "{app}\Runbranch.exe"

[Run]
Filename: "{app}\Runbranch.exe"; Description: "Launch Runbranch"; Flags: nowait postinstall skipifsilent
