; Clean up agent hooks before removing Coucou or its staged relay.
; If cleanup fails, keep the binaries so configured hooks can still run.

!macro NSIS_HOOK_PREUNINSTALL
  Push $0
  ClearErrors
  IfFileExists "$INSTDIR\Coucou.exe" 0 coucou_cleanup_failed
  ExecWait '"$INSTDIR\Coucou.exe" --uninstall-hooks' $0
  IfErrors coucou_cleanup_failed
  StrCmp $0 "0" coucou_cleanup_done

coucou_cleanup_failed:
  Pop $0
  SetErrorLevel 2
  MessageBox MB_OK|MB_ICONSTOP "Coucou could not remove its agent hooks. Uninstallation has stopped to keep the app and hook relay available. Reinstall Coucou or remove its hooks in Settings, then try again." /SD IDOK
  Abort

coucou_cleanup_done:
  Pop $0
  RMDir /r "$LOCALAPPDATA\Coucou\bin"
  RMDir /r "$LOCALAPPDATA\Coucou\inbox"
  Delete "$LOCALAPPDATA\Coucou\coucou.log"
!macroend
