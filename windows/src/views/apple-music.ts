import { appleMusicPlayer } from "../core/apple-music";
import type { AgentTask } from "../core/state";
import { buildMediaCard, buildMediaPill, togglePlay as toggleMediaPlay } from "./media-player";

export const buildAppleMusicCard = () => buildMediaCard(appleMusicPlayer);
export const buildAppleMusicPill = (task: AgentTask, onTap: () => void) => buildMediaPill(task, onTap, appleMusicPlayer);
export const togglePlay = () => toggleMediaPlay(appleMusicPlayer);
