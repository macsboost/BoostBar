; BoostBar for Windows installer (Inno Setup 6).
; Per-user install into %LOCALAPPDATA%\Programs\BoostBar: no admin prompt, and updates install silently.
;   ISCC /DVersion=1.3.73 /DBuildDir=..\..\build\win windows\installer\BoostBar.iss

#ifndef Version
  #define Version "0.0.0"
#endif
#ifndef BuildDir
  #define BuildDir "..\..\build\win"
#endif

[Setup]
AppId={{9C1E5B2A-4B7D-4E0B-9F43-6B0B2C1E7A11}
AppName=BoostBar
AppVersion={#Version}
AppVerName=BoostBar {#Version}
AppPublisher=MacsBoost
AppPublisherURL=https://macsboost.com
AppSupportURL=https://github.com/macsboost/BoostBar
AppUpdatesURL=https://github.com/macsboost/BoostBar/releases
AppCopyright=© 2026 MacsBoost / X1 Racing. MIT License.
VersionInfoVersion={#Version}
DefaultDirName={localappdata}\Programs\BoostBar
DisableDirPage=auto
DisableProgramGroupPage=yes
DisableReadyPage=yes
PrivilegesRequired=lowest
OutputDir={#BuildDir}\out
OutputBaseFilename=BoostBar-Setup
SetupIconFile=..\Shared\BoostBar.ico
UninstallDisplayIcon={app}\BoostBar.exe
UninstallDisplayName=BoostBar
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=force
RestartApplications=no
MinVersion=10.0.17763
LicenseFile=..\..\LICENSE

[Tasks]
Name: "startup"; Description: "Start BoostBar when I sign in"
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "{#BuildDir}\app\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "*.pdb"
Source: "{#BuildDir}\saver\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "*.pdb"
Source: "{#BuildDir}\saver\BoostBarSaver.exe"; DestDir: "{app}"; DestName: "BoostBarFlyingCars.scr"; Flags: ignoreversion
Source: "{#BuildDir}\saver\BoostBarSaver.exe"; DestDir: "{app}"; DestName: "BoostBarStarships.scr"; Flags: ignoreversion
Source: "{#BuildDir}\saver\BoostBarSaver.exe"; DestDir: "{app}"; DestName: "BoostBarStarlink.scr"; Flags: ignoreversion
Source: "{#BuildDir}\saver\BoostBarSaver.exe"; DestDir: "{app}"; DestName: "BoostBarJetRacers.scr"; Flags: ignoreversion
Source: "{#BuildDir}\savers\*.html"; DestDir: "{app}\savers"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\BoostBar"; Filename: "{app}\BoostBar.exe"
Name: "{userdesktop}\BoostBar"; Filename: "{app}\BoostBar.exe"; Tasks: desktopicon

[Registry]
; first install only: a silent update keeps whatever the user chose in Settings ▸ General
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "BoostBar"; \
  ValueData: """{app}\BoostBar.exe"" --login"; Tasks: startup; Flags: uninsdeletevalue; Check: not WizardSilent

[Run]
Filename: "{app}\BoostBar.exe"; Description: "Launch BoostBar"; Flags: nowait postinstall skipifsilent
Filename: "{app}\BoostBar.exe"; Flags: nowait; Check: WizardSilent

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/IM BoostBar.exe /F"; Flags: runhidden; RunOnceId: "KillBoostBar"

[UninstallDelete]
Type: filesandordirs; Name: "{localappdata}\BoostBar\WebView2"

[Code]
// Give a running BoostBar (that just launched this updater) a moment to quit, then make sure it's gone.
function InitializeSetup(): Boolean;
var
  i, rc: Integer;
begin
  for i := 0 to 20 do
  begin
    if not CheckForMutexes('Local\MacsBoost.BoostBar') then break;
    Sleep(250);
  end;
  if CheckForMutexes('Local\MacsBoost.BoostBar') then
    Exec(ExpandConstant('{sys}\taskkill.exe'), '/IM BoostBar.exe /F', '', SW_HIDE, ewWaitUntilTerminated, rc);
  Result := True;
end;
