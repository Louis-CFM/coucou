import { createMusicViews } from "./spotify";
import { AppleMusic, APPLE_MUSIC_ID } from "../core/apple-music";
import { Bridge } from "../core/bridge";
const views = createMusicViews({id:APPLE_MUSIC_ID,name:"Cider",color:"#FA2D48",
  store:AppleMusic,control:Bridge.ciderControl,open:Bridge.ciderOpen});
export const buildAppleMusicCard=views.buildSpotifyCard;
export const buildAppleMusicPill=views.buildSpotifyPill;
export const toggleAppleMusic=views.togglePlay;
