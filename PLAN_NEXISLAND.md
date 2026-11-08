# NexIsland — Project Architecture & Transformation Master Plan
> **Fork of:** [Louis-CFM/coucou](https://github.com/Louis-CFM/coucou)  
> **Original Creator & Architect:** Louis-CFM (Louis Raillé)  
> **Reimagined & Modified By:** NexSz  
> **Target Name:** NexIsland  
> **New Mascot:** Splash / Nexi (Glossy 3D Blue Dolphin)  
> **Date:** November 2026  

---

## 1. Executive Summary & Vision

**NexIsland** is an evolution of Coucou, transforming the AI agent companion that lives in the MacBook notch, Windows/Linux dynamic island bar, and mobile devices (iOS / Android) into an aquatic, oceanic desktop ecosystem. 

Where the original Coucou featured **Mochi** (a round marshmallow-rice-cake character), **NexIsland** introduces **Splash** (also known as **Nexi**) — a glossy, sky-blue 3D dolphin inspired by high-end vinyl art toys that playfully surfaces, dives, leaps, and monitors AI coding agents (Claude Code, Codex, Cursor, Gemini CLI, Antigravity, and custom LLM hooks).

```
   ┌────────────────────────────────────────────────────────┐
   │                   MacBook Notch / Island               │
   │      ~~~~~ ( 🐬 Splash breaching surface ) ~~~~~       │
   │   [ Claude Code: Running tests... ] [ Approve ]        │
   └────────────────────────────────────────────────────────┘
```

### Core Value Proposition
- **Seamless Continuity:** Retain all core engineering strengths of Coucou (0% CPU when dormant, Swift 6 native concurrency, Keychain security, local IPC hooks, Cloudflare push relay).
- **Aquatic Mascot & Identity:** Full transition from a static marshmallow blob to an expressive hydrodynamic dolphin with swimming, diving, tail-flapping, and water-particle physics.
- **Fresh High-Fidelity Audio:** 29 all-new sound effects recorded and synthesized with hydro-acoustic, bubble, chime, and ocean droplet sound design.
- **Universal Multi-Platform Support:** Synchronized updates across macOS (`NotchBuddy`), Windows & Linux (`Tauri v2`), Android (`Jetpack Compose`), and iOS (`CoucouPhone` -> `NexIslandPhone` + Live Activity).
- **Transparent Attribution:** Complete preservation of original authorship by `Louis-CFM` with clear addition of `NexSz` as the modifier and creator of the NexIsland fork.

---

## 2. Mascot & 3D Visual Identity: Splash (The Dolphin)

### 2.1 Reference Image Analysis
*Reference Asset:* `https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcSegXaF15XhSYK-htDsrE8NneRq9nyRx1rZW6s9vgVrmQ&s`

| Characteristic | Specification | Implementation Value |
|---|---|---|
| **Form Factor** | Smooth, rounded, aerodynamic 3D vinyl dolphin | Custom 4-quadrant cubic Bézier spline with variable thickness |
| **Primary Color** | Pastel sky-blue / azure gradient | `#8BC8F2` (top highlight) to `#5CA8E6` (mid-body) |
| **Secondary Color** | Contrasting clean pearl-white underbelly & jaw | `#FFFFFF` with soft `#E0EFFC` ambient occlusion |
| **Accent Color** | Deep ocean cobalt for fins & tail | `#3A86D4` (dorsal fin, pectoral flippers, tail flukes) |
| **Finish / Shading**| High-gloss vinyl sheen with specular glare | Multi-stop radial gradients simulating studio rim lighting |
| **Eyes** | Glossy black ovals with dual white specular reflections | Dual highlight dots (primary 40% top-right, secondary 15% bottom-left) |
| **Mouth** | Subtle, friendly curved upturn | Dynamic curve morphing from smile to open treat-catch |
| **Blowhole** | Dark circular vent on forehead crown | Origin point for bubble particles, steam, and sleep "Zzz" |

---

## 3. Procedural Rendering & Animation Engine Specification

Rather than loading heavy video or gif assets that spike CPU and memory, NexIsland preserves Coucou's zero-dependency, ultra-efficient **Canvas + TimelineView** architecture. The rendering engine in `BotEngine.swift` (macOS/iOS), `engine.ts` (Windows/Linux), and `MochiPainter.kt` (Android) will be rewritten into the **DolphinEngine**.

### 3.1 Geometric Construction (`DolphinGeometry.swift`)

The dolphin body is constructed parametrically using parametric Bézier splines:
1. **Snout & Melon (Forehead):** Smooth convex curve extending forward with an upward slope.
2. **Dorsal Ridge & Fin:** Top spine arches gently down to the dorsal fin at $x \approx 0.15 R$, rising to a soft curved crest.
3. **Fluke & Tail Stock:** Tapers backward with controllable pitch angle $\theta_{\text{tail}}$, splitting into symmetric flukes.
4. **Pectoral Flippers (Left & Right):** Attached at lower flanks with independent z-index rendering (under-body flipper drawn before body, front flipper drawn after body).
5. **Ventral Belly Cutout:** Smooth interior white belly patch blended using CoreGraphics clipping masks.

```swift
// Example Core Dolphin Path Generator
func dolphinBodyPath(R: CGFloat, rx: CGFloat, ry: CGFloat, yaw: CGFloat, pitch: CGFloat, tailFlex: CGFloat) -> Path {
    var p = Path()
    // Nose / Rostrum tip
    let snout = CGPoint(x: -rx * 0.95, y: -ry * 0.05 + pitch * 10)
    p.move(to: snout)
    
    // Forehead melon to dorsal fin base
    p.addCurve(to: CGPoint(x: -rx * 0.1, y: -ry * 0.85),
               control1: CGPoint(x: -rx * 0.7, y: -ry * 0.7),
               control2: CGPoint(x: -rx * 0.4, y: -ry * 0.85))
               
    // Dorsal fin apex and trailing edge
    p.addCurve(to: CGPoint(x: rx * 0.25, y: -ry * 0.75),
               control1: CGPoint(x: rx * 0.05, y: -ry * 1.35),
               control2: CGPoint(x: rx * 0.2, y: -ry * 1.05))
               
    // Spine to caudal peduncle (tail stock)
    p.addCurve(to: CGPoint(x: rx * 0.85, y: ry * 0.1 + tailFlex * 15),
               control1: CGPoint(x: rx * 0.5, y: -ry * 0.5),
               control2: CGPoint(x: rx * 0.7, y: ry * 0.0))
               
    // Tail flukes
    // ... Fluke lobes rendered with flipper sweep ...
    
    // Underbelly contour (white boundary) back to snout
    p.addCurve(to: snout,
               control1: CGPoint(x: rx * 0.2, y: ry * 0.85),
               control2: CGPoint(x: -rx * 0.6, y: ry * 0.5))
    p.closeSubpath()
    return p
}
```

### 3.2 Dynamic State & Animation Matrix

| State | Motion / Behavioral Mechanics | Eye Shape | Particle FX |
|---|---|---|---|
| **`idle`** | Gentle buoyant bobbing (0.8 Hz sine wave), subtle tail fin waving, pectoral flippers flutter | Standard round glossy with reflection | Subtle surface ripple ring |
| **`working`** | Forward swimming stroke with horizontal undulation, body tilts slightly downward | Determined focused eye | Stream of tiny micro-bubbles trailing |
| **`thinking`** | Tilted head with subtle sonar ping vibration, dorsal fin twitch | Upward glancing pill | Pulsing concentric sonar rings from forehead |
| **`searching`** | Gliding panoramic scan, head rotates left-to-right scanning with radar arc | Glancing sweeping eye | Aquatic radar arc sweep |
| **`approval`** | **Breach Leap:** Dolphin leaps upward out of the notch, doing an acrobatic half-spin | Wide excited sparkle | Splash droplet burst spraying outwards |
| **`question`** | Peeks snout and melon over notch lip, head cocked 12 degrees | Inquisitive wide | Single bouncing question bubble |
| **`error`** | Splash impact stumble, slight belly-up wobble | Flat / dazed | Frothy foam fizzle |
| **`finished`** | Full corkscrew backflip, landing cleanly back into the island notch | Happy closed arcs (`^^`) | Golden bubble burst & sparkle stars |
| **`sleeping`** | Drifting peacefully near surface, slow breathing scale contraction | Peaceful horizontal lines | Slow translucent bubbles rising from blowhole |
| **`dizzy`** | Rapid spinning spiral roll when poked/clicked 3+ times | Hypnotic spirals | Orbiting dizzy sea stars |
| **`gulp (drop)`** | Jumps up with open mouth catching dropped files like fish/treats | Cheerful blink | Deep suction water splash |

---

## 4. App Icon, Cosmetics & Visual Assets Overhaul

### 4.1 Master App Icon Suite (`NotchBuddy/Assets.xcassets/AppIcon.appiconset/`)
- **Theme:** "The Dolphin in the Island"
- **Composition:** 
  - Standard macOS rounded squircle tile.
  - Deep midnight-abyss gradient background (`#0B132B` to `#1C2541`).
  - Sleek matte black Dynamic Island cutout nestled at the upper edge.
  - Glossy 3D sky-blue dolphin leaping vigorously through the island notch toward the viewer.
  - Subtle neon cyan caustic lighting ripple across the bottom quadrant.
- **Sizes Required:**
  - `icon_16x16.png`, `icon_16x16@2x.png` (32x32)
  - `icon_32x32.png`, `icon_32x32@2x.png` (64x64)
  - `icon_128x128.png`, `icon_128x128@2x.png` (256x256)
  - `icon_256x256.png`, `icon_256x256@2x.png` (512x512)
  - `icon_512x512.png`, `icon_512x512@2x.png` (1024x1024)

### 4.2 Menu Bar Icon (`NotchBuddy/Assets.xcassets/MenuBarIcon.imageset/`)
- Pure monochrome vector silhouette conforming to macOS Human Interface Guidelines.
- Dolphin leaping in a smooth arc above a horizontal notch pill line.
- Provided at 16x16 (`menubar.png`), 32x32 (`menubar@2x.png`), 48x48 (`menubar@3x.png`).

### 4.3 Mobile Themed Icon Variations (`PhoneAssets.xcassets/`)
iOS & Android alternate editions:
- **Ocean Blue (Default):** Sky-blue dolphin in deep azure ocean.
- **Abyssal Graphite:** Monochromatic matte-charcoal dolphin with luminescent cyan eyes.
- **Emerald Coral:** Mint/teal dolphin with tropical turquoise water.
- **Sunset Lagoon:** Rose-pink dolphin with vibrant golden sunset gradient.
- **Twilight Purple:** Lavender-indigo dolphin with electric violet aura.

### 4.4 Island & Notch Cosmetics
- **Water Ripple Island Edge:** Subtle animated aqua glow (`#48CAE4`) outlining the notch when tasks update.
- **Bubble Particle Emitter:** Replaces star/spark particle classes with translucent CoreGraphics bubbles that refract background colors.
- **Ocean Wardrobe:**
  - Scuba mask & snorkel
  - Sailor / Captain cap
  - Tropical floral lei
  - Sea shell crown

---

## 5. Sound Effects Re-engineering (29 Aquatic Audio Assets)

All 29 legacy audio files in `NotchBuddy/Resources/sounds/` will be replaced with custom, studio-grade hydro-acoustic effects.

| File Name | Duration | Description & Sound Character |
|---|---|---|
| `greet.wav` | 0.35s | Cheerful high-frequency dolphin trill with gentle water chime |
| `greeting.wav` | 0.85s | Full melodic water splash intro followed by welcoming dolphin chirp |
| `approval.wav` | 0.45s | Ascending melodic aqua bell chime signaling task approval ready |
| `approve.wav` | 0.25s | Crisp underwater bubble pop with positive tactile punch |
| `work.wav` | 0.20s | Soft hydrodynamic flipper stroke / rhythmic water pulse |
| `think.wav` | 0.25s | Soft resonant sonar ping with lingering reverberation |
| `search.wav` | 0.30s | Rapid gentle echolocation click sequence |
| `finish.wav` | 0.60s | Celebratory crystal water drop chime with harmonic major chord |
| `error.wav` | 0.40s | Muffled sub-bass water thud with splash dispersion |
| `gulp.wav` | 0.35s | Suction whoosh followed by solid bubble gulp (file received) |
| `attach.wav` | 0.25s | Clean aquatic lock-in click |
| `blip.wav` | 0.08s | Crisp micro-droplet ping |
| `close.wav` | 0.22s | Smooth sliding water surface seal |
| `open.wav` | 0.25s | Buoyant surface breach emergence sound |
| `dizzy.wav` | 0.55s | Warbling underwater oscillator wobble with bubble swirl |
| `hover.wav` | 0.06s | Microscopic hydro tick |
| `love.wav` | 0.40s | Shimmering coral bell chime with warm resonance |
| `peek.wav` | 0.18s | Playful percussive water drop |
| `pop.wav` | 0.12s | High-clarity bubble burst |
| `proud.wav` | 0.45s | Triumphant two-tone dolphin whistle |
| `question.wav` | 0.32s | Curiously rising droplet inflection |
| `rate.wav` | 0.30s | Stepped hydrophone click sequence |
| `send.wav` | 0.22s | Aerodynamic hydro-jet whoosh |
| `slap.wav` | 0.28s | Flat water surface slap with droplet spray |
| `sleep.wav` | 0.70s | Peaceful underwater white-noise swell with soft bubble |
| `tick.wav` | 0.04s | Submerged clock tick |
| `wink.wav` | 0.15s | Quick playful aquatic chirp |
| `yawn.wav` | 0.50s | Relaxed ascending bubble stream |
| `annoyed.wav`| 0.30s | Short grumpy dolphin squawk |

---

## 6. Global Rebranding, Naming & Codebase Migration

### 6.1 Entity Renaming Mapping Table

| Component | Legacy Coucou Identifier | New NexIsland Identifier |
|---|---|---|
| **App Name** | `Coucou` | `NexIsland` |
| **Internal Mac Project** | `NotchBuddy` | `NexIsland` |
| **Mascot Name** | `Mochi` | `Splash` (or `Nexi`) |
| **macOS Bundle ID** | `fr.louisraille.NotchBuddy` | `com.nexsz.nexisland` |
| **iOS Bundle ID** | `fr.louisraille.NotchBuddy.phone` | `com.nexsz.nexisland.phone` |
| **Widgets Bundle ID** | `fr.louisraille.NotchBuddy.widgets` | `com.nexsz.nexisland.widgets` |
| **Android Package** | `com.coucou.android` | `com.nexisland.android` |
| **CLI Command** | `coucou` | `nexisland` |
| **Hook Script / Server**| `coucou-hook` / `HookServer` | `nexisland-hook` / `NexHookServer` |
| **IPC Sockets & Paths**| `~/.coucou/`, `/tmp/coucou.sock` | `~/.nexisland/`, `/tmp/nexisland.sock` |
| **Cask Definition** | `Casks/coucou.rb` | `Casks/nexisland.rb` |
| **Tauri App Name** | `Coucou` / `coucou` | `NexIsland` / `nexisland` |
| **Relay Service** | `relay.coucou.app` | `relay.nexisland.app` |

### 6.2 Key Code Modifications Plan
1. **Swift Core (`NotchBuddy/Sources/`):**
   - Refactor `CoucouKit` -> `NexIslandKit`.
   - Refactor `BotEngine.swift` & `Mochi*.swift` -> `DolphinEngine.swift` & `Splash*.swift`.
   - Update `AppState.swift` and `IslandStateMachine.swift` to use Splash state triggers.
   - Update `Info.plist`, `project.yml`, and entitlements to `NexIsland`.
2. **Windows & Linux Tauri (`windows/`):**
   - Update `tauri.conf.json`: package name, product name, window titles, icons.
   - Refactor `windows/src/mochi/` -> `windows/src/dolphin/`.
   - Update `windows/hook/` CLI relay to `nexisland-hook`.
3. **Android Client (`android/`):**
   - Rename Kotlin package from `com.coucou.android` to `com.nexisland.android`.
   - Refactor `MochiPainter.kt` to `DolphinPainter.kt`.
   - Update `AndroidManifest.xml` and widget providers.
4. **Cloudflare Worker Relay (`relay/`):**
   - Update APNs notification headers and payload identifiers to `com.nexsz.nexisland`.

---

## 7. Attribution & Licensing Contract

Compliance with the open-source MIT License of `Louis-CFM/coucou` is strictly maintained, while clearly giving credit to both the original creator and the modifier.

### 7.1 LICENSE File Header
```text
MIT License

Copyright (c) 2026 Louis CFM (Original Coucou project and architecture)
Copyright (c) 2026 NexSz (NexIsland fork, Dolphin mascot, new soundscape, assets & branding)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
```

### 7.2 In-App Credits & About Dialog (`AboutView.swift` / `SettingsView.swift`)
Every platform's About view will state:
> **NexIsland**  
> Version 1.0.0 (Build 100)  
> *A tiny aquatic friend in your notch keeping an eye on AI coding agents.*  
> 
> **Credits:**  
> • **Original Concept & Architecture:** [Louis-CFM](https://github.com/Louis-CFM/coucou)  
> • **Fork & Reimagined By:** **NexSz** (Dolphin Mascot, Animations, Aquatic Audio & Theme)  

---

## 8. Phased Execution Roadmap

```
  Phase 1: Workspace & Git Fork Setup
    └── Initialize NexIsland workspace, branch, directory alignment
  
  Phase 2: Asset Production & Pipeline
    ├── Generate 1024x1024 3D Dolphin AppIcon & export xcassets
    ├── Generate 16/32/48px MenuBar silhouette icons
    ├── Synthesize & export 29 hydro-acoustic 24-bit 44.1kHz WAV sound effects
    └── Generate mobile alternate icons (5 color variants)

  Phase 3: Mascot Rendering Engine Rebuild
    ├── Implement Dolphin parametric spline path in SwiftUI / CoreGraphics
    ├── Implement glossy dual-tone shaders & specular highlights
    ├── Code swimming, breach leap, and water ripple animations
    └── Port DolphinEngine to TypeScript (Tauri) and Kotlin (Android)

  Phase 4: Global Codebase Migration & Renaming
    ├── Update XcodeGen project.yml & regenerates .xcodeproj
    ├── Rename Swift files, structs, classes, and constants
    ├── Update Tauri configuration & CLI hooks
    ├── Update Android package & widgets
    └── Update docs, CHANGELOG, and README

  Phase 5: Quality Assurance & Integration Testing
    ├── Verify 0% CPU sleep behavior in notch
    ├── Verify Claude Code, Codex, Cursor, Gemini hook reception
    ├── Verify audio playback across all 29 states
    └── Multi-platform build verification (macOS, Linux, Windows, Android)
```

### Next Action Step
With the planning phase completed, execution begins with **Phase 1 & Phase 2**: generating the 3D dolphin icon catalog, creating the procedural dolphin rendering code, and packaging the 29 new aquatic sound effects.
