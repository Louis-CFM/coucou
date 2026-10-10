; Uninstall hooks for the NSIS installer.
;
; The app stages coucou-hook.exe into %LOCALAPPDATA%\Coucou\bin at launch, so the
; installer never recorded it and the default uninstaller leaves it behind. The
; inbox and the log live in the same place and are ours too.
;
; Clean up agent hooks (Antigravity, Claude Code, Cursor, Codex, etc.) before
; removing binaries, so agents are not left with broken hooks pointing to a
; deleted coucou-hook.exe relay (e.g. Antigravity fails closed on broken pre-tool hooks).
;
; The app stages coucou-hook.exe into %LOCALAPPDATA%\Coucou\bin at launch, so the
; installer never recorded it and the default uninstaller leaves it behind. The
; inbox and the log live in the same place and are ours too.

!macro NSIS_HOOK_PREUNINSTALL
  IfFileExists "$INSTDIR\Coucou.exe" 0 +2
    ExecWait '"$INSTDIR\Coucou.exe" --uninstall-hooks'
  RMDir /r "$LOCALAPPDATA\Coucou\bin"
  RMDir /r "$LOCALAPPDATA\Coucou\inbox"
  Delete "$LOCALAPPDATA\Coucou\coucou.log"
!macroend

