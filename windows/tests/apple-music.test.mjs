import { beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { emit, sent } from "./tauri.mjs";
import { installFakeDom } from "./fakedom.mjs";
import { AppleMusic, APPLE_MUSIC_ID } from "../src/core/apple-music.ts";
import { IDLE_SPOTIFY, Spotify, islandDances } from "../src/core/spotify.ts";
import { State, DEFAULT_SETTINGS } from "../src/core/state.ts";
import { registerAppleMusicHandlers } from "../src/island/apple-music.ts";
import { buildAppleMusicCard, buildAppleMusicPill } from "../src/views/apple-music.ts";
import { setLanguage } from "../src/i18n/i18n.ts";

installFakeDom();
const island = { reveals: 0, revealSilently() { this.reveals++; } };
registerAppleMusicHandlers(island);
const track = { id:"apple:123", objectPath:"/org/node/mediaplayer/cider/track/123", title:"Example Track", artist:"Example Artist", album:"Example Album", duration:180, artUrl:"https://is1-ssl.mzstatic.com/image/test.jpg" };
const playing = { ...IDLE_SPOTIFY, installed:true, running:true, playing:true, track, position:10, positionAt:Date.now(), volume:70 };
beforeEach(() => {
  setLanguage("en");
  State.settings = { ...DEFAULT_SETTINGS, activeIntegrations:[APPLE_MUSIC_ID] };
  State.os="linux"; State.tasks=[]; State.focusId=null;
  State.mode="hidden"; State.view="overview"; State.paused=false;
  Spotify.state={...IDLE_SPOTIFY}; AppleMusic.state={...IDLE_SPOTIFY}; AppleMusic.artwork=null;
  State.loadIntegrationTasks(); island.reveals=0;
});

test("Cider updates only its own pill, reveals once, and makes Mochi dance", () => {
  emit("apple-music", playing);
  assert.equal(State.tasks.find(t=>t.id===APPLE_MUSIC_ID).name,track.title);
  assert.ok(State.spotifyPlaying); assert.equal(island.reveals,1);
  emit("apple-music", {...playing, position:30}); assert.equal(island.reveals,1);
  assert.equal(Spotify.state.track,null);
  assert.ok(islandDances({music:true,state:"idle",mode:"expanded",view:"overview",focusId:APPLE_MUSIC_ID}));
  State.settings.activeIntegrations=[];
  emit("apple-music",playing); assert.ok(!State.spotifyPlaying);
});

test("Apple card reads supplied metadata and routes all buttons to Cider", () => {
  emit("apple-music", {...playing, playing:false});
  const card=buildAppleMusicCard(); card.sync();
  assert.match(card.el.textContent,/Cider.*Example Track.*Example Artist.*Example Album/);
  const [shuffle,prev,play,next,repeat]=card.el.querySelector("np-buttons").children;
  const before=sent("cider_control").length;
  shuffle.fire("click"); repeat.fire("click"); prev.fire("click"); next.fire("click"); play.fire("click");
  assert.deepEqual(sent("cider_control").slice(before),[
    {action:"shuffle",value:1},{action:"repeat",value:1},{action:"previous",value:null},
    {action:"next",value:null},{action:"playPause",value:null},
  ]);
  assert.equal(sent("spotify_control").length,0);
  assert.ok(AppleMusic.state.playing);
});

test("a stale artwork never appears on a new Apple Music track", () => {
  emit("apple-music",playing);
  emit("apple-music-artwork",{artUrl:track.artUrl,dataUrl:"data:image/png;base64,AA"});
  const card=buildAppleMusicCard(); card.sync();
  assert.ok(card.el.querySelector("np-art").classList.contains("has-art"));
  emit("apple-music",{...playing,track:{...track,artUrl:track.artUrl+"new"}}); card.sync();
  assert.ok(!card.el.querySelector("np-art").classList.contains("has-art"));
});

test("focusing Apple Music refreshes once and hover controls stay independent", () => {
  const before=sent("cider_refresh").length;
  State.mode="expanded"; State.setFocus(APPLE_MUSIC_ID); State.notify();
  assert.equal(sent("cider_refresh").length,before+1);
  emit("apple-music",playing);
  const pill=buildAppleMusicPill(State.focusTask,()=>{});
  pill.el.fire("mouseenter"); assert.ok(pill.el.classList.contains("controls"));
  pill.el.querySelector("np-pill-controls").children[0].fire("click");
  assert.equal(AppleMusic.state.playing,false);
  pill.el.fire("mouseleave"); assert.ok(!pill.el.classList.contains("controls"));
});
