# Phone-link hub

The shared snapshot and decision rules used by the Windows/Linux phone link.
The desktop adapter remains in `../src-tauri/src/phone_link/`; TLS, pairing,
discovery, provider chat and relay handling stay there.

A host publishes snapshots through `hub::Hub` and implements `hub::Host` for
decisions, answers and diff requests. A transport must authenticate each
connection and pass its negotiated capabilities to `Hub::subscribe_with`.

From `windows/`, run the hub tests without Tauri or GTK:

```sh
cargo test -p coucou-phone-link --locked
```

The catalog contract tests read the sibling TypeScript sources. The crate uses
Tokio channels but does not require a running async executor.

This library preserves the current pill-based session identifiers and one pending
approval/question. It does not discover or control existing agent processes.
A headless host would still need its own snapshot producer and decision adapter.

The hub originates in Rhytam Biswas's phone-link module. Its original
copyright notice is retained in the desktop module and carried with the moved
hub source; see `../../android/LICENSE` for the MIT license text.
