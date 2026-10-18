// Sound volume: the slider reaches full volume.

import { test } from "node:test";
import assert from "node:assert/strict";
import { SOUND_VOLUME_MAX, Sound } from "../src/core/sound.ts";

test("the volume goes up to full and no further", () => {
  Sound.setVolume(0.8);
  assert.equal(Sound.volume, 0.8);
  Sound.setVolume(5);
  assert.equal(Sound.volume, SOUND_VOLUME_MAX);
  Sound.setVolume(-1);
  assert.equal(Sound.volume, 0);
});
