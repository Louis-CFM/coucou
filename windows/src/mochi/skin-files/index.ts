// The skins shipped with the app (kept in the repository, never touched by an
// update of the app). One JSON file each: see ../skins.ts for the format. To add
// one, drop the file here and list it below — or, with no rebuild at all, put it
// in <config folder>/skins/ (see Settings: the wardrobe reads both).

import alien from "./alien.json";
import angelWings from "./angelWings.json";
import apple from "./apple.json";
import bear from "./bear.json";
import blush from "./blush.json";
import bowTie from "./bowTie.json";
import cap from "./cap.json";
import cape from "./cape.json";
import cat from "./cat.json";
import dog from "./dog.json";
import duck from "./duck.json";
import ghost from "./ghost.json";
import headphones from "./headphones.json";
import heartsHeadband from "./heartsHeadband.json";
import kiwi from "./kiwi.json";
import mustache from "./mustache.json";
import orange from "./orange.json";
import pig from "./pig.json";
import robot from "./robot.json";
import scarf from "./scarf.json";
import snowman from "./snowman.json";
import strawberry from "./strawberry.json";
import strawHat from "./strawHat.json";
import topHat from "./topHat.json";
import watermelon from "./watermelon.json";
import watermelonSlice from "./watermelonSlice.json";

export const BUNDLED_SKINS: readonly unknown[] = [
  topHat, cap, heartsHeadband, strawHat,
  scarf, bowTie, cape, angelWings, blush, mustache, headphones,
  dog, cat, bear, pig, duck,
  watermelon, watermelonSlice, orange, strawberry, apple, kiwi,
  ghost, robot, alien, snowman,
];
