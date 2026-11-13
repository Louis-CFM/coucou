# Coucou Windows — Development & Build Guide

This guide provides instructions on how to run Coucou locally in the browser, run it as a live desktop application in development mode, and package it into a production Windows executable (`.exe`) and native setup installer.

---

## 📋 Table of Contents
1. [Prerequisites & System Setup](#1-prerequisites--system-setup)
2. [Running in the Browser (Fast Frontend Dev)](#2-running-in-the-browser-fast-frontend-dev)
3. [Running as Desktop App in Dev Mode (Tauri Shell)](#3-running-as-desktop-app-in-dev-mode-tauri-shell)
4. [Converting & Packaging into a Windows App (.exe / .msi)](#4-converting--packaging-into-a-windows-app-exe--msi)
5. [Installation & First Run on Your PC](#5-installation--first-run-on-your-pc)
6. [Troubleshooting & Pro Tips](#6-troubleshooting--pro-tips)
7. [Commands Cheatsheet](#7-commands-cheatsheet)

---

## 1. Prerequisites & System Setup

Ensure you have the following installed on your Windows PC:

| Requirement | Recommended Version | Verification Command | Notes |
| :--- | :--- | :--- | :--- |
| **Node.js** | v20.x or v22.x+ | `node -v` | JavaScript runtime |
| **pnpm** | v9.x or v10.x | `pnpm -v` | Fast package manager (`corepack enable pnpm`) |
| **Rust & Cargo** | Stable (1.80+) | `cargo --version` | Install via [rustup.rs](https://rustup.rs) (x86_64-pc-windows-msvc) |
| **Visual Studio Build Tools** | 2022 | Visual Studio Installer | Workload: **Desktop development with C++** |
| **WebView2 Runtime** | Evergreen | Pre-installed | Bundled by default on Windows 10 & 11 |

### Install Dependencies
Before running or building, install the Node dependencies:
```powershell
# From the project root
pnpm --prefix windows install

# Or navigate directly into windows/
cd windows
pnpm install
```

---

## 2. Running in the Browser (Fast Frontend Dev)

Running Coucou in the browser is the fastest way to tweak and inspect UI components (Liquid Glass styling, Framer Motion spring animations, Inter typography, and custom dropdowns) with **instant Hot Module Replacement (HMR)** without compiling Rust every time.

### 🚀 Quick Command: Test Only in the Browser

To immediately launch and test the Coucou Settings UI in your default web browser without any Rust or desktop overhead:

```powershell
# From the project root:
pnpm --prefix windows run test:browser

# Or if you are inside the windows/ folder:
pnpm run test:browser
```

> **What this command does**:
> - Starts the Vite development server in pure frontend mode.
> - Automatically launches your default web browser pointing directly to [`http://127.0.0.1:1420/settings.html`](http://127.0.0.1:1420/settings.html).
> - Zero Rust, zero Cargo compilation, and zero C++ dependencies required.
> - Supports full hot reload: any change you save in CSS or TypeScript updates live in your browser in milliseconds.

### Other Browser Dev Options

```powershell
# Start Vite dev server without opening browser automatically:
pnpm --prefix windows run dev

# Start Vite and open the default root view (Island Notch):
pnpm --prefix windows run dev:browser
```

### Accessing App Pages in the Browser
Once Vite starts, it listens at **`http://127.0.0.1:1420/`**. Open any of the following URLs in your browser:

| View | Browser URL | Description |
| :--- | :--- | :--- |
| **Settings Hub** | [`http://127.0.0.1:1420/settings.html`](http://127.0.0.1:1420/settings.html) | Full Settings window with sidebar navigation, Liquid Glass cards, spring physics, and dropdowns |
| **Island Notch** | [`http://127.0.0.1:1420/index.html`](http://127.0.0.1:1420/index.html) | The Dynamic Island notch and Mochi character interface |
| **Mochi Canvas** | [`http://127.0.0.1:1420/mochi.html`](http://127.0.0.1:1420/mochi.html) | Standalone mascot animations and outfit canvas |
| **Pill View** | [`http://127.0.0.1:1420/pill.html`](http://127.0.0.1:1420/pill.html) | Floating pill widget |

> **Note**: In pure browser mode, backend native OS calls (e.g. Windows Credential Manager, audio loopback, raw clipboard hooks) run in mock/fallback mode so you can design and preview without native crashes.

---

## 3. Running as Desktop App in Dev Mode (Tauri Shell)

To test the actual native desktop application with live hooks, system tray, transparency, floating window, and keyboard shortcuts:

```powershell
cd windows
pnpm tauri dev
```

### What Happens:
1. Starts the Vite dev server on `127.0.0.1:1420`.
2. Compiles the Rust backend in debug mode.
3. Spawns the transparent, borderless Dynamic Island notch pinned to the top of your screen.
4. Auto-reloads UI when you save TypeScript or CSS files.

To stop the dev app, press `Ctrl + C` in your terminal or right-click the system tray icon and choose **Quit**.

---

## 4. Converting & Packaging into a Windows App (.exe / .msi)

When you are ready to package the entire project into production executables and installers, follow these steps:

### Option A: Complete One-Step Automated Packaging *(Recommended)*

Run the complete build & pack script:
```powershell
# From project root
pnpm --prefix windows run pack
```
*Or from the `windows/` folder:*
```powershell
cd windows
pnpm run pack
```

---

### Option B: Step-by-Step Manual Build Pipeline

If you prefer executing each phase manually or need to inspect intermediate outputs:

#### Step 1: Pre-build the Claude Code Hook Relay
Coucou bundles `coucou-hook.exe` (which relays Claude Code / agent events to Coucou) as an embedded resource:
```powershell
cargo build --release --manifest-path windows/hook/Cargo.toml
```

#### Step 2: Build the Production Frontend
Typechecks with `tsc` and bundles minified HTML, CSS, fonts, and Motion scripts:
```powershell
pnpm --prefix windows run build
```

#### Step 3: Compile Rust & Package Installers
Invokes Tauri with release profile optimizations (`opt-level = "s"`, Link-Time Optimization `lto = true`, and symbol stripping `strip = true`):
```powershell
cd windows
pnpm tauri build
```

#### Step 4: Stage Shipping Packages
Extracts and standardizes installer names into the `windows/release/` directory:
```powershell
node windows/scripts/pack.mjs
```

---

### 📦 Where to Find the Output Files

All packaged files are staged in **`windows/release/`**:

| Output File | Format | Purpose |
| :--- | :--- | :--- |
| **`Coucou-Windows-0.5.9-setup.exe`** | NSIS Setup | **Recommended Installer**. Installs to `%LOCALAPPDATA%\Coucou`, creates Start Menu shortcut, desktop icon, and registered uninstaller. |
| **`Coucou-Windows-0.5.9.msi`** | MSI Package | Native Windows Installer for enterprise and standard deployment. |
| **`coucou.exe`** *(in `windows/target/release/`)* | Portable `.exe` | Standalone binary. Runs directly with zero installation required. |

---

## 5. Installation & First Run on Your PC

### 1. Clean previous running instances:
If Coucou is currently running on your PC, quit it first so Windows doesn't lock the executable:
- Right-click **Coucou (Mochi)** in your System Tray $\rightarrow$ Click **Quit**, or run:
```powershell
Stop-Process -Name "coucou" -ErrorAction SilentlyContinue
```

### 2. Run the Installer:
1. Open File Explorer to:
   ```text
   windows\release\
   ```
2. Double-click **`Coucou-Windows-0.5.9-setup.exe`**.
3. **If Windows Defender SmartScreen appears**:
   > Because this binary is compiled locally without an expensive commercial EV certificate, SmartScreen may say *"Windows protected your PC"*.
   - Click **More info**.
   - Click **Run anyway**.
4. The installer sets up Coucou and launches it automatically.

---

## 6. Troubleshooting & Pro Tips

### Issue 1: "Command failed with exit code 4294967295" or Dev Crashes
- **Cause**: Port `1420` is already in use by another instance or a previous background process is still active.
- **Fix**: Kill existing processes occupying port 1420:
  ```powershell
  # Find PID on 1420
  netstat -ano | findstr :1420
  # Kill process (replace <PID>)
  taskkill /F /PID <PID>
  ```

### Issue 2: "io: invalid peer certificate: UnknownIssuer" during packaging
- **Cause**: Tauri attempts to download the NSIS packager binary from GitHub inside an isolated sandbox without network certificates.
- **Fix**: Run `pnpm run pack` in an unrestricted shell with standard internet access so Tauri can download the NSIS runtime once.

### Issue 3: "File in use / Access is denied" during compilation
- **Cause**: `coucou.exe` is currently running and Windows locked the file on disk.
- **Fix**: Terminate running instances before compiling:
  ```powershell
  Stop-Process -Name "coucou*" -Force -ErrorAction SilentlyContinue
  ```

### Issue 4: Cleaning Stale Build Cache
If you want to perform a 100% clean rebuild from scratch:
```powershell
# Remove old releases and bundles
Remove-Item -Path "windows/release/*", "windows/target/release/bundle/*" -Recurse -Force -ErrorAction SilentlyContinue

# Clean Rust target cache (optional, if you need full re-compile)
cd windows
cargo clean
```

---

## 7. Commands Cheatsheet

| Task | Command (from root) | Command (in `windows/`) | Description |
| :--- | :--- | :--- | :--- |
| **Test in Browser Only** | `pnpm --prefix windows run test:browser` | `pnpm run test:browser` | **Starts Vite & opens Settings UI directly in your browser** |
| **Start Browser Dev Server** | `pnpm --prefix windows run dev` | `pnpm run dev` | Starts Vite on `http://127.0.0.1:1420/` |
| **Open Dev Root in Browser** | `pnpm --prefix windows run dev:browser` | `pnpm run dev:browser` | Starts Vite & opens Island Notch |
| **Install Packages** | `pnpm --prefix windows install` | `pnpm install` | Installs frontend dependencies |
| **Run Native App in Dev Mode** | — | `pnpm tauri dev` | Starts desktop app with live Rust backend |
| **Verify Frontend Build** | `pnpm --prefix windows run build` | `pnpm run build` | Typechecks (`tsc`) & builds production JS/CSS |
| **Verify Rust Code** | — | `cargo check` (in `src-tauri/`) | Checks Rust backend without building |
| **Package Windows App (.exe / .msi)** | `pnpm --prefix windows run pack` | `pnpm run pack` | Compiles & creates release installers |
| **Kill Running Coucou Instances** | `Stop-Process -Name "coucou*" -Force` | `Stop-Process -Name "coucou*" -Force` | Frees port 1420 & executable locks |

---

*Maintained by Madhan Kumar — Built with TypeScript, Vite, Tailwind-free custom CSS, Framer Motion, Rust, and Tauri v2.*
