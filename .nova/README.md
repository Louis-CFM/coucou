# Nova Phase 1 build transport

This branch carries a compressed, integrity-checked source snapshot because the
connected GitHub interface supports text-file writes, not atomic tree replacement
or binary uploads. The snapshot includes the reviewed source edits, file removals
and original replacement icons. It is NOT an agent harness.

The candidate Windows workflow materializes the snapshot and invokes the original
Tauri/npm build pipeline. It uploads installer, portable binaries and clean source.
No workflow pushes code, publishes releases or receives provider secrets.

To inspect the decoded snapshot before applying:
```powershell
node -e "const fs=require('fs'),z=require('zlib');fs.writeFileSync('snapshot.json',z.gunzipSync(Buffer.from(fs.readFileSync('.nova/phase1.snapshot.b64','utf8'),'base64')))"
```
To materialize locally from this branch: `node .nova/materialize.mjs`.
Then follow the replacement README's Windows build/test instructions.
Phase 1 is a rebrand candidate only. The remaining phases are not implemented.
