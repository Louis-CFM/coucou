# Coucou for Android

The phone half of the remote companion: see your PC's agent sessions, approve or
deny permission cards, answer questions and chat — from anywhere, over a
Cloudflare Worker you deploy yourself. Free tier end to end (Worker + Durable
Objects + Firebase Cloud Messaging), no Play account: the APK is sideloaded.

```
PC (Coucou)  ── state ──►  your Worker ("box")  ◄── fetch/decide/chat ──  Android
        ▲                        │                                          ▲
        └──────── take ◄─────────┘                                          │
                                    FCM data push ("card waiting") ─────────┘
```

Pushes carry a kind + timestamp only; the phone then reads the box over HTTPS,
so nothing sensitive rides Google's push. Pairing is a one-time code
(`id|secret|worker`, shown as a QR in Settings); the box stores the secret's
SHA-256, and `Unpair` on either side wipes it.

## 1. Deploy the relay (once)

In `relay/`:

```
npm install
npx wrangler login
npx wrangler deploy                        # prints https://…workers.dev
npx wrangler secret put FCM_SA < service-account.json
```

`service-account.json` comes from Firebase (next step). Full details — and how
the APNs route stays optional — are in `relay/README.md`.

## 2. Firebase (free Spark plan)

1. [console.firebase.google.com](https://console.firebase.google.com) → **Add
   project** (no Google Analytics needed).
2. **Add app → Android**, package `fr.louisraille.coucou.phone` → download
   `google-services.json` → drop it in `android/app/` (gitignored).
3. Project settings → **Service accounts** → **Generate new private key** —
   that file is what `FCM_SA` above takes. Delete it afterwards.
4. No other setup: Cloud Messaging is on by default in new projects.

## 3. Build the APK

Android Studio → open `android/` → **Run ▶**, or headless:

```
cd android
gradlew.bat assembleDebug        # produces app/build/outputs/apk/debug/app-debug.apk
```

Copy the APK to the phone (USB, mail, anything), tap it, allow "install unknown
apps" — done. For a release APK sign it the usual way.

## 4. Pair

1. Coucou → **Settings → Android phone** → paste your `https://…workers.dev`
   URL → **Pair phone…** → a QR + the code appear.
2. In the app: paste the code (the relay URL fills itself from its third
   segment), name the phone, **Connect**.
3. The settings panel flips from "Waiting for the phone…" to the device name —
   you're live.

From then on a waiting permission pings the phone with **Allow / Deny** right
on the notification (questions and chat open the app). The app polls the box
every 3 s while open; between pushes nothing runs in the background.

## Notes

- The secret lives in the PC's keychain (`phone-secret`) and the app's private
  preferences; `allowBackup=false` keeps it out of adb/cloud backups. Treat the
  pairing code like a password while it's on screen.
- Lost phone → **Unpair phone** in Settings wipes the box; a wiped box kicks the
  app back to the pair screen.
- No Google Play services → FCM can't deliver a token and pairing fails; use a
  device with Play services (any stock Android).
- The notification's Allow/Deny works even with the app closed; actions go
  straight to the box and the PC applies them through the same code path as an
  island click.
