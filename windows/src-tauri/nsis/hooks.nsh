; Uninstall hooks for the NSIS installer.
;
; The app stages alfred-hook.exe into %LOCALAPPDATA%\Alfred\bin at launch, so the
; installer never recorded it and the default uninstaller leaves it behind. The
; inbox and the log live in the same place and are ours too.
;
; Claude Code's own settings.json is deliberately NOT touched here: it belongs to
; the user, it may contain hooks from other tools, and rewriting somebody's
; config from an uninstaller with no diff and no consent is exactly what the rest
; of this app goes out of its way not to do. A relay that is gone exits 0 without
; printing anything, so a leftover entry costs nothing beyond a dead path.

!macro NSIS_HOOK_PREUNINSTALL
  RMDir /r "$LOCALAPPDATA\Alfred\bin"
  RMDir /r "$LOCALAPPDATA\Alfred\inbox"
  Delete "$LOCALAPPDATA\Alfred\alfred.log"
!macroend
