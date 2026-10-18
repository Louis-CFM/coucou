import { isAd, type SpotifyState } from "./spotify";
export class MusicAssistant {
  private duck: {original:number;target:number;confirmed:boolean;since:number} | null = null;
  private ad = false;
  private previous: SpotifyState | null = null;
  private progressAt = 0;
  private warned = false;
  update(s: SpotifyState, now: number, quietAds: boolean): {volume?:number; notice?:string} {
    const out: {volume?:number;notice?:string}={};
    const advertising = s.running && isAd(s.track);
    const old=this.previous;
    if(!s.running) { this.duck=null;this.ad=false;this.previous=s;this.warned=false;return out; }
    if(this.duck) {
      if(s.volume===this.duck.target) this.duck.confirmed=true;
      else if(this.duck.confirmed || now-this.duck.since>5000) this.duck=null; // manual adjustment wins
      if(this.duck && (!advertising || !quietAds)) {
        if(s.volume===this.duck.target) out.volume=this.duck.original;
        this.duck=null;
      }
    }
    if(quietAds && advertising && !this.ad && s.volume>10) {
      const target=Math.min(10,Math.round(s.volume*.2));
      this.duck={original:s.volume,target,confirmed:false,since:now};out.volume=target;
    }
    this.ad=advertising;
    if(!old || old.track?.id!==s.track?.id || !s.playing || !old.playing || Math.abs(s.position-old.position)>.5) {
      this.progressAt=now;this.warned=false;
    } else if(!advertising && s.playing && s.track && now-this.progressAt>=60000 && !this.warned) {
      this.warned=true;out.notice="Spotify reports playback, but the track has not advanced for a minute.";
    }
    if(old?.playing && !s.playing && old.track && !advertising && old.track.id===s.track?.id &&
      old.track.duration>0 && s.position>=old.track.duration-3) out.notice="The track ended and nothing else is playing.";
    this.previous={...s};return out;
  }
}
