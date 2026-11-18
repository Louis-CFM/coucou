# Deploying the relay, and trying it with the phone on mobile data

This is the guide for **you** (the person who runs the computer and the phone). It takes about 15 minutes. Nothing here is
published anywhere: the relay is a small program you put on your own Cloudflare account, and only you hold its key.

Why a relay at all: on your home Wi-Fi the phone talks to the computer directly. Away from home it cannot, so both sides
connect *out* to a relay on the internet that passes encrypted messages between them. The relay cannot read them
(wire details: `docs/RELAY_LINK.md`, reasoning and threats: `android/RELAY_PLAN.md`, `android/RELAY_THREAT_CHECK.md`).

You need: a free Cloudflare account, Node 22 or newer on the computer, this repository, and a phone with a debug build of
Coucou for Android (`cd android && ./gradlew assembleDebug`, then `adb install -r app/build/outputs/apk/debug/app-debug.apk`).

## 1. Deploy the relay

```
cd android/relay
npm install
export WRANGLER_SEND_METRICS=false      # optional: Wrangler is Cloudflare's tool and may send anonymous usage statistics
npx wrangler login                      # opens a browser; sign in to your Cloudflare account
```

Make the **access key**, a random 43-character secret that lets a request create or join rooms on *your* relay. Write it down
somewhere safe; you will paste it into the computer's settings:

```
openssl rand -base64 32 | tr '+/' '-_' | tr -d '='
```

Store it on the relay as a secret (this prompts for the value; it is never written to a file or to git), then deploy:

```
npx wrangler secret put ACCESS_KEY      # paste the key when asked
npx wrangler deploy                     # prints https://coucou-link.<your-name>.workers.dev
curl https://coucou-link.<your-name>.workers.dev/     # must print: Coucou link relay
```

Notes:

- If `deploy` complains about the `[[ratelimits]]` block, delete that block from `android/relay/wrangler.toml` and deploy again:
  the relay works without it (it only limits new connections per address).
- In the Cloudflare dashboard, open the Worker `coucou-link` and check that **Observability / Logs are off**. The relay logs
  nothing and has nothing worth logging, but this is the one place a setting could differ from the file.
- `wrangler.toml` contains no secret. Never add the access key to it, to `.dev.vars`, or to any file you commit.

## 2. Set up the computer (Windows or Linux)

1. Settings > **Android phone**. Turn **Phone link** on.
2. In the block **Away from home Wi-Fi**:
   - **Relay address**: `wss://coucou-link.<your-name>.workers.dev` (it must start with `wss://`), press **Save address**.
   - **Relay access key**: paste the key from step 1, press **Save key**. The field empties; the key is kept in the system keystore
     and is never shown again.
   - Turn **Away from home Wi-Fi** on.
3. The status under it should read **Connected to the relay, waiting for the phone.** Other messages and what they mean are in
   section 6.
4. Press **Show pairing code**. The code now also carries the relay's host (a line says so) and an end-to-end key made for this
   pairing.

If you change the address or the key later, press **Show pairing code** again and scan the new code with the phone.

## 3. Pair the phone (the real test: mobile data, not Wi-Fi)

1. On the phone, **turn Wi-Fi off** (mobile data only) and make sure the data connection works.
2. Open Coucou for Android, scan the code on the computer's screen (the camera does not need a network). The confirmation names
   the computer **and the relay's host**: check that it is yours, then pair.
3. Within a few seconds Home should show the computer as connected, and Settings > **Away from home Wi-Fi** should say
   **Connected through your relay (coucou-link...)**. The computer's block says **The phone is connected through the relay.**

If it does not connect, go to section 6 before anything else.

## 4. The checklist (PC on home Wi-Fi, phone on mobile data)

Tick each line and note anything odd. "Expect" is what should happen.

