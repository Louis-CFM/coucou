import { Bridge, onEvent } from "../core/bridge";
import { AppleMusic, APPLE_MUSIC_ID } from "../core/apple-music";
import { State } from "../core/state";
import type { SpotifyState } from "../core/spotify";
import type { SpotifyHost } from "./spotify";
export function applyAppleMusic(island:SpotifyHost,next:SpotifyState) {
  const was=State.spotifyPlaying;
  AppleMusic.state=next;
  syncName();
  if(!was && State.spotifyPlaying && !State.paused && State.mode==="hidden") island.revealSilently();
  State.notify();
}
function syncName() {
  const task=State.tasks.find(t=>t.id===APPLE_MUSIC_ID);
  if(task) task.name=AppleMusic.state.track?.title || "Cider";
}
export function registerAppleMusicHandlers(island:SpotifyHost) {
  void onEvent<SpotifyState>("apple-music",s=>applyAppleMusic(island,s));
  void onEvent<{artUrl:string;dataUrl:string}>("apple-music-artwork",art=>{AppleMusic.artwork=art;State.notify();});
  let shown=false;
  State.subscribe(()=>{
    syncName();
    const now=State.mode==="expanded" && State.view==="overview" && State.focusTask?.id===APPLE_MUSIC_ID;
    if(now&&!shown) {shown=true;void Bridge.ciderRefresh();} else shown=now;
  });
}
