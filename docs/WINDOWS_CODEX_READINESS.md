# Windows Codex provider: contribution and public-release review

Review date: 2026-10-01. Upstream base: `835421c7fff260f0f0be48927591b96bfad81cad`.
This is an optional local coding-agent adapter, not an OpenAI chat backend.

## Findings resolved during the replacement contribution

| Finding | Resolution | Regression evidence |
|---|---|---|
| Stdin was read before the relay deadline | Read in a worker under a 2-second budget; limit input to 1 MiB | Real executable with stdin deliberately held open; oversized input |
| A large approval command could be shown only as a truncated prefix | Decline the local card for overlong permission strings; leave the complete prompt to the agent | Native normalization and real executable tests |
| Reply/frame limits were incomplete | Limit reply frames to 32 bytes; reject oversized server frames and time out incomplete reads | Isolated Win32 pipe; native async frame tests |
| Unknown approval decisions became deny | Accept only explicit allow/deny (legacy explicit always becomes allow); otherwise no decision | Native decision and timeout/ack/decline tests |
| Empty CODEX_HOME could target the working directory | Fall back to USERPROFILE/.codex | Disposable configuration fixture |
| Temporary writes used a process-only filename | Exclusive nonce-named temporary file; sync before atomic rename | Install/remove fixture with preserved byte backups |
| Large preview diffs allocated quadratic memory | Switch to complete before/after text above the comparison threshold | Large preview regression |
| Codex SessionEnd exceeded the documented timeout cap | Set SessionEnd and Interrupt to 3 seconds on both platforms | Installer tests |
| Upstream renamed and wrapped the Mac relay | Materialize wrapper plus the correct Python variant and forward provider arguments | Python and real shell-wrapper tests |

## Preserved boundaries

- Untagged events and default preferences remain Claude. Codex setup is opt-in.
- Codex writes only its reviewed `hooks.json`; Claude settings and Codex
  `config.toml` remain separate. Foreign handler siblings and matcher metadata
  survive installation/removal. Changed previews are rejected before writing.
- Permission cards are bound to provider, session and request. Competing cards,
  cancellation, expired prompts, a closed app and missing acknowledgments do
  not grant or deny permission automatically.
- The relay validates the named-pipe server's user SID before sending data.
  The server retains first-instance ownership and Tokio's remote-client rejection.
  This is not authentication of the coding agent: processes under the same user
  can supply events. Do not treat the companion as a security enforcement boundary.
- UI tool text uses text nodes, not HTML injection. Transcript paths and tool
  responses are removed by the relay. The adapter adds no network endpoint,
  account credential, telemetry, background poller or executable installer download.
- No hook test opens the production pipe or changes real agent configuration.
- Existing media, identifiers and release workflows are retained, including
  upstream's pause on Windows downloads while its Defender report is unresolved.

## Executed local checks

The replacement is verified with frontend regression/typecheck/build, native
relay normalization and isolated pipe I/O, native application-library tests,
real relay-process failure/deadline checks, and embedded Mac relay/wrapper tests.
The Windows process suite also executes the quoted command from a disposable
path containing spaces, Unicode and an ampersand through the Windows shell.
Exact command/output/exit records are kept outside git in the local verification
artifact. Windows Rust execution uses the isolated GNU toolchain; it is not an
MSVC/NSIS packaging result. CI is a separate source of results, not presumed success.

## Public-release acceptance gates

- [ ] Windows MSVC native build and NSIS package succeed on the contribution SHA.
- [ ] A clean Windows 10/11 install finds the bundled relay, with WebView2 present.
- [ ] Native Codex setup/trust and shell/edit/finish/interrupt events are dogfooded.
- [ ] Explicit Allow/Deny, no answer, concurrent providers and stale cards are
      exercised in the actual UI; Claude is retested with its existing setup.
- [ ] Custom folders (spaces/Unicode), uninstall, byte backups and foreign hooks
      are checked in an installed build, without changing unrelated configuration.
- [ ] Defender/SmartScreen, signing and distribution decisions are cleared by
      the upstream maintainer; no exclusions or protection disabling are requested.
- [ ] Native idle CPU and UI evidence are recorded; supported Codex client/version
      coverage is established separately from the inspected CLI `0.153.3`.
- [ ] Both native Mac variants and the Swift installer test pass their CI job.

Ready for review is a contribution status, not certification for public binaries.
Automated fixture success must not be presented as completion of the release gates.

## Reusable verification prompt

```text
Review the Windows Codex provider using AGENTS.md and this acceptance matrix.
Trace reviewed setup -> native relay -> named pipe -> provider-owned card ->
explicit decision. Use disposable files and isolated peers. Run frontend,
MSVC native and package checks on the exact PR head; record native UI/Defender
evidence separately. Preserve Claude defaults and the upstream download pause.
```

Protocol reference: [official Codex hooks](https://learn.chatgpt.com/docs/hooks).
