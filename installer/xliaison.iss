#define MyAppName "xLiaison"
#define MyAppVersion "0.2.0"
#define MyAppPublisher "xLiaison"

[Setup]
AppId={{8A74D23A-939E-4C58-9872-B1E798B22AF8}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
WizardStyle=modern
PrivilegesRequired=admin
CreateAppDir=no
Uninstallable=no
CreateUninstallRegKey=no
DisableProgramGroupPage=yes
DisableDirPage=yes
OutputDir=..\dist
OutputBaseFilename=xLiaison-Setup-Windows
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UsePreviousSetupType=no
UsePreviousTasks=no
SetupLogging=yes

[Types]
Name: "client"; Description: "クライアント版"
Name: "server"; Description: "サーバー版"
Name: "both"; Description: "サーバー版とクライアント版の両方"

[Components]
Name: "client"; Description: "xLiaison Client"; Types: client both; Flags: fixed
Name: "server"; Description: "xLiaison Server"; Types: server both; Flags: fixed

[Files]
Source: "..\dist\xliaison-windows\*"; DestDir: "{tmp}\xliaison"; Flags: ignoreversion recursesubdirs createallsubdirs

[Code]
function SelectedRole: String;
begin
  if WizardIsComponentSelected('server') and WizardIsComponentSelected('client') then
    Result := 'Both'
  else if WizardIsComponentSelected('server') then
    Result := 'Server'
  else
    Result := 'Client';
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
  PowerShellPath: String;
  SetupScript: String;
  Parameters: String;
begin
  if CurStep <> ssPostInstall then
    exit;

  WizardForm.StatusLabel.Caption := 'xLiaisonを自動セットアップしています...';
  PowerShellPath := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
  SetupScript := ExpandConstant('{tmp}\xliaison\scripts\install-xliaison.ps1');
  Parameters :=
    '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' +
    SetupScript + '" -Role ' + SelectedRole + ' -NonInteractive';

  if not Exec(
    PowerShellPath,
    Parameters,
    ExpandConstant('{tmp}\xliaison'),
    SW_SHOWNORMAL,
    ewWaitUntilTerminated,
    ResultCode
  ) then
    RaiseException('xLiaisonセットアップを開始できませんでした。');

  if ResultCode <> 0 then
    RaiseException(
      'xLiaisonセットアップに失敗しました。終了コード: ' +
      IntToStr(ResultCode) +
      '。%TEMP%\xLiaisonSetup.logを確認してください。'
    );
end;
