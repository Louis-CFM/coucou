#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-codex-text.XXXXXX")"
trap 'if [ -f "$TEST_DIR/server-error" ]; then cat "$TEST_DIR/server-error"; fi; rm -rf "$TEST_DIR"' EXIT
cat > "$TEST_DIR/server.py" <<'PY'
#!/usr/bin/python3
import json,os,sys,time,pathlib
sys.excepthook=lambda kind,error,tb:(pathlib.Path(__file__).parent/'server-error').write_text(repr(error))
home=pathlib.Path(os.environ['CODEX_HOME'])
assert home.parent.stat().st_mode&0o777==0o700
assert home.stat().st_mode&0o777==0o700
assert (home/'config.toml').stat().st_mode&0o777==0o600
assert pathlib.Path.cwd().name=='work' and pathlib.Path.cwd().parent.name.startswith('coucou-text-')
assert not any(k.startswith(('OPENAI_','CODEX_')) and k!='CODEX_HOME' for k in os.environ)
# Neither credential contents nor a credential file are sent to this subprocess.
auth=home/'auth.json'
assert not auth.exists()
try:auth.write_text('DAMAGED')
except PermissionError:pass
else:raise AssertionError('Plaintext auth write was permitted')
try:(pathlib.Path(__file__).parent/'native'/'auth.json').read_text()
except PermissionError:pass
else:raise AssertionError('Native credentials remained readable')
def send(x):
 sys.stdout.write(json.dumps(x)+'\n');sys.stdout.flush()
for line in sys.stdin:
 r=json.loads(line);m=r.get('method');p=r.get('params',{})
 if m is None or m=='initialized':continue
 out={}
 if m=='initialize':out={'userAgent':'coucou/0.163.0 (fixture)'}
 elif m=='account/read':out={'account':{'type':'chatgpt'}}
 elif m=='config/read':out={'config':{'mcp_servers':{}}}
 elif m=='thread/start':
  assert p['ephemeral'] and p['environments']==p['runtimeWorkspaceRoots']==p['selectedCapabilityRoots']==p['dynamicTools']==[]
  assert p['sandbox']=='read-only' and p['approvalPolicy']=='never' and p['modelProvider']=='openai'
  assert all(v is False for v in p['config']['features'].values())
  assert not p['config']['agents']['enabled'] and p['config']['project_doc_max_bytes']==0
  out={'thread':{'id':'text-thread','ephemeral':True,'environments':[]},'runtimeWorkspaceRoots':[],'instructionSources':[]}
 elif m=='turn/start':
  assert p['threadId']=='text-thread' and p['environments']==p['runtimeWorkspaceRoots']==[]
  query=p['input'][0]['text'];turn='text-turn'
  send({'method':'turn/started','params':{'threadId':'text-thread','turn':{'id':turn}}})
  if query=='hold':continue
  if query=='delayed':time.sleep(0.15)
  if query=='unknown-tool':
   send({'id':999,'method':'item/tool/call','params':{'threadId':'text-thread','turnId':turn,'tool':'read_private'}});continue
  if query=='disconnect':sys.exit(0)
  send({'method':'item/completed','params':{'threadId':'wrong','turnId':turn,'item':{'type':'agentMessage','id':'foreign','text':'WRONG'}}})
  send({'method':'item/completed','params':{'threadId':'text-thread','turnId':'stale','item':{'type':'agentMessage','id':'stale','text':'STALE'}}})
  send({'method':'item/completed','params':{'threadId':'text-thread','turnId':turn,'item':{'type':'agentMessage','id':'comment','phase':'commentary','text':'Let me think'}}})
  send({'method':'item/completed','params':{'threadId':'text-thread','turnId':turn,'item':{'type':'agentMessage','id':'partial','phase':'partial_answer','text':'INCOMPLETE JSON'}}})
  send({'method':'item/completed','params':{'threadId':'text-thread','turnId':turn,'item':{'type':'agentMessage','id':'legacy','text':'LEGACY PRELUDE'}}})
  text='x'*524289 if query=='oversized' else '' if query=='empty' else '{"text":"fixture"}' if 'outputSchema' in p else 'fixture reply'
  status='failed' if query=='failed' else 'completed'
  send({'method':'turn/completed','params':{'threadId':'text-thread','turn':{'id':turn,'status':status,'items':[{'type':'agentMessage','id':'comment','phase':'commentary','text':'Let me think'},{'type':'agentMessage','id':'final','phase':'final_answer','text':text}]}}})
  out={} if query=='malformed-start' else {'turn':{'id':turn}}
 else:raise AssertionError(m)
 try:send({'id':r['id'],'result':out})
 except BrokenPipeError:break
