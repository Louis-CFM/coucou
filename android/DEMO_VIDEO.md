# Demo video for Louis (about 90 seconds)

Louis asked for a short screen recording of the main flow. Nothing is published: the file goes to Louis only.

## Before recording

- Phone: Coucou for Android from the latest `android` branch, Wi-Fi on, same network as the PC, notification volume up.
- PC: the portable `coucou.exe` (no other Coucou running), Settings > Android phone > Phone link on, phone paired.
- Claude Code (the command-line tool, not the Desktop app) in a folder you trust, started with `claude.cmd --permission-mode default`.
- Phone: Do Not Disturb off, "Show Mochi over other apps" on if you want the island in the video.
- Use a test folder and a harmless command (`echo hello > demo.txt`). No real secrets on screen.

## Shot list

1. Home, connected, Mochi and the agent card (5 s).
2. Lock the phone. In the terminal, ask Claude Code to write `demo.txt` (10 s).
3. The screen lights up with the notification: "Approval needed / Unlock to see the request" (8 s).
4. Unlock and tap Allow with the fingerprint. The phone screen is black here, so cut to the PC with the caption "Request sent for approval", then the terminal continuing (20 s).
5. A second request: the PC shows it waiting, Deny on the phone, the terminal says it was denied, caption "Denied on the phone" (15 s).
6. Plan usage and the Chat tab, if switched on (15 s).
7. Settings > About and Licences: the attribution to Louis (10 s).

## The one catch: secure screens record black

The pairing, chat and approval screens are marked secure on purpose, so a screen recording of them is black. The video
does not remove that protection. During those seconds it shows the request from the other side instead:

- Record the PC screen at the same time (the terminal waiting on the permission, and Coucou's island or card on the PC).
- Put a caption over the black part: **"Request sent for approval"**, then **"Approved on the phone (fingerprint)"** or
  **"Denied on the phone"**. Add the captions when editing (any video editor, or the Windows Clipchamp).
- Cut between the phone (notification, Home, Settings, About) and the PC (terminal and island), so the viewer always sees
  something real. Use the other phone as a camera only if Louis wants to see the approval sheet itself.

## How to record

Wireless or USB, from the PC: `adb shell screenrecord --time-limit 180 /sdcard/coucou-demo.mp4`, then
`adb pull /sdcard/coucou-demo.mp4`. Or use Android's own screen recorder (swipe down twice, Screen recorder).
Trim to about 90 seconds. Check the file for notifications from other apps before sending it.
