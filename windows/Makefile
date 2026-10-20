.PHONY: release

# Release build of Coucou for Windows; leaves Coucou.exe on the Windows desktop.
# Run from WSL (or any shell where make and powershell.exe exist).
release:
	powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$$(wslpath -w scripts/release-windows.ps1)"
