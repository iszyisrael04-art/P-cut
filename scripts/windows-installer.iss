#define AppName "P-cut"
#define AppVersion "0.2.3"
[Setup]
AppId={{D31D7488-F2FD-4129-B824-B2A3D4C9B027}
AppName={#AppName}
AppVersion={#AppVersion}
DefaultDirName={localappdata}\Programs\P-cut
DefaultGroupName=P-cut
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=P-cut-Setup
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
SetupIconFile=..\assets\branding\pcut.ico
[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
[Icons]
Name: "{group}\P-cut"; Filename: "{app}\P-cut.exe"
Name: "{autodesktop}\P-cut"; Filename: "{app}\P-cut.exe"; Tasks: desktopicon
[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked
[Run]
Filename: "{app}\P-cut.exe"; Description: "Open P-cut"; Flags: nowait postinstall skipifsilent
