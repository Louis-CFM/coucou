#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-codex-services.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
cat > "$TEST_DIR/server.py" <<'PY'
import json, sys, os, time
objects=[b'<< /Type /Catalog /Pages 2 0 R >>',b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>']
stream=b'BT /F1 8 Tf 5 70 Td (actual attachment) Tj ET 0 0 1 rg 20 20 20 20 re f'
objects += [b'<< /Length '+str(len(stream)).encode()+b' >>\nstream\n'+stream+b'\nendstream',b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>']
pdf=b'%PDF-1.4\n';offsets=[0]
for index,obj in enumerate(objects,1): offsets.append(len(pdf));pdf+=str(index).encode()+b' 0 obj\n'+obj+b'\nendobj\n'
xref=len(pdf);pdf+=b'xref\n0 6\n0000000000 65535 f \n'
for offset in offsets[1:]:pdf+=('%010d 00000 n \n'%offset).encode()
pdf+=b'trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n'+str(xref).encode()+b'\n%%EOF\n'
with open(os.path.join(os.path.dirname(__file__),'fixture.pdf'),'wb') as fixture:fixture.write(pdf)
thread_starts=0
turn_starts=0
pending_interrupt=None
held_turn=None
account_update_at=None
account_epoch=0
auth_type='chatgpt'
auth_stale=False
auth_delay=0
login_mode='normal'
login_sequence=0
active_login=None
def send(value):
    data=json.dumps(value)+"\n"
    # Deliberately fragment JSONL across pipe reads.
    mid=len(data)//2
    sys.stdout.write(data[:mid]);sys.stdout.flush()
    sys.stdout.write(data[mid:]);sys.stdout.flush()
for line in sys.stdin:
    request=json.loads(line)
    method=request.get('method')
    if method is None: continue
    if method=='initialized': continue
    with open(os.path.join(os.path.dirname(__file__),'rpc-methods'),'a') as log: log.write(method+'\n')
    result={}
    if method=='initialize': result={'userAgent':'codex_cli_rs/0.160.0 (fixture)'}
    elif method=='fixture/armAccountUpdate': account_update_at=request['params']['at']
    elif method=='fixture/setAuthentication':
        auth_type=request['params'].get('type','chatgpt')
        auth_stale=request['params'].get('stale',False)
        auth_delay=request['params'].get('delay',0)
        login_mode=request['params'].get('login','normal')
    elif method=='fixture/completeLogin':
        mismatch=request['params'].get('mismatch',False)
        success=request['params'].get('success',True)
        if success and not mismatch: auth_type='chatgpt'
        send({'method':'account/login/completed','params':{'loginId':'another-login' if mismatch else active_login,'success':success,'error':None if success else 'Fixture sign-in failed'}})
    elif method=='hooks/list': result={'data':[{'errors':[],'hooks':[{'command':'/tmp/nb-hook --agent codex','eventName':event,'enabled':True,'trustStatus':'trusted'} for event in ['sessionStart','stop']]}]}
    elif method=='account/rateLimits/read':
        stale=False
        if account_update_at in ['limits','always']:
            send({'method':'account/updated','params':{'authMode':'chatgpt'}});account_epoch+=1;stale=True
            if account_update_at!='always':account_update_at=None
        result={'rateLimits':{'primary':{'usedPercent':999 if stale else 35 if account_epoch else 25,'windowDurationMins':300,'resetsAt':int(time.time())+3600}},'rateLimitResetCredits':{'availableCount':2,'credits':[{'status':'available','expiresAt':int(time.time())+86400}]}}
    elif method=='account/usage/read':
        stale=False
        if account_update_at=='usage':
            send({'method':'account/updated','params':{'authMode':'chatgpt'}});account_update_at=None;account_epoch+=1;stale=True
        result={'summary':{'lifetimeTokens':999 if stale else 222 if account_epoch else 111},'dailyUsageBuckets':[],'threadUsage':None}
    elif method=='hang': continue
    elif method=='stall':
        send({'id':request['id'],'result':{}});time.sleep(10);continue
    elif method=='exit': sys.exit(0)
    elif method=='oversized': sys.stdout.write('x'*2097153+'\n');sys.stdout.flush();continue
    elif method=='account/read':
        if auth_delay:time.sleep(auth_delay)
        if auth_type=='error':
            send({'id':request['id'],'error':{'code':-32000,'message':'Fixture account unavailable'}});continue
        result={} if auth_type=='missing' else {'account':None if auth_type=='null' else {'type':auth_type}}
        if auth_stale:
            auth_stale=False;auth_type='null'
            # An old connected response must not win over this account change.
            send({'method':'account/updated','params':{'authMode':None}})
    elif method=='account/login/start':
        assert request['params']['type']=='chatgpt'
        login_sequence+=1;active_login='fixture-login-'+str(login_sequence)
        result={'type':'chatgpt','loginId':active_login,'authUrl':'https://auth.openai.com/fixture'}
        notification={'method':'account/login/completed','params':{'loginId':active_login,'success':login_mode!='failed','error':'Fixture sign-in failed' if login_mode=='failed' else None}}
        if login_mode in ['early','failed']:
            if login_mode=='early':auth_type='chatgpt'
            # Completion before the start reply exercises the pre-continuation race.
            send(notification)
        elif login_mode=='normal':
            send({'id':request['id'],'result':result});time.sleep(0.02)
            auth_type='chatgpt';send(notification);continue
    elif method=='account/login/cancel':
        assert request['params']['loginId']==active_login
        active_login=None
    elif method=='account/logout': raise AssertionError('Coucou disconnect must not remove the shared native login')
    elif method=='model/list': result={'data':[{'model':'fixture-model','displayName':'Fixture','inputModalities':['text','image']}],'nextCursor':None}
    elif method=='thread/start':
        p=request['params']
        assert p['sandbox']=='read-only' and p['approvalPolicy']=='on-request'
        assert p['config']['web_search']=='cached'
        thread_starts+=1
        with open(os.path.join(os.path.dirname(__file__),'thread-started'),'w') as marker: marker.write(str(thread_starts))
        time.sleep(0.15)
        thread='owned-thread' if thread_starts==1 else 'owned-thread-'+str(thread_starts)
        result={'thread':{'id':thread,'cwd':p['cwd']},'model':'fixture-model'}
        send({'method':'thread/started','params':{'thread':result['thread']}})
        if pending_interrupt:
            with open(os.path.join(os.path.dirname(__file__),'thread-before-interrupt-reply'),'w') as marker: marker.write(thread)
            # A late event from the cancelled turn must not enter the new Chat.
            send({'method':'item/agentMessage/delta','params':{'threadId':held_turn[0],'turnId':held_turn[1],'itemId':'late','delta':'LATE OLD TURN'}})
            send({'id':pending_interrupt,'result':{}})
            pending_interrupt=None
    elif method=='turn/start':
        p=request['params'];thread=p['threadId']
        assert thread==('owned-thread' if thread_starts==1 else 'owned-thread-'+str(thread_starts)), 'Cancelled native thread reused'
        turn_starts+=1;turn='turn-'+str(turn_starts)
        if len(p['input'])>1: assert 'actual attachment' in p['input'][0]['text']
        if p['input'][0].get('text','').startswith('PDF:'):assert any(item['type']=='localImage' for item in p['input']), 'PDF text-bearing chart image omitted'
        send({'method':'turn/started','params':{'threadId':thread,'turn':{'id':turn}}})
        query=p['input'][0].get('text')
        if query in ['hold for cancel','start rpc error','start rpc timeout','start malformed response']:
            held_turn=(thread,turn)
            send({'method':'item/agentMessage/delta','params':{'threadId':thread,'turnId':turn,'itemId':'partial','delta':'Partial old response'}})
            with open(os.path.join(os.path.dirname(__file__),'held-turn'),'w') as marker: marker.write(turn)
            if query=='start rpc error':
                send({'id':request['id'],'error':{'code':-32000,'message':'Fixture turn/start failed'}});continue
            if query=='start rpc timeout':continue
            if query=='start malformed response':
                send({'id':request['id'],'result':{}});continue
            send({'id':request['id'],'result':{'turn':{'id':turn}}});continue
        send({'method':'item/agentMessage/delta','params':{'threadId':'wrong-thread','turnId':turn,'itemId':'a','delta':'WRONG'}})
        send({'method':'item/agentMessage/delta','params':{'threadId':thread,'turnId':turn,'itemId':'a','delta':'Hello'}})
        send({'method':'item/completed','params':{'threadId':thread,'turnId':turn,'item':{'id':'a','type':'agentMessage','text':'Hello Codex'}}})
        # Completion precedes the start response: client must not lose it.
        send({'method':'turn/completed','params':{'threadId':thread,'turn':{'id':turn,'status':'completed'}}})
        result={'turn':{'id':turn}}
    elif method=='turn/interrupt':
        p=request['params'];assert held_turn==(p['threadId'],p['turnId']), 'Interrupt lost the captured thread/turn IDs'
        pending_interrupt=request['id']
        with open(os.path.join(os.path.dirname(__file__),'interrupt-pending'),'w') as marker: marker.write(p['turnId'])
        continue
    elif method=='echo': result=request['params']
    send({'id':request['id'],'result':result})
PY
cat > "$TEST_DIR/tests.swift" <<'SWIFT'
import Foundation
import Combine
import AppKit
// The service uses this same-module boundary; fixture OAuth never opens a browser.
@MainActor final class NSWorkspace {
 static let shared=NSWorkspace()
 private(set) var opened:[URL]=[]
 func open(_ url:URL)->Bool { opened.append(url);return true }
}
enum ChatProvider { case codex, anthropic }
enum ChatRole { case user, assistant }
enum PromptContext { case window(appName:String,title:String,url:String?);case file(name:String,fileURL:URL?) }
enum BotState { case thinking }
enum IslandView { case prompt }
enum BotEmote { case happy }
struct ChatMessage: Identifiable { let id=UUID();let role:ChatRole;var content:String }
extension Notification.Name { static let triggerEmote=Notification.Name("testEmote") }
@MainActor final class AppState {
 static let shared=AppState(restoringModel:true)
 private var restoringModel=false
 private(set) var startupResets=0
 @Published var codexModel="" {
  didSet {
   if restoringModel { startupResets+=1;CodexChatService.shared.reset() }
  }
 }
 var codexProjectPath="",codexSearchMode="cached",codexCanWrite=false,codexChatBusy=false
 var chatProvider=ChatProvider.codex,chatHistory:[ChatMessage]=[],stateOverride:BotState?,view=IslandView.prompt
 init(restoringModel:Bool=false) {
  self.restoringModel=restoringModel
  if restoringModel { restoreModel() }
  self.restoringModel=false
 }
 // A helper assignment fires didSet while the shared singleton is still initializing.
 private func restoreModel() { codexModel="restored-fixture-model" }
}
@MainActor final class HookServer {
 static let shared=HookServer()
 static let codexRequiredHookEvents=["SessionStart","Stop"]
 var resolvedThreads:[String]=[]
 func resolveCodexRequests(threadId:String) { resolvedThreads.append(threadId) }
}
@MainActor final class CodexEventAdapter { static let shared=CodexEventAdapter();func registerThread(_ thread:[String:Any]) {} }
@main struct Tests {
 @MainActor static func waitUntil(_ predicate:()->Bool,_ message:String) async {
  for _ in 0..<400 {
   if predicate() { return }
   try? await Task.sleep(for:.milliseconds(5))
  }
  assertionFailure(message)
 }
 @MainActor static func authenticationChecks(root:URL) async throws {
  let directory=root.appendingPathComponent("authentication")
  try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
  try FileManager.default.copyItem(at:root.appendingPathComponent("server.py"),to:directory.appendingPathComponent("server.py"))
  let connection=CodexConnection(executable:URL(fileURLWithPath:"/usr/bin/python3"),arguments:["-u",directory.appendingPathComponent("server.py").path],requestTimeout:0.3)
  let lease=connection.retainConnection()
  let chat=CodexChatService(connection:connection),state=AppState()
  func methods()->[String] {
   (try? String(contentsOf:directory.appendingPathComponent("rpc-methods"),encoding:.utf8))?.split(whereSeparator:{$0.isNewline}).map(String.init) ?? []
  }
  await chat.refreshAuthentication()
  assert(chat.authenticationStatus == .connected,"Persisted ChatGPT login was not detected")
  chat.reset();assert(chat.authenticationStatus == .connected,"Reset discarded authorization")
  _=try await connection.request("fixture/setAuthentication",params:["type":"null"])
  await chat.refreshAuthentication();assert(chat.authenticationStatus == .disconnected)
  for kind in ["missing","future-auth-mode","error"] {
   _=try await connection.request("fixture/setAuthentication",params:["type":kind])
   await chat.refreshAuthentication();assert(chat.authenticationStatus == .unknown,"Unknown/read-error account claimed a connection")
  }
  _=try await connection.request("fixture/setAuthentication",params:["type":"apiKey"])
  await chat.refreshAuthentication();assert(chat.authenticationStatus == .disconnected,"API-key mode claimed a ChatGPT link")
  _=try await connection.request("fixture/setAuthentication",params:["type":"chatgpt","delay":0.1])
  let cancelledRefresh=Task { @MainActor in await chat.refreshAuthentication() }
  await waitUntil({chat.authenticationStatus == .checking},"Cancellable account refresh did not begin")
  cancelledRefresh.cancel();await cancelledRefresh.value
  assert(chat.authenticationStatus == .unknown,"Cancelled account refresh remained Checking")
  _=try await connection.request("fixture/setAuthentication",params:["type":"chatgpt","stale":true])
  await chat.refreshAuthentication()
  assert(chat.authenticationStatus != .connected,"Stale account/read restored a revoked connection")
  _=try await connection.request("fixture/setAuthentication",params:["type":"chatgpt","stale":true])
  state.codexProjectPath=directory.path
  let startsBefore=methods().filter{$0=="thread/start"}.count
  await chat.chat(query:"stale initial account",context:nil,state:state)
  assert(chat.threadId==nil && methods().filter{$0=="thread/start"}.count==startsBefore,"Stale initial Chat account created a native thread")
  assert(chat.authenticationStatus != .connected,"Stale initial Chat restored connected status")
  for mode in ["early","normal"] {
   _=try await connection.request("fixture/setAuthentication",params:["type":"null","login":mode])
   await chat.refreshAuthentication()
   let browserCount=NSWorkspace.shared.opened.count
   let login=Task { @MainActor in await chat.login(state:state) }
   await waitUntil({chat.authenticationStatus == .connected},"OAuth completion was lost: \(mode)")
   await login.value
   assert(NSWorkspace.shared.opened.count==browserCount+1 && NSWorkspace.shared.opened.last?.host=="auth.openai.com")
   assert(chat.authenticationStatus == .connected,"Successful OAuth was not published")
  }
  _=try await connection.request("fixture/setAuthentication",params:["type":"null","login":"failed"])
  await chat.refreshAuthentication()
  let failed=Task { @MainActor in await chat.login(state:state) }
  let failedBrowser=NSWorkspace.shared.opened.count
  await waitUntil({NSWorkspace.shared.opened.count>failedBrowser && chat.authenticationStatus != .signingIn},"Failed login remained active")
  await failed.value
  assert(chat.authenticationStatus != .connected && state.chatHistory.last?.content=="Fixture sign-in failed")
  _=try await connection.request("fixture/setAuthentication",params:["type":"null","login":"hold"])
  let browserCount=NSWorkspace.shared.opened.count
  let mismatched=Task { @MainActor in await chat.login(state:state) }
  await waitUntil({NSWorkspace.shared.opened.count>browserCount},"Held OAuth did not start")
  _=try await connection.request("fixture/completeLogin",params:["mismatch":true])
  try? await Task.sleep(for:.milliseconds(20))
  assert(chat.authenticationStatus == .signingIn,"Unrelated login completion was accepted")
  _=try await connection.request("fixture/completeLogin")
  await waitUntil({chat.authenticationStatus == .connected},"Matching OAuth completion did not finish")
  await mismatched.value
  _=try await connection.request("fixture/setAuthentication",params:["type":"null","login":"hold"])
  await chat.refreshAuthentication()
  let cancelBrowser=NSWorkspace.shared.opened.count
  let cancelled=Task { @MainActor in await chat.login(state:state) }
  await waitUntil({NSWorkspace.shared.opened.count>cancelBrowser},"Cancellable OAuth did not start")
  cancelled.cancel()
  await waitUntil({chat.authenticationStatus != .signingIn},"Cancelled OAuth remained active")
  await cancelled.value
  assert(chat.authenticationStatus != .connected && methods().contains("account/login/cancel"))
  _=try await connection.request("fixture/setAuthentication",params:["type":"chatgpt"])
  await chat.refreshAuthentication();assert(chat.authenticationStatus == .connected)
  connection.releaseConnection(lease)
  assert(!connection.isConnected && chat.authenticationStatus == .connected,"Idle transport close discarded persisted authorization")
  chat.disconnect()
  assert(chat.authenticationStatus == .disconnected)
  let before=methods()
  await chat.refreshAuthentication()
  assert(chat.authenticationStatus == .disconnected && methods()==before,"Explicit disconnect automatically reconnected")
  state.codexProjectPath=directory.path
  await chat.chat(query:"after local disconnect",context:nil,state:state)
  assert(chat.authenticationStatus == .disconnected && methods()==before && chat.threadId==nil,"Chat bypassed the explicit disconnect")
  assert(!methods().contains("account/logout"),"Disconnect removed shared Codex credentials")
  let reconnectLease=connection.retainConnection()
  _=try await connection.request("fixture/setAuthentication",params:["type":"null","login":"early"])
  let reconnected=Task { @MainActor in await chat.login(state:state) }
  await waitUntil({chat.authenticationStatus == .connected},"Explicit sign-in did not restore the Coucou link")
  await reconnected.value
  connection.releaseConnection(reconnectLease)
  assert(chat.authenticationStatus == .connected)
  print("PASS authentication: persisted/null/unknown/error, OAuth early/normal/failure/mismatch/cancel, stale account read, reset, idle close and local disconnect (no live browser or logout)")
 }
 @MainActor static func main() async throws {
  let startup=AppState.shared
  assert(startup.codexModel=="restored-fixture-model" && startup.startupResets==1,"Startup restore did not exercise the actual service reset")
  print("PASS startup: restoring the published Codex model can reset the actual shared service without recursive AppState.shared initialization")
  let root=URL(fileURLWithPath:CommandLine.arguments[1])
  let connection=CodexConnection(executable:URL(fileURLWithPath:"/usr/bin/python3"),arguments:["-u",root.appendingPathComponent("server.py").path],requestTimeout:0.3)
  let response=try await connection.request("echo",params:["correct":42]);assert(response["correct"] as? Int==42)
  assert(connection.cliVersion=="0.160.0")
  do { _=try await connection.request("hang");assertionFailure("Expected timeout") } catch CodexServiceError.timeout {}
  let cancelled=Task { _ = try await connection.request("hang") };cancelled.cancel()
  do { _=try await cancelled.value;assertionFailure("Expected cancellation") } catch is CancellationError {}
  let stalled=CodexConnection(executable:URL(fileURLWithPath:"/usr/bin/python3"),arguments:["-u",root.appendingPathComponent("server.py").path],requestTimeout:0.3)
  _=try await stalled.request("stall")
  let started=Date()
  do { _=try await stalled.request("echo",params:["large":String(repeating:"x",count:800_000)]);assertionFailure("Expected blocked writer timeout") } catch CodexServiceError.timeout {}
  assert(Date().timeIntervalSince(started)<2);stalled.stop()
  let hooks:[String:Any]=["data":[["errors":[],"hooks":[["command":"/tmp/nb-hook --agent codex","eventName":"sessionStart","enabled":true,"trustStatus":"trusted"],["command":"/tmp/nb-hook --agent codex","eventName":"stop","enabled":true,"trustStatus":"managed"]]]]]
  assert(CodexAgentsInfo.parseHooks(hooks,requiredEvents:HookServer.codexRequiredHookEvents).status == .done)
  assert(CodexAgentsInfo.parseHooks(hooks,requiredEvents:["SessionStart","Stop","Interrupt"]).status == .incomplete)
  let limits=CodexAgentsInfo.parseLimits(["rateLimitsByLimitId":["codex":["primary":["usedPercent":25,"windowDurationMins":37]]],"rateLimits":["primary":["usedPercent":0]]])
  assert(limits.count==1 && limits[0].usedPercent==25 && limits[0].remainingPercent==75 && limits[0].windowDurationMins==37)
  assert(CodexAgentsInfo.parseLimits(["rateLimits":["primary":["usedPercent":true]]]).isEmpty)
  assert(CodexAgentsInfo.integer(-1)==nil && CodexAgentsInfo.integer(true)==nil)
  let rollout=root.appendingPathComponent("exact.jsonl")
  let records:[[String:Any]]=[
   ["type":"session_meta","payload":["id":"child-thread"]],
   ["type":"event_msg","payload":["type":"token_count","info":["total_token_usage":["input_tokens":10,"output_tokens":2,"total_tokens":12]]]],
   ["type":"event_msg","payload":["type":"token_count","info":["total_token_usage":["input_tokens":20,"output_tokens":4,"total_tokens":24]]]]]
  var bytes=Data();for record in records { bytes.append(try JSONSerialization.data(withJSONObject:record));bytes.append(10) };bytes.append(Data("{partial".utf8));try bytes.write(to:rollout)
  let usage=try CodexAgentsInfo.readRollout(path:rollout.path,threadId:"child-thread",sessionsRoot:root)
  assert(usage?.input==20 && usage?.total==24)
  let wrong=try CodexAgentsInfo.readRollout(path:rollout.path,threadId:"root-thread",sessionsRoot:root);assert(wrong==nil)
  let state=AppState();state.codexProjectPath=root.path
  let attachment=root.appendingPathComponent("source.txt");try Data("actual attachment".utf8).write(to:attachment)
  let workflowLease=connection.retainConnection()
  let chat=CodexChatService(connection:connection)
  let changeWhileStarting=Task { @MainActor in
   for _ in 0..<100 {
    if FileManager.default.fileExists(atPath:root.appendingPathComponent("thread-started").path) { break }
    try? await Task.sleep(for:.milliseconds(5))
   }
   assert(FileManager.default.fileExists(atPath:root.appendingPathComponent("thread-started").path))
   state.codexCanWrite=true;state.codexSearchMode="disabled"
  }
  await chat.chat(query:"read",context:.file(name:"source.txt",fileURL:attachment),state:state)
  await changeWhileStarting.value
  assert(!chat.allowsProjectWrites(threadId:"owned-thread"),"Mutable state escaped the read-only snapshot")
  state.codexCanWrite=false;state.codexSearchMode="cached"
  assert(state.chatHistory.last?.content=="Hello Codex");assert(chat.owns(threadId:"owned-thread"));assert(!chat.owns(threadId:"external-thread"))
  let pdf=root.appendingPathComponent("fixture.pdf")
  await chat.chat(query:"read chart",context:.file(name:"fixture.pdf",fileURL:pdf),state:state)
  assert(state.chatHistory.last?.content=="Hello Codex")
  let utf=root.appendingPathComponent("unicode.txt");try Data(("actual attachment"+String(repeating:"🦀",count:50_000)).utf8).write(to:utf)
  await chat.chat(query:"read unicode",context:.file(name:"unicode.txt",fileURL:utf),state:state)
  assert(state.chatHistory.last?.content=="Hello Codex")
  let threadStarts=try String(contentsOf:root.appendingPathComponent("thread-started"),encoding:.utf8)
  assert(threadStarts=="1","Mutable search mode changed the owned-thread snapshot")
  do { try await chat.sendManagedInstruction(threadId:"external-thread",text:"bad",expectedCwd:root.path);assertionFailure("External writer accepted") } catch {}
  try await chat.sendManagedInstruction(threadId:"owned-thread",text:"continue",expectedCwd:root.path)
  let beforeResolve=HookServer.shared.resolvedThreads.count
  let active=Task { @MainActor in await chat.chat(query:"hold for cancel",context:nil,state:state) }
  for _ in 0..<100 {
   if chat.turnId != nil && state.chatHistory.last?.content=="Partial old response" { break }
   try? await Task.sleep(for:.milliseconds(5))
  }
  assert(chat.isBusy && chat.turnId != nil && state.chatHistory.last?.content=="Partial old response")
  chat.cancel()
  assert(!chat.owns(threadId:"owned-thread") && chat.turnId==nil,"Cancel retained native ownership")
  assert(state.chatHistory.isEmpty && state.stateOverride==nil,"Cancelled history still suggests a continued native conversation")
  assert(HookServer.shared.resolvedThreads.count==beforeResolve+1 && HookServer.shared.resolvedThreads.last=="owned-thread")
  do { try await chat.sendManagedInstruction(threadId:"owned-thread",text:"stale Phone instruction",expectedCwd:root.path);assertionFailure("Cancelled Phone target accepted") } catch {}
  await active.value
  assert(!chat.isBusy && !state.codexChatBusy && state.chatHistory.isEmpty)
  for _ in 0..<100 {
   if FileManager.default.fileExists(atPath:root.appendingPathComponent("interrupt-pending").path) { break }
   try? await Task.sleep(for:.milliseconds(5))
  }
  assert(FileManager.default.fileExists(atPath:root.appendingPathComponent("interrupt-pending").path))
  let newMessage=ChatMessage(role:.user,content:"new conversation")
  state.chatHistory.append(newMessage)
  await chat.chat(query:"new conversation",context:nil,state:state)
  assert(chat.owns(threadId:"owned-thread-2") && !chat.owns(threadId:"owned-thread"),"Chat reused the interrupted native thread")
  assert(state.chatHistory.count==2 && state.chatHistory.first?.id==newMessage.id && state.chatHistory.last?.content=="Hello Codex","Old output leaked into the new conversation")
  let beforeInterruptReply=try String(contentsOf:root.appendingPathComponent("thread-before-interrupt-reply"),encoding:.utf8)
  assert(beforeInterruptReply=="owned-thread-2","Regression did not exercise an outstanding interrupt")
  chat.reset();assert(!chat.owns(threadId:"owned-thread-2") && state.chatHistory.isEmpty)
  assert(HookServer.shared.resolvedThreads.count==beforeResolve+2 && HookServer.shared.resolvedThreads.last=="owned-thread-2")
  for failure in ["start rpc error","start rpc timeout","start malformed response"] {
   await chat.chat(query:failure,context:nil,state:state)
   let failedStart=try String(contentsOf:root.appendingPathComponent("thread-started"),encoding:.utf8)
   let failedThread="owned-thread-"+failedStart
   assert(!chat.owns(threadId:failedThread) && chat.threadId==nil && chat.turnId==nil && !chat.isBusy,"Failed turn/start retained a running native thread")
   assert(state.chatHistory.count==1 && state.chatHistory.last?.content != "Partial old response","Failed RPC kept the old conversation")
   assert(HookServer.shared.resolvedThreads.last==failedThread,"Failed RPC did not clear native pending cards")
   do { try await chat.sendManagedInstruction(threadId:failedThread,text:"stale Phone instruction",expectedCwd:root.path);assertionFailure("Failed-start Phone target accepted") } catch {}
   let held=try String(contentsOf:root.appendingPathComponent("held-turn"),encoding:.utf8)
   for _ in 0..<100 {
    if (try? String(contentsOf:root.appendingPathComponent("interrupt-pending"),encoding:.utf8))==held { break }
    try? await Task.sleep(for:.milliseconds(5))
   }
   assert((try? String(contentsOf:root.appendingPathComponent("interrupt-pending"),encoding:.utf8))==held)
   await chat.chat(query:"fresh after failed start",context:nil,state:state)
   let restarted=try String(contentsOf:root.appendingPathComponent("thread-before-interrupt-reply"),encoding:.utf8)
   assert(restarted != failedThread && chat.owns(threadId:restarted),"Chat reused the failed-start thread before interrupt completed")
   assert(state.chatHistory.last?.content=="Hello Codex")
   chat.reset();assert(state.chatHistory.isEmpty && chat.threadId==nil)
  }
  await chat.chat(query:"before disconnect",context:nil,state:state)
  let disconnectedThread=chat.threadId!
  assert(!state.chatHistory.isEmpty)
  do { _=try await connection.request("exit");assertionFailure("Expected disconnected") } catch CodexServiceError.disconnected {}
  assert(!chat.owns(threadId:disconnectedThread) && chat.threadId==nil && state.chatHistory.isEmpty,"Disconnected history implies retained native context")
  state.chatHistory.append(ChatMessage(role:.user,content:"after disconnect"))
  await chat.chat(query:"after disconnect",context:nil,state:state)
  assert(chat.owns(threadId:"owned-thread") && state.chatHistory.count==2 && state.chatHistory.last?.content=="Hello Codex")
  chat.reset();assert(state.chatHistory.isEmpty)
  connection.releaseConnection(workflowLease)
  let metadataConnection=CodexConnection(executable:URL(fileURLWithPath:"/usr/bin/python3"),arguments:["-u",root.appendingPathComponent("server.py").path],requestTimeout:3)
  let info=CodexAgentsInfo(connection:metadataConnection)
  await info.refresh();assert(info.lifetimeTokens==111 && info.limits.first?.usedPercent==25 && info.updatedAt != nil)
  assert(info.planUsage?.resetCredits==2 && info.planUsage?.fiveHour?.usedPct==25 && info.planUsage?.resetCreditExpiresAt != nil,"Merged Codex plan/reset credits must share the native usage response")
  var publishedLifetimes:[Int64]=[],publishedPercents:[Double]=[]
  let tokenSubscription=info.$lifetimeTokens.compactMap{$0}.sink{publishedLifetimes.append($0)}
  let quotaSubscription=info.$limits.sink{publishedPercents.append(contentsOf:$0.map(\.usedPercent))}
  _=try await metadataConnection.request("fixture/armAccountUpdate",params:["at":"usage"])
  await info.refresh()
  assert(info.lifetimeTokens==222 && info.limits.first?.usedPercent==35 && info.updatedAt != nil && info.error==nil,"Latest usage did not complete on the same process")
  assert(!publishedLifetimes.contains(999),"Old usage response crossed account change")
  _=try await metadataConnection.request("fixture/armAccountUpdate",params:["at":"limits"])
  await info.refresh()
  assert(info.lifetimeTokens==222 && info.limits.first?.usedPercent==35 && info.updatedAt != nil && info.error==nil,"Latest limit did not complete on the same process")
  assert(info.planUsage?.resetCredits==2 && info.planUsage?.fiveHour?.usedPct==35)
  assert(!publishedPercents.contains(999),"Old limit response crossed account change")
  _=try await metadataConnection.request("fixture/armAccountUpdate",params:["at":"always"])
  await info.refresh()
  assert(info.lifetimeTokens==nil && info.limits.isEmpty && info.planUsage==nil && info.updatedAt==nil && info.error != nil,"Repeated account changes must stop with a visible error")
  tokenSubscription.cancel();quotaSubscription.cancel()
  do { _=try await connection.request("oversized");assertionFailure("Expected output limit") } catch CodexServiceError.oversized {}
  do { _=try await connection.request("exit");assertionFailure("Expected disconnected") } catch CodexServiceError.disconnected {}
  connection.stop()
  try await authenticationChecks(root:root)
  print("Codex services: connection, cancellation, bounds, hooks, usage, exact rollout, managed Chat and external-writer guards passed (fixtures; no model inference).")
 }
}
SWIFT
# Compile the shipped Foundation parser; the SwiftUI card is exercised by Xcode builds.
python3 - "$TEST_DIR/codex-plan.swift" <<'PYPLAN'
from pathlib import Path
import sys
source = Path("NotchBuddy/Sources/App/CodexPlanGauge.swift").read_text()
core = source.split("// MARK: - Codex Plan Card View", 1)[0]
core = core.replace("#if !APPSTORE\n", "", 1).replace("import SwiftUI", "import Foundation", 1)
Path(sys.argv[1]).write_text(core)
PYPLAN
swiftc -swift-version 6 -parse-as-library \
 NotchBuddy/Sources/App/CodexConnection.swift \
 NotchBuddy/Sources/App/CodexAgentsInfo.swift \
 NotchBuddy/Sources/App/ClaudePlanGauge.swift \
 "$TEST_DIR/codex-plan.swift" \
 NotchBuddy/Sources/App/CodexChatService.swift \
 "$TEST_DIR/tests.swift" -o "$TEST_DIR/tests"
"$TEST_DIR/tests" "$TEST_DIR"
