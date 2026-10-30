import { spotifyPlayer } from "../core/spotify";
import type { AgentTask } from "../core/state";
import { buildMediaCard, buildMediaPill, togglePlay as toggleMediaPlay } from "./media-player";

export const buildSpotifyCard = () => buildMediaCard(spotifyPlayer);
export const buildSpotifyPill = (task: AgentTask, onTap: () => void) => buildMediaPill(task, onTap, spotifyPlayer);
export const togglePlay = () => toggleMediaPlay(spotifyPlayer);