| # | Do | Expect |
|---|---|---|
| 1 | `curl` the relay address | `Coucou link relay` |
| 2 | Computer: relay on | `Connected to the relay, waiting for the phone.` |
| 3 | Phone on mobile data: scan, pair | Connected, card says **through your relay** |
| 4 | Start an agent on the computer | Its session appears on the phone |
| 5 | Trigger a permission request | The sheet appears. **Deny** works at once. **Allow** asks for the fingerprint or screen lock, then the agent goes on |
| 6 | Tap the same decision twice, quickly | The second one is ignored |
| 7 | Leave a request unanswered for 2 minutes | It expires on both sides; a late tap is refused |
| 8 | Phone back on the home Wi-Fi | Within about a minute the card says **Connected directly**; leave again and it goes back to the relay |
| 9 | Put the computer to sleep for a minute, wake it | Phone shows the computer offline, then recovers by itself |
| 10 | Computer: change the relay address to something wrong | Status says the relay cannot be reached; **the agents are never delayed**; at home the direct link still works |
| 11 | Computer: **Pair again** | The phone is cut off at once and must scan the new code; the old pairing cannot reconnect |
| 12 | Make a new access key, `npx wrangler secret put ACCESS_KEY`, paste it in the computer's **Relay access key**, Save | New connections with the old key are refused. A phone that is connected **follows the new key by itself** (it is sent inside the encrypted channel); a phone that was offline needs a new scan |
| 13 | `npx wrangler tail` while an agent works | Connections only, **no readable content** (there is none to show) |
| 14 | Phone on mobile data, screen off, not moving, **30 minutes** | Does an approval still arrive? (Doze and the carrier decide; this is the one result I cannot predict) |
| 15 | Overnight battery: before, `adb shell dumpsys batterystats --reset`; after, `adb shell dumpsys batterystats --charged com.coucou.android` | Note the percentage used and tell me |

## 5. Rotating, losing a phone, switching off

- **A phone is lost or stolen:** on the computer press **Pair again** (a new key and a new room; the old phone can no longer read
  or send anything). That phone also still holds the relay's access key, which only lets someone use your free quota, not read
  anything. If you want to cut that too, rotate the access key (row 12 above).
- **The access key leaked:** rotate it (row 12). It protects your quota, not your data.
- **Stop using the relay:** turn **Away from home Wi-Fi** off on the computer. Nothing connects out any more. To remove the relay
  entirely: `cd android/relay && npx wrangler delete`.
- **Free tier:** Cloudflare's current limits are on their pages (I wrote them down from memory, check). If the daily quota runs out,
  the phone keeps working on the home network and the card says the relay is unreachable; nothing is lost because nothing is
  stored. A paid Workers plan removes the cap.

## 6. When the status line is not green

| Computer says | Phone card says | What to check |
|---|---|---|
| **The relay refused the access key** | Check it in Settings on your computer | The key pasted on the computer is not the one stored with `wrangler secret put`. Paste again; Save key |
| **The relay cannot be reached. Trying again.** | Cannot reach the relay | Wrong address, no internet, or Cloudflare unreachable. The address must be `wss://` and nothing else |
| **This pairing is in use somewhere else. Press Pair again.** | This pairing is in use somewhere else | A second copy of the computer app with the same pairing, or someone holds the room. Press **Pair again** |
| **The relay is limiting connections from here** | The relay is limiting connections for now | Too many connection attempts from this address in a minute; it retries by itself |
| Connected, waiting for the phone | Your computer is not answering through the relay | The computer is asleep, the app is closed, or its relay switch is off |

The phone's card says **This pairing has no relay** when the code was made before the relay was switched on: switch it on, show
the code again, and scan it.

## 7. What I could not test for you

Doze and carrier behaviour on a real phone, real battery cost, the real Cloudflare free-tier limits and the hibernation timing
in production (the tests run the real Worker code locally under `wrangler dev`, end to end with the Rust computer and the Kotlin
phone, but not on Cloudflare's network), and the Android screens' appearance (Compose and lint run in CI only). Rows 14 and 15
above, and a first look at the Settings card, are what is missing.
