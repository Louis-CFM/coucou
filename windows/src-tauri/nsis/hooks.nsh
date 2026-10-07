; Uninstall hooks for the NSIS installer.
;
; The app stages coucou-hook.exe into %LOCALAPPDATA%\Coucou\bin at launch, so the
; installer never recorded it and the default uninstaller leaves it behind. The
; inbox and the log live in the same place and are ours too.
;
; The user's Claude, Kimi, Codex and Hermes hook configs are deliberately NOT
; touched here: removing entries without a preview and consent could disturb
; unrelated hooks. An orphaned Coucou entry invokes a missing relay until the
; user removes it from Coucou Settings before uninstalling or cleans it manually.

!macro NSIS_HOOK_PREUNINSTALL
  RMDir /r "$LOCALAPPDATA\Coucou\bin"
  RMDir /r "$LOCALAPPDATA\Coucou\inbox"
  Delete "$LOCALAPPDATA\Coucou\coucou.log"
!macroend
