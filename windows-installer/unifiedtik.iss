; Windows installer for UnifiedTik. Built by the GitHub workflow: ISCC /DSrc=<Release folder> /DIcon=<app_icon.ico>
#define AppName "UnifiedTik"
#define AppVersion "1.0.0"

[Setup]
AppId={{6E2B1F0A-5C1D-4C8E-9A57-0D7A1B3C9E21}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=UnifiedTik
AppPublisherURL=https://unifiedtik.com
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputBaseFilename=UnifiedTik-Setup
SetupIconFile={#Icon}
UninstallDisplayIcon={app}\unifiedtik.exe
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern

[Files]
Source: "{#Src}\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\unifiedtik.exe"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\unifiedtik.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Run]
Filename: "{app}\unifiedtik.exe"; Description: "Open {#AppName}"; Flags: nowait postinstall skipifsilent
