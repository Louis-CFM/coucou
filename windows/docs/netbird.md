# NetBird and remote management

Coucou has no built-in NetBird integration. NetBird can provide a private network for tools outside Coucou, including an explicitly configured remote terminal or desktop. Coucou does not enroll devices, enable remote access, change network policies or run commands on remote peers.

NetBird also offers a [browser client for SSH and RDP](https://docs.netbird.io/manage/peers/browser-client). The dashboard requires an administrator account; NetBird SSH or the target RDP service and appropriate access must already be configured. This is a NetBird workflow, not an embedded Coucou desktop-control feature.

The installed NetBird CLI exposes machine-readable connection and peer information through `netbird status --json`. A possible Coucou integration can reuse that existing sign-in for an opt-in, read-only peer list, connection health and a refresh action. Polling belongs only in the open management view. Peer addresses, account details and raw status output must remain local. See the [NetBird CLI reference](https://docs.netbird.io/get-started/cli).

Remote actions need a selected host and an explicit user action. NetBird SSH also needs the target's SSH service and access policy configured; a connected peer alone does not grant command execution. Network-wide management uses the separate [NetBird API](https://docs.netbird.io/api) and requires its own authentication. CLI sign-in must not be treated as API authorization. Any API credentials belong in the OS credential store, with the management URL supplied by configuration.

NetBird's [Remote Jobs](https://docs.netbird.io/manage/peers/remote-jobs) require the target peer to opt in. Coucou has no remote-job control and does not enable that option.

The current Android phone link uses certificate pinning and a pairing token independently of network access. Its pairing QR advertises the detected LAN address; it has no NetBird address selector. NetBird connectivity therefore does not establish phone pairing or iPhone support. Windows-to-iPhone transport is not supplied by NetBird connectivity.