PY
chmod 700 "$TEST_DIR/server.py"
cat > "$TEST_DIR/metadata.py" <<'PY'
#!/usr/bin/python3
import json,pathlib,sys
name=pathlib.Path(sys.argv[0]).name
for line in sys.stdin:
 r=json.loads(line);method=r.get('method')
 if not method or method=='initialized':continue
 if method=='initialize' and name=='metadata-initialize-hang.py':continue
 if method=='config/read' and name=='metadata-hang.py':continue
 result={'userAgent':'coucou/0.163.0 (fixture)'} if method=='initialize' else {'config':{'cli_auth_credentials_store':'keyring'}} if method=='config/read' else r.get('params',{})
 print(json.dumps({'id':r['id'],'result':result}),flush=True)
PY
chmod 700 "$TEST_DIR/metadata.py"
cp "$TEST_DIR/metadata.py" "$TEST_DIR/metadata-hang.py"
cp "$TEST_DIR/metadata.py" "$TEST_DIR/metadata-initialize-hang.py"
cat NotchBuddy/Sources/App/CodexConnection.swift NotchBuddy/Sources/App/CodexTextService.swift > "$TEST_DIR/tests.swift"
cat >> "$TEST_DIR/tests.swift" <<'SWIFT'
enum CodexAuthenticationStatus { case connected, disconnected }
@MainActor final class FixturePublisher { func send() {} }
@MainActor final class CodexChatService { static let shared=CodexChatService();var authenticationStatus=CodexAuthenticationStatus.connected;var authenticationEpoch=UUID();let objectWillChange=FixturePublisher() }
@MainActor final class UserDefaults { static let standard=UserDefaults();var enabled=false;func bool(forKey:String)->Bool {enabled};func set(_ value:Bool,forKey:String){enabled=value} }
@MainActor final class AppState { static let shared=AppState();var codexSearchMode="cached" }
func CoucouCreateCodexAccess(_ path:CFString,_ access:UnsafeMutablePointer<SecAccess?>)->OSStatus {fatalError("Live Keychain ACL must not run in mocked fixture")}
@main struct Tests {
 @MainActor static func main() async throws {
  let base=URL(fileURLWithPath:CommandLine.arguments[1]), native=base.appendingPathComponent("native")
  try FileManager.default.createDirectory(at:native,withIntermediateDirectories:false)
  let auth=native.appendingPathComponent("auth.json")
  let fixture:[String:Any]=["auth_mode":"chatgpt","tokens":["id_token":"fixture-id","access_token":"fixture-access","refresh_token":"KEEP_NATIVE_REFRESH","account_id":"fixture-account"],"OPENAI_API_KEY":"KEEP_API_KEY"]
  let original=try JSONSerialization.data(withJSONObject:fixture)
  try original.write(to:auth)
  var vault:[String:Data]=[:]
  let keyring=CodexTextService.Keyring(read:{ _ in original },save:{account,data,_ in
   assert(!String(decoding:data,as:UTF8.self).contains("KEEP_"))
   let parsed=try JSONSerialization.jsonObject(with:data) as! [String:Any]
   assert((parsed["tokens"] as! [String:Any])["refresh_token"] as? String == "")
   assert(parsed["OPENAI_API_KEY"]==nil);vault[account]=data
  },delete:{account in vault.removeValue(forKey:account)},clear:{account in vault[account]=Data("{}".utf8)})
  let other=Data("different-keyring-account".utf8)
  let preferred=CodexTextService.Keyring(read:{_ in other},save:{_,_,_ in fatalError()},delete:{_ in fatalError()},clear:{_ in fatalError()})
  let selectedFile=try CodexTextService.Keyring.source(home:native,keyring:preferred,storage:"file")
  let selectedKeyring=try CodexTextService.Keyring.source(home:native,keyring:preferred,storage:"keyring")
  let selectedAuto=try CodexTextService.Keyring.source(home:native,keyring:preferred,storage:"auto")
  assert(selectedFile==original && selectedKeyring==other && selectedAuto==other)
  let missing=CodexTextService.Keyring(read:{_ in nil},save:{_,_,_ in fatalError()},delete:{_ in fatalError()},clear:{_ in fatalError()})
  do {_ = try CodexTextService.Keyring.source(home:native,keyring:missing,storage:"keyring");fatalError("Keyring mode read stale file")}catch{}
  let fallback=try CodexTextService.Keyring.source(home:native,keyring:missing,storage:"auto");assert(fallback==original)
  func run(_ query:String,timeout:TimeInterval=2,schema:[String:Any]?=nil,current:@escaping()->Bool={true}) async throws ->String {
   let context=try CodexTextService.Context(executable:base.appendingPathComponent("server.py"),nativeHome:native,keyring:keyring)
   let request=CodexTextService.Request(connection:context.connection,cwd:context.cwd,isCurrent:current)
   let result:Result<String,Error>
   do {result = .success(try await request.run(system:"fixture system",user:query,model:"",timeout:timeout,webSearch:false,outputSchema:schema))}
   catch {result = .failure(error)}
   await context.connection.stopAndWait()
   context.removeCredentials()
   assert((try? Data(contentsOf:auth))==original)
   try FileManager.default.removeItem(at:context.root)
   return try result.get()
  }
  let normal=try await run("normal");assert(normal=="fixture reply")
  let schema:[String:Any]=["type":"object","properties":["text":["type":"string"]],"required":["text"],"additionalProperties":false]
  let structured=try await run("structured",schema:schema);assert(structured=="{\"text\":\"fixture\"}")
  for query in ["empty","failed","oversized","malformed-start","unknown-tool","disconnect"] {
   do {_ = try await run(query);fatalError("Unexpected success: \(query)")} catch {}
  }
  do {_ = try await run("hold",timeout:0.15);fatalError("Timeout succeeded")} catch CodexServiceError.timeout {}
  let task=Task {try await run("hold",timeout:10)}
  try await Task.sleep(for:.milliseconds(80));task.cancel()
  do {_ = try await task.value;fatalError("Cancellation succeeded")} catch is CancellationError {}
  let a=Task {try await run("normal")}, b=Task {try await run("structured",schema:schema)}
  let outputs=try await [a.value,b.value]
  assert(outputs==["fixture reply","{\"text\":\"fixture\"}"])
  var current=true
  let stale=Task {try await run("delayed",current:{current})}
  try await Task.sleep(for:.milliseconds(80));current=false
  do {_ = try await stale.value;fatalError("Old authentication answered")}catch is CancellationError{}
  assert(vault.isEmpty)
  let chat=CodexConnection(executable:base.appendingPathComponent("metadata.py"))
  let chatEcho=try await chat.request("echo",params:["conversation":"kept"]);assert(chatEcho["conversation"] as? String=="kept")
  let metadata=try await CodexTextService.nativeConfiguration(executable:base.appendingPathComponent("metadata.py"),timeout:1)
  assert(metadata["cli_auth_credentials_store"] as? String=="keyring")
  for filename in ["metadata-hang.py","metadata-initialize-hang.py"] {
   let began=ProcessInfo.processInfo.systemUptime
   do {_ = try await CodexTextService.nativeConfiguration(executable:base.appendingPathComponent(filename),timeout:0.12);fatalError("Hung metadata succeeded")}catch CodexServiceError.timeout{}
   assert(ProcessInfo.processInfo.systemUptime-began<1.5)
   let echo=try await chat.request("echo",params:["conversation":"still kept"]);assert(echo["conversation"] as? String=="still kept")
  }
  let pendingMetadata=Task {_ = try await CodexTextService.nativeConfiguration(executable:base.appendingPathComponent("metadata-hang.py"),timeout:10)}
  try await Task.sleep(for:.milliseconds(80));pendingMetadata.cancel()
  do {_ = try await pendingMetadata.value;fatalError("Cancelled metadata succeeded")}catch is CancellationError{}
  assert(chat.isConnected);await chat.stopAndWait()
  let failed=CodexConnection(executable:base.appendingPathComponent("missing"))
  do {_ = try await failed.request("account/read");fatalError("Missing executable succeeded")} catch {}
  await failed.stopAndWait()
  let stableHome=base.appendingPathComponent("stable-text-home")
  let first=try CodexTextService.Context(executable:base.appendingPathComponent("server.py"),nativeHome:native,keyring:keyring,utilityHome:stableHome)
  let stableAccount=CodexTextService.Keyring.account(for:stableHome)
  assert(vault.count==1 && vault[stableAccount] != nil)
  let firstAccount=try await first.connection.request("account/read")
  assert((firstAccount["account"] as? [String:Any])?["type"] as? String=="chatgpt")
  await first.connection.stopAndWait();first.clearCredentials()
  assert(vault.count==1 && vault[stableAccount]==Data("{}".utf8))
  try FileManager.default.removeItem(at:first.root)
  let second=try CodexTextService.Context(executable:base.appendingPathComponent("server.py"),nativeHome:native,keyring:keyring,utilityHome:stableHome)
  assert(second.root != first.root && second.cwd != first.cwd && vault.count==1)
  assert(vault[stableAccount] != Data("{}".utf8))
  let secondRequest=CodexTextService.Request(connection:second.connection,cwd:second.cwd)
  let secondReply=try await secondRequest.run(system:"fixture",user:"normal",model:"",timeout:2,webSearch:false,outputSchema:nil)
  assert(secondReply=="fixture reply")
  await second.connection.stopAndWait();second.clearCredentials()
  try FileManager.default.removeItem(at:second.root)
  assert(vault[stableAccount]==Data("{}".utf8) && (try? Data(contentsOf:auth))==original)
  assert(!FileManager.default.fileExists(atPath:stableHome.appendingPathComponent("auth.json").path))
  let settings=try String(contentsOf:stableHome.appendingPathComponent("config.toml"),encoding:.utf8)
  assert(!settings.contains("fixture-access") && !settings.contains("KEEP_"))
  let arguments=second.connection.arguments.joined(separator:" ")
  assert(arguments.contains("log_dir=") && arguments.contains("sqlite_home=") && arguments.contains(second.root.path))
  second.removeCredentials();assert(vault.isEmpty)
  let loaded=try await CodexTextService.CredentialLoad().run(timeout:1){Data("background source".utf8)}
  assert(String(decoding:loaded,as:UTF8.self)=="background source")
  let loadBegan=ProcessInfo.processInfo.systemUptime
  do {_ = try await CodexTextService.CredentialLoad().run(timeout:0.05){Thread.sleep(forTimeInterval:0.3);return Data()};fatalError("Source deadline ignored")}catch CodexServiceError.timeout{}
  assert(ProcessInfo.processInfo.systemUptime-loadBegan<0.2)
  let pendingSource=Task {try await CodexTextService.CredentialLoad().run(timeout:5){Thread.sleep(forTimeInterval:0.3);return Data()}}
  try await Task.sleep(for:.milliseconds(20));pendingSource.cancel()
  do {_ = try await pendingSource.value;fatalError("Source cancellation ignored")}catch is CancellationError{}
  assert(!CodexTextService.isEnabled && !CodexTextService.isAvailable)
  UserDefaults.standard.enabled=true
  let otherChat=CodexConnection(executable:base.appendingPathComponent("metadata.py"))
  _ = try await otherChat.request("echo",params:["conversation":"survives shutdown"])
  let shutdownMetadata=Task {_ = try await CodexTextService.nativeConfiguration(executable:base.appendingPathComponent("metadata-hang.py"),timeout:10)}
  try await Task.sleep(for:.milliseconds(80))
  CodexTextService.shutdown(keyring:keyring,home:stableHome)
  assert(CodexTextService.isEnabled && !CodexTextService.isAvailable)
  do {_ = try await shutdownMetadata.value;fatalError("Shutdown left owned metadata running")}catch is CancellationError{}
  do {_ = try await CodexTextService.complete(system:"",user:"MUST NEVER SEND");fatalError("Shutdown accepted a new request")}catch CodexServiceError.message{}
  let afterShutdown=try await otherChat.request("echo",params:["conversation":"still independent"])
  assert(afterShutdown["conversation"] as? String=="still independent")
  await otherChat.stopAndWait()
  assert(vault[stableAccount]==Data("{}".utf8))
  print("Codex text fixtures: isolation, Keychain-only access, no native refresh authority, stable account reuse and idle clearing, private logs/sqlite paths, identity, commentary, JSON, failure, bounds, full metadata/source deadlines, cancellation, concurrency, shutdown cancellation and new-request rejection, failed launch passed")
 }
}
SWIFT
swiftc -swift-version 6 -parse-as-library "$TEST_DIR/tests.swift" -o "$TEST_DIR/tests"
"$TEST_DIR/tests" "$TEST_DIR"
