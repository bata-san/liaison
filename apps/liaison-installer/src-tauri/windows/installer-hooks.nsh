!macro NSIS_HOOK_PREUNINSTALL
  IfFileExists "$INSTDIR\payload\scripts\uninstall-liaison.ps1" 0 liaison_cleanup_done

  MessageBox MB_YESNO|MB_ICONQUESTION "Liaisonが追加した設定、データ、Ubuntu、Docker、Tailscaleなども一括で削除しますか？ ［はい］完全削除 / ［いいえ］Liaison本体のみ削除" IDYES liaison_full_cleanup IDNO liaison_basic_cleanup

liaison_full_cleanup:
  MessageBox MB_YESNO|MB_ICONEXCLAMATION "WSLと仮想マシン プラットフォームのWindows機能も無効化しますか？ 他のアプリがWSLを使用している場合は［いいえ］を選んでください。" IDYES liaison_full_cleanup_features IDNO liaison_full_cleanup_keep_features

liaison_full_cleanup_features:
  nsExec::ExecToLog '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\payload\scripts\uninstall-liaison.ps1" -RemoveData -RemoveDependencies -DisableWindowsFeatures'
  Pop $0
  Goto liaison_cleanup_done

liaison_full_cleanup_keep_features:
  nsExec::ExecToLog '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\payload\scripts\uninstall-liaison.ps1" -RemoveData -RemoveDependencies'
  Pop $0
  Goto liaison_cleanup_done

liaison_basic_cleanup:
  nsExec::ExecToLog '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\payload\scripts\uninstall-liaison.ps1"'
  Pop $0

liaison_cleanup_done:
!macroend
