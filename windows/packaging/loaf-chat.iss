; Loaf Chat's Windows installer. Setup only puts the first build in place
; and registers the uninstaller: every later build arrives through the app's
; own updater (lib/update/windows_updater.dart), which swaps files in this
; same folder. So the install is per user and needs no admin, ever, and
; the folder is one the updater can always write.
;
; Built by tool/release/windows.sh:
;   iscc /DAppVersion=<version> /DBuild=<build> /DBundle=<bundle dir>
;        /DOutDir=<out dir> windows/packaging/loaf-chat.iss

#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef Build
  #error Build is required
#endif
#ifndef Bundle
  #error Bundle is required
#endif
#ifndef OutDir
  #error OutDir is required
#endif

[Setup]
; Never changes: Windows knows an install, and its uninstaller, by this.
AppId={{77BADDA9-8841-438E-BC7C-A15BD9E894D4}
AppName=Loaf Chat
AppVersion={#AppVersion}
AppVerName=Loaf Chat {#AppVersion}
AppPublisher=moe.loaf
AppPublisherURL=https://get.loaf.moe
AppSupportURL=https://matrix.to/#/#feedback:loaf.moe
VersionInfoVersion={#AppVersion}.{#Build}
PrivilegesRequired=lowest
DefaultDirName={localappdata}\Programs\Loaf Chat
; Anywhere else might not be writable later, and then no update could land.
DisableDirPage=yes
DisableProgramGroupPage=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputDir={#OutDir}
OutputBaseFilename=Loaf-Chat-{#AppVersion}-Setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\loaf-chat.exe
UninstallDisplayName=Loaf Chat
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
; Installing over a running copy closes it first, then opens the new one.
CloseApplications=yes
RestartApplications=no

[Files]
Source: "{#Bundle}\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
; The id main.cpp gives the process, so a pinned button and the window are
; one taskbar button.
Name: "{userprograms}\Loaf Chat"; Filename: "{app}\loaf-chat.exe"; AppUserModelID: "moe.loaf.chat"

[Run]
Filename: "{app}\loaf-chat.exe"; Description: "Open Loaf Chat"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Updates add files Setup never logged, and leave .old ones behind: the
; whole folder goes, not just what Setup put there. Messages and keys live
; in AppData, not here, and stay.
Type: filesandordirs; Name: "{app}"
