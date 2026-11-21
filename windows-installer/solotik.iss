; Windows installer for Solotik. Built by the GitHub workflow: ISCC /DSrc=<Release folder> /DIcon=<app_icon.ico>
#define AppName "Solotik"
#define AppVersion "1.0.0"

[Setup]
AppId={{6E2B1F0A-5C1D-4C8E-9A57-0D7A1B3C9E21}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=Solotik
AppPublisherURL=https://unifiedtik.com
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputBaseFilename=Solotik-Setup
SetupIconFile={#Icon}
UninstallDisplayIcon={app}\solotik.exe
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern

[InstallDelete]
; the app was called UnifiedTik before
Type: files; Name: "{app}\unifiedtik.exe"

[Files]
Source: "{#Src}\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\solotik.exe"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\solotik.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Run]
Filename: "{app}\solotik.exe"; Description: "Open {#AppName}"; Flags: nowait postinstall skipifsilent
