import {test} from "node:test";
import assert from "node:assert/strict";
import {PetNotices,NoticeQueue} from "../src/mochi/notices.ts";
import {MusicAssistant} from "../src/core/music-assistant.ts";
import {IDLE_SPOTIFY} from "../src/core/spotify.ts";
import {State,DEFAULT_SETTINGS} from "../src/core/state.ts";
const task={id:"agent_codex",state:"working",sessionId:"s",stepIndex:0};
test("approval notices identify the owner once and a new request can notify again",()=>{
 const p=new PetNotices(),req={pillId:task.id,requestId:"one"};
 assert.equal(p.observe([task],null).length,0);
 assert.equal(p.observe([task],req)[0].pet,task.id);
 assert.equal(p.observe([task],req).length,0);
 assert.equal(p.observe([task],{...req,requestId:"two"}).length,1);
 assert.equal(p.observe([{...task,state:"finished"}],null)[0].urgent,false);
 assert.equal(p.observe([{...task,state:"finished"}],null).length,0);
});
test("notices are bounded and approvals take precedence without responding to them",()=>{
 const q=new NoticeQueue();for(let i=0;i<30;i++)q.push({key:`${i}`,pet:`pet${i}`,urgent:false,text:"Done"});
 q.push({key:"permission",pet:"codex",urgent:true,text:"Permission"});
 assert.equal(q.size,16);assert.equal(q.take().key,"permission");
 q.push({key:"permission",pet:"codex",urgent:true,text:"Permission"});assert.equal(q.size,15);
});
const song={...IDLE_SPOTIFY,running:true,playing:true,volume:70,track:{id:"spotify:track:one",duration:180},position:20};
const ad={...song,track:{id:"spotify:ad:one",duration:30}};
test("identified advertisements duck and restore exactly the previous player volume",()=>{
 const a=new MusicAssistant();a.update(song,0,true);
 assert.equal(a.update(ad,1,true).volume,10);
 assert.equal(a.update({...ad,volume:10},2,true).volume,undefined);
 assert.equal(a.update({...song,volume:10},3,true).volume,70);
 assert.equal(a.update(song,4,true).volume,undefined);
});
test("manual volume adjustments, mute and unknown metadata are respected",()=>{
 const a=new MusicAssistant();a.update(ad,0,true);a.update({...ad,volume:10},1,true);
 a.update({...ad,volume:30},2,true);assert.equal(a.update({...song,volume:30},3,true).volume,undefined);
 assert.equal(new MusicAssistant().update({...ad,volume:0},0,true).volume,undefined);
 assert.equal(new MusicAssistant().update({...song,track:{...song.track,title:"Advertisement"}},0,true).volume,undefined);
 assert.equal(new MusicAssistant().update(ad,0,false).volume,undefined);
});
test("stalls require sixty seconds of unchanged actual position and recover on progress",()=>{
 const a=new MusicAssistant();assert.equal(a.update(song,0,false).notice,undefined);
 assert.equal(a.update(song,30000,false).notice,undefined);
 assert.match(a.update(song,60000,false).notice,/not advanced/);
 assert.equal(a.update(song,90000,false).notice,undefined);
 a.update({...song,position:30},90001,false);
 assert.equal(a.update({...song,position:30},120000,false).notice,undefined);
 assert.match(a.update({...song,position:30},150001,false).notice,/not advanced/);
});
test("normal manual pauses do not trigger end-of-track warnings",()=>{
 const a=new MusicAssistant();a.update(song,0,false);
 assert.equal(a.update({...song,playing:false},100,false).notice,undefined);
 a.update({...song,position:179},200,false);
 assert.match(a.update({...song,position:180,playing:false},300,false).notice,/track ended/);
});
test("each pet sees only its own provider history and does not change the voice default",()=>{
 State.settings={...DEFAULT_SETTINGS,companionMode:true,chatProvider:"ollama"};
 State.focusId="ai_ollama";State.chatHistory=[{id:1,role:"user",content:"private local"}];
 State.focusId="agent_codex";State.chatHistory=[];assert.equal(State.chatProvider,"codex");
 State.chatHistory.push({id:2,role:"user",content:"private codex"});
 State.focusId="ai_ollama";assert.equal(State.chatHistory[0].content,"private local");
 State.chatHistory=[];State.focusId="agent_codex";assert.equal(State.chatHistory[0].content,"private codex");
 assert.equal(State.settings.chatProvider,"ollama");
});

test("answering a Codex permission keeps the Codex card instead of restoring Gravity",()=>{
 State.settings={...DEFAULT_SETTINGS,companionMode:true};
 State.tasks=[{...task,id:"agent_codex"},{...task,id:"agent_antigravity"}];
 State.focusId="agent_antigravity";State.focusBeforeApproval=null;
 State.beginApproval({requestId:"codex-only",sessionId:"s",pillId:"agent_codex",tool:"test",command:"synthetic"});
 assert.equal(State.chatProvider,"codex");
 State.endApproval();
 assert.equal(State.focusId,"agent_codex");assert.equal(State.chatProvider,"codex");
 assert.equal(State.pendingApproval,null);assert.equal(State.focusBeforeApproval,null);
 assert.equal(State.tasks[0].state,"working");
});

test("finishing a permission preserves a manual pet switch and the singleton's old focus policy",()=>{
 State.settings={...DEFAULT_SETTINGS,companionMode:true};
 State.tasks=[{...task,id:"agent_codex"},{...task,id:"agent_antigravity"},{...task,id:"ai_ollama"}];
 State.focusId="agent_antigravity";State.focusBeforeApproval=null;
 State.beginApproval({requestId:"one",sessionId:"s",pillId:"agent_codex",tool:"test",command:"synthetic"});
 State.setFocus("ai_ollama");State.endApproval();assert.equal(State.focusId,"ai_ollama");
 State.settings={...DEFAULT_SETTINGS,companionMode:false};State.focusId="agent_antigravity";
 State.beginApproval({requestId:"two",sessionId:"s",pillId:"agent_codex",tool:"test",command:"synthetic"});
 State.endApproval();assert.equal(State.focusId,"agent_antigravity");
});


import {RecentMusic,spotifyItemUri} from "../src/core/spotify.ts";
test("recent music search is bounded, tokenized, and rejects ads and foreign URLs",()=>{
 const recent=new RecentMusic();
 for(let i=0;i<70;i++)recent.observe({id:`spotify:track:${String(i).padStart(22,"0")}`,title:`Song [${i}]`,artist:"Artist",album:"Album"});
 assert.equal(recent.search("[0]").length,0);
 assert.equal(recent.search("Artist 69")[0].title,"Song [69]");
 assert.equal(recent.search("").length,5);
 assert.equal(spotifyItemUri("https://open.spotify.com/track/0123456789012345678901?si=ignored"),"spotify:track:0123456789012345678901");
 for(const url of ["https://evil.example/track/0123456789012345678901","spotify:ad:0123456789012345678901","spotify:track:bad","https://open.spotify.com.evil/track/0123456789012345678901"])
   assert.equal(spotifyItemUri(url),null);
});
