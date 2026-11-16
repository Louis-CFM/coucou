"use client";

import {
  Airplane01Icon,
  AlarmClockIcon,
  Alert02Icon,
  ArrowUp02Icon,
  BatteryCharging01Icon,
  Bicycle01Icon,
  Call02Icon,
  CallEnd02Icon,
  Cancel01Icon,
  Car03Icon,
  CheckmarkCircle02Icon,
  Coffee02Icon,
  ComputerIcon,
  ComputerTerminal01Icon,
  Download01Icon,
  FastForwardIcon,
  FavouriteIcon,
  FilePlusCornerIcon,
  FlashIcon,
  GitPullRequestIcon,
  Globe02Icon,
  HeadphonesIcon,
  Home03Icon,
  LaptopIcon,
  Location01Icon,
  MessageCircleIcon,
  Mic01Icon,
  MusicNote03Icon,
  NextIcon,
  Notification01Icon,
  Package02Icon,
  PackageIcon,
  PauseIcon,
  PencilEdit01Icon,
  PreviousIcon,
  RecordIcon,
  Restaurant02Icon,
  Search01Icon,
  SmartPhone01Icon,
  SparklesIcon,
  StarIcon,
  StopIcon,
  StopWatchIcon,
  Tablet01Icon,
  Tick02Icon,
  Triangle01Icon,
  Video02Icon,
  VolumeHighIcon,
  Wrench01Icon,
} from "@hugeicons/core-free-icons";
import type { IconSvgElement } from "@hugeicons/react";
import { createElement, type CSSProperties, type ReactNode, useId } from "react";

/**
 * islandcn's glyphs: Hugeicons (free set, MIT) drawn for the island. The free set is outline only,
 * which reads thin inside a black pill beside semibold digits and solid controls, so each glyph
 * names how its parts draw: as outlines at an island weight, filled solid, or cut out of a solid
 * part. Media controls, the handsets, the pin, the bolt, the car, the cloud and the message bubble
 * are solid, as the system's own glyphs are at island sizes; tools and devices stay outlines.
 */

/** Props every islandcn glyph takes. */
export interface GlyphDrawingProps {
  /** The glyph's square box in pt. Defaults to 22, the compact glyph. */
  size?: number;
  /** Ink colour. Defaults to `currentColor`, so a button's icon colour carries through. */
  color?: string;
  /** Extra style on the svg. Defaults to none. */
  style?: CSSProperties;
}

/** A glyph component, marked so `Glyph` draws it at its own size rather than scaling it like a foreign icon set. */
export type IslandGlyph = ((props: GlyphDrawingProps) => ReactNode) & {
  readonly islandGlyph: true;
  readonly displayName: string;
  /** The Hugeicons icon it draws (its first layer), for apps that want the same icon elsewhere. Absent on glyphs made by hand. */
  readonly icon?: IconSvgElement;
};

/**
 * How one element of a Hugeicons drawing renders.
 * - "line": an outline at the island weight.
 * - "fill": solid, with no stroke added, so its edge is the icon's own path.
 * - "heavy": solid and outlined at the island weight, for a solid element whose path also carries an
 *   open mark (the stopwatch's side button).
 * - "cut": not drawn, but cut out of the solid elements: a closed shape as a hole, an open mark as a
 *   gap the island weight wide, as a filled symbol's details are.
 * - "gap": drawn as an outline, with a gap cut around it in the solid elements.
 * - "inlay": solid, set into the solid elements with a gap around it, as a car's wheels are.
 */
export type GlyphPart = "line" | "fill" | "heavy" | "cut" | "gap" | "inlay";

/**
 * Where a layer sits on the glyph's 24 unit grid. Outlines keep the glyph's weight however it is
 * scaled or stretched.
 */
export interface GlyphPlacement {
  /** Where the icon's grid centre (12, 12) lands. Defaults to [12, 12]. */
  at?: readonly [number, number];
  /** Scale about that centre. Defaults to 1. */
  scale?: number;
  /** Clockwise turn in degrees about that centre. Defaults to 0. */
  turn?: number;
  /** Mirrors it left to right. Defaults to false. */
  mirror?: boolean;
  /** Stretches its height only, by this factor. Defaults to 1. */
  stretch?: number;
}

/** One Hugeicons icon (or some of its elements) in a glyph. */
export interface GlyphLayer {
  /** The icon, or a subset of its elements. Required. */
  icon: IconSvgElement;
  /** One part for every element, or a list by element index (missing entries are "line"). Defaults to "line". */
  parts?: GlyphPart | readonly GlyphPart[];
  /** Where it sits. Defaults to where the icon draws itself. */
  place?: GlyphPlacement;
}

/** How a glyph draws its Hugeicons icon, and any more layers on top of it. */
export interface GlyphRecipe {
  /** One part for every element of the icon, or a list by element index (missing entries are "line"). Defaults to "line". */
  parts?: GlyphPart | readonly GlyphPart[];
  /** Where the icon sits. Defaults to where it draws itself. */
  place?: GlyphPlacement;
  /** More icons drawn with it; their cuts cut every layer's solids. Defaults to none. */
  layers?: readonly GlyphLayer[];
  /**
   * The window onto the 24 unit grid the box shows, as [x, y, width, height]. Defaults to the whole
   * grid. A smaller window draws the ink larger, for the controls drawn to measured sizes.
   */
  view?: readonly [number, number, number, number];
}

/** Hugeicons draw on a 24 unit grid. */
const grid = 24;

/**
 * The outline weight in grid units. Hugeicons' 1.5 reads hairline in a black pill, so outlines run
 * at 2 units at the 22 pt compact size (1.83 pt, about the island's semibold digit stems). Small
 * glyphs get a little heavier and large ones a little lighter, as type does across sizes:
 * about 2.5 units at 12 pt and 1.6 at 44 pt.
 */
const strokeAt = (size: number) => Math.round(2 * Math.pow(22 / size, 0.35) * 100) / 100;

const partAt = (parts: GlyphLayer["parts"], index: number): GlyphPart => {
  if (parts === undefined) return "line";
  if (typeof parts === "string") return parts;
  return parts[index] ?? "line";
};

/** A closed shape is cut as a hole; an open mark only along its stroke. */
const isClosed = (tag: string, attrs: IconSvgElement[number][1]) => {
  if (tag !== "path") return true;
  const d = attrs.d;
  return typeof d === "string" && /[zZ]\s*$/.test(d);
};

const placement = (place: GlyphPlacement | undefined) => {
  const [x, y] = place?.at ?? [grid / 2, grid / 2];
  const scale = place?.scale ?? 1;
  const stretch = place?.stretch ?? 1;
  const turn = place?.turn ?? 0;
  const sx = scale * (place?.mirror ? -1 : 1);
  const plain = x === grid / 2 && y === grid / 2 && sx === 1 && scale * stretch === 1 && turn === 0;
  return {
    transform: plain ? undefined : `translate(${x} ${y}) scale(${sx} ${scale * stretch}) rotate(${turn}) translate(${-grid / 2} ${-grid / 2})`,
    scale,
    stretched: stretch !== 1,
  };
};

/** Some elements of a Hugeicons icon, by index. */
const pick = (icon: IconSvgElement, ...indexes: readonly number[]): IconSvgElement => indexes.flatMap((index) => icon.slice(index, index + 1));

/** One path as an icon: Hugeicons subpaths joined into a closed outline the free set draws open. */
const pathIcon = (d: string): IconSvgElement => [["path", { d, stroke: "currentColor", strokeLinecap: "round", strokeLinejoin: "round", strokeWidth: "1.5", key: "0" }]];

/**
 * Turns a Hugeicons icon into an islandcn glyph. Exported so an app can draw any of the free set's
 * 4,000+ icons the way the presets draw theirs:
 * `const CartGlyph = glyphFrom("CartGlyph", ShoppingCart01Icon, { parts: "line" })`.
 */
export const glyphFrom = (name: string, icon: IconSvgElement, recipe: GlyphRecipe = {}): IslandGlyph => {
  const [vx, vy, vw, vh] = recipe.view ?? [0, 0, grid, grid];
  const layers = [{ icon, parts: recipe.parts, place: recipe.place }, ...(recipe.layers ?? [])].map((layer) => ({
    icon: layer.icon,
    roles: layer.icon.map((_, index) => partAt(layer.parts, index)),
    ...placement(layer.place),
  }));
  const hasCut = layers.some((layer) => layer.roles.some((role) => role === "cut" || role === "gap" || role === "inlay"));

  const Drawn = ({ size = 22, color = "currentColor", style }: GlyphDrawingProps) => {
    // useId gives colons; mask references want a plain token.
    const id = `icn${useId().replace(/[^a-zA-Z0-9_-]/g, "")}`;
    // A tighter window draws the ink larger, so the weight follows the size the ink is drawn at.
    const line = strokeAt((size * grid) / vw);
    type Pass = "mask" | "fill" | "line" | "inlay";
    const draw = (pass: Pass) =>
      layers.map((layer, layerIndex) => {
        // Widths are glyph units; a scaled layer divides them back out, a stretched one draws them in
        // screen pixels, so every outline and gap keeps one weight.
        const width = (units: number) => (layer.stretched ? (units * size) / vw : units / layer.scale);
        const effect = layer.stretched ? "non-scaling-stroke" : undefined;
        const elements = layer.icon.flatMap(([tag, attrs], index) => {
          const role = layer.roles[index];
          const base = { ...attrs, key: index, vectorEffect: effect, strokeLinecap: "round", strokeLinejoin: "round" } as const;
          switch (pass) {
            case "mask":
              if (role === "cut") {
                const closed = isClosed(tag, attrs);
                return [createElement(tag, { ...base, fill: closed ? "#000" : "none", stroke: "#000", strokeWidth: width(closed ? 0.01 : line) })];
              }
              if (role === "gap") return [createElement(tag, { ...base, fill: "none", stroke: "#000", strokeWidth: width(line * 3) })];
              if (role === "inlay") return [createElement(tag, { ...base, fill: "none", stroke: "#000", strokeWidth: width(line * 2) })];
              return [];
            case "fill":
              if (role === "fill") return [createElement(tag, { ...base, fill: "currentColor", stroke: "none" })];
              if (role === "heavy") return [createElement(tag, { ...base, fill: "currentColor", stroke: "currentColor", strokeWidth: width(line) })];
              return [];
            case "line":
              if (role === "line" || role === "gap") return [createElement(tag, { ...base, fill: "none", stroke: "currentColor", strokeWidth: width(line) })];
              return [];
            case "inlay":
              if (role === "inlay") return [createElement(tag, { ...base, fill: "currentColor", stroke: "none" })];
              return [];
            default: {
              const exhaustive: never = pass;
              return exhaustive;
            }
          }
        });
        return elements.length === 0 ? null : (
          <g key={layerIndex} transform={layer.transform}>
            {elements}
          </g>
        );
      });
    return (
      <svg
        aria-hidden
        width={size}
        height={size}
        viewBox={`${vx} ${vy} ${vw} ${vh}`}
        fill="none"
        strokeLinecap="round"
        strokeLinejoin="round"
        style={{ display: "block", flex: "none", color, overflow: "visible", ...style }}
      >
        {hasCut ? (
          <mask id={`${id}-cut`} maskUnits="userSpaceOnUse" x={-grid} y={-grid} width={grid * 3} height={grid * 3}>
            <rect x={-grid} y={-grid} width={grid * 3} height={grid * 3} fill="#fff" />
            {draw("mask")}
          </mask>
        ) : null}
        <g mask={hasCut ? `url(#${id}-cut)` : undefined}>{draw("fill")}</g>
        {draw("line")}
        {draw("inlay")}
      </svg>
    );
  };
  return Object.assign(Drawn, { islandGlyph: true as const, displayName: name, icon });
};

/** A square window centred on the grid that draws `inkUnits` of ink at `share` of the box: the transport row's glyphs are drawn to measured ink sizes. */
const centredView = (inkUnits: number, share: number): readonly [number, number, number, number] => {
  const side = Math.round((inkUnits / share) * 100) / 100;
  const start = Math.round((grid / 2 - side / 2) * 100) / 100;
  return [start, start, side, side];
};

// Timing and media

/** A stopwatch, solid, its hand cut out. */
export const TimerGlyph = glyphFrom("TimerGlyph", StopWatchIcon, { parts: ["heavy", "line", "cut"] });

/**
 * The play triangle: Triangle01's outline turned to point right and scaled to Pause's 16 unit
 * height (its outline spans 19.9 units across), set 1.2 units right of centre so it looks centred
 * beside Pause, as a play button's triangle sits. Hugeicons' own Play is a rounded blob.
 */
const playPlace = { at: [12.4, 12], scale: 0.8, turn: 90 } as const satisfies GlyphPlacement;

export const PlayGlyph = glyphFrom("PlayGlyph", pick(Triangle01Icon, 0), { parts: "fill", place: playPlace });

export const PauseGlyph = glyphFrom("PauseGlyph", PauseIcon, { parts: "fill" });

export const StopGlyph = glyphFrom("StopGlyph", StopIcon, { parts: "fill" });

export const CloseGlyph = glyphFrom("CloseGlyph", Cancel01Icon);

/** Skip to the next track: a solid triangle against a bar. ForwardGlyph is for seeking. */
export const NextTrackGlyph = glyphFrom("NextTrackGlyph", NextIcon, { parts: ["fill", "line"] });

/** Back to the previous track: a bar against a solid triangle. BackwardGlyph is for seeking. */
export const PreviousTrackGlyph = glyphFrom("PreviousTrackGlyph", PreviousIcon, { parts: ["fill", "line"] });

/** Seek forward: two solid triangles, the first one's tip against the second one's back. */
export const ForwardGlyph = glyphFrom("ForwardGlyph", FastForwardIcon, { parts: "fill" });

/** Seek back: `ForwardGlyph` mirrored. The free set's Rewind has rounded lobes that read as blobs. */
export const BackwardGlyph = glyphFrom("BackwardGlyph", FastForwardIcon, { parts: "fill", place: { mirror: true } });

/** Two beamed notes: solid heads on outline stems, so the heads stay apart. */
export const MusicGlyph = glyphFrom("MusicGlyph", MusicNote03Icon, { parts: ["fill", "fill", "line", "line"] });

/*
 * The music player's transport row, drawn for one box size each so the expanded now-playing row
 * keeps its measured ink: PlayerPause and PlayerPlay at 30 pt are about 27.6 pt tall, PlayerBack
 * and PlayerForward at 34 pt about 31.5 pt wide, AudioOutput at 27.5 pt about 21 pt wide. They
 * stay out of `islandGlyphs`: that set is for any size, and these are drawn for one.
 */

/** Pause's bars span 4 to 20 units, and the play triangle is scaled to the same height, so they share one window. */
const playerView = centredView(16, 27.6 / 30);

export const PlayerPauseGlyph = glyphFrom("PlayerPauseGlyph", PauseIcon, { parts: "fill", view: playerView });

export const PlayerPlayGlyph = glyphFrom("PlayerPlayGlyph", pick(Triangle01Icon, 0), { parts: "fill", place: playPlace, view: playerView });

/** FastForward spans 3.25 to 20.75 units, centred. */
const skipView = centredView(17.5, 31.5 / 34);

/** Next track: two solid triangles, the first one's tip against the second one's back. */
export const PlayerForwardGlyph = glyphFrom("PlayerForwardGlyph", FastForwardIcon, { parts: "fill", view: skipView });

/** Previous track: `PlayerForwardGlyph` mirrored. */
export const PlayerBackGlyph = glyphFrom("PlayerBackGlyph", FastForwardIcon, { parts: "fill", place: { mirror: true }, view: skipView });

/**
 * Where the sound plays: a solid speaker with two sound waves, stretched 1.35 times taller about the
 * speaker's middle (to 13.5 units, near the old drawing's measured height) without thickening them.
 * The icon spans 2 to 22 units across.
 */
export const AudioOutputGlyph = glyphFrom("AudioOutputGlyph", pick(VolumeHighIcon, 0), {
  parts: "fill",
  layers: [{ icon: pick(VolumeHighIcon, 1, 2), place: { stretch: 1.35 } }],
  view: centredView(21, 21 / 27.5),
});

// Calls

/** A handset held to the ear, solid. */
export const PhoneGlyph = glyphFrom("PhoneGlyph", Call02Icon, { parts: "fill" });

/**
 * A handset put down, for ending or declining a call: CallEnd02's handset without its arrow, moved
 * down to the centre. Its grip is an open arc between the pads, so it is "heavy": filled, with the
 * grip drawn at the island weight.
 */
export const HangUpGlyph = glyphFrom("HangUpGlyph", pick(CallEnd02Icon, 0), { parts: "heavy", place: { at: [12, 16] } });

// Status

export const CheckGlyph = glyphFrom("CheckGlyph", Tick02Icon);

export const CheckCircleGlyph = glyphFrom("CheckCircleGlyph", CheckmarkCircle02Icon);

export const WarningGlyph = glyphFrom("WarningGlyph", Alert02Icon);

export const BellGlyph = glyphFrom("BellGlyph", Notification01Icon);

/** A round speech bubble, solid. */
export const MessageGlyph = glyphFrom("MessageGlyph", MessageCircleIcon, { parts: "fill" });

// Transfer and files

/**
 * Cloud's outline is two open subpaths (the lobes and the dome) with two inner strokes; these are
 * the outer two joined, the dome reversed, into one closed contour that can fill.
 */
const cloudContour = pathIcon(
  "M17.4776 10.0001C17.485 10 17.4925 17.5 10C19.9853 22 12.0147 14.5C22 16.9853 19.9853 19 19H7C4.23858 2 16.7614 14C2 11.4003 3.98398 9.26407 6.52042 9.0227C6.76233 6.20862 9.12324 4 12 4C15.0376 6.46243 9.5C17.5 9.66856 17.4924 9.83536 17.4776 10.0001Z",
);

/** A solid cloud with an arrow up cut out of it: ArrowUp02 at 0.55, low in the cloud. */
export const UploadGlyph = glyphFrom("UploadGlyph", cloudContour, {
  parts: "fill",
  layers: [{ icon: ArrowUp02Icon, parts: "cut", place: { at: [12, 13.6], scale: 0.55 } }],
});

export const ArrowUpGlyph = glyphFrom("ArrowUpGlyph", ArrowUp02Icon);

/** A page with its corner folded and a plus at the foot. */
export const DocumentPlusGlyph = glyphFrom("DocumentPlusGlyph", FilePlusCornerIcon);

export const PackageGlyph = glyphFrom("PackageGlyph", PackageIcon);

/** Downloading: an arrow into a tray. */
export const DownloadGlyph = glyphFrom("DownloadGlyph", Download01Icon);

// Tools

export const TerminalGlyph = glyphFrom("TerminalGlyph", ComputerTerminal01Icon);

/** A pencil, without PencilEdit01's underline. */
export const PencilGlyph = glyphFrom("PencilGlyph", pick(PencilEdit01Icon, 0));

export const SearchGlyph = glyphFrom("SearchGlyph", Search01Icon);

export const GlobeGlyph = glyphFrom("GlobeGlyph", Globe02Icon);

/** A spanner, solid. */
export const WrenchGlyph = glyphFrom("WrenchGlyph", Wrench01Icon, { parts: "fill" });

export const GitMergeRequestGlyph = glyphFrom("GitMergeRequestGlyph", GitPullRequestIcon);

/** Four-point sparkles, solid. */
export const SparkleGlyph = glyphFrom("SparkleGlyph", SparklesIcon, { parts: "fill" });

// Recording

/** A solid capsule on an outline stand. */
export const MicrophoneGlyph = glyphFrom("MicrophoneGlyph", Mic01Icon, { parts: ["fill", "line"] });

/** A screen with a solid recording dot in it: Computer's outline, and Record at 0.3 in the middle of the screen. */
export const ScreenRecordGlyph = glyphFrom("ScreenRecordGlyph", ComputerIcon, {
  layers: [{ icon: RecordIcon, parts: "fill", place: { at: [12, 10], scale: 0.3 } }],
});

/** A solid camera body and lens, the viewfinder mark cut out. */
export const VideoGlyph = glyphFrom("VideoGlyph", Video02Icon, { parts: ["cut", "fill", "fill"] });

/** A solid recording dot. */
export const RecordGlyph = glyphFrom("RecordGlyph", RecordIcon, { parts: "fill" });

export const HeadphonesGlyph = glyphFrom("HeadphonesGlyph", HeadphonesIcon);

// Travel

/**
 * Car03's body is one path of open strokes, the window line among them; these are its outline
 * strokes joined, the rear edge reversed, into one closed body that can fill. The roof starts where
 * the rear edge's curve does, so the join leaves no spike.
 */
const carBody = pathIcon(
  "M3.9 5H12.2394C12.2394 5 12.779 13.2586 5.048C14.158 5.132 14.9134 5.54 15.6688 6.56C16.4687 7.64 17.0837 9.008 17.8991 9.74C19.2541 10.9564 21.8321 10.58 21.976 13.16C22.012 14.48 22.012 15.92 21.952 16.16C21.8557 16.8667 21.3108 16.9821 20.633 17C20.0448 17.0156 19.3357 16.9721 18.9903 17L5.00893 17C2.1671 16.58 2.04719 15.98 2.01122 15.26C1.98723 13.04 2.00722 10.78 10C2.22306 8.26 3.16234 6.2 3.64197 5.42Z",
);

/**
 * The two windows as holes: the regions Car03's roof, rear edge, windshield, window line (y 10) and
 * pillar (x 9) enclose, each drawn 1.4 units in from them so the body keeps an even rim.
 */
const carWindows = pathIcon("M4.4 6.4H7.9V8.6H3.6Z M10.1 6.4H13.3C14.2 6.6 14.9 7.4 15.8 8.6H10.1Z");

/** A car in profile, solid: Car03's body filled, its windows cut out, and its wheels set in with a gap. */
export const CarGlyph = glyphFrom("CarGlyph", carBody, {
  parts: "fill",
  layers: [
    { icon: carWindows, parts: "cut" },
    { icon: pick(Car03Icon, 0, 1), parts: "inlay" },
  ],
});

/** A map pin, solid, with a round hole. */
export const PinGlyph = glyphFrom("PinGlyph", Location01Icon, { parts: ["fill", "cut"] });

/** A house with its door, both outlines. */
export const HouseGlyph = glyphFrom("HouseGlyph", Home03Icon);

/** A parcel, solid: Package02's box filled, its lid seam, tape and label cut out. */
export const ParcelGlyph = glyphFrom("ParcelGlyph", Package02Icon, { parts: ["cut", "fill", "cut", "cut", "cut"] });

export const BicycleGlyph = glyphFrom("BicycleGlyph", Bicycle01Icon);

/** An airliner, solid. */
export const AirplaneGlyph = glyphFrom("AirplaneGlyph", Airplane01Icon, { parts: "fill" });

// Food

export const CoffeeGlyph = glyphFrom("CoffeeGlyph", Coffee02Icon);

export const ForkKnifeGlyph = glyphFrom("ForkKnifeGlyph", Restaurant02Icon);

// Devices

export const PhoneDeviceGlyph = glyphFrom("PhoneDeviceGlyph", SmartPhone01Icon);

export const TabletGlyph = glyphFrom("TabletGlyph", Tablet01Icon);

/** A laptop: the screen an outline on a solid base. */
export const LaptopGlyph = glyphFrom("LaptopGlyph", LaptopIcon, { parts: ["line", "fill"] });

export const DesktopGlyph = glyphFrom("DesktopGlyph", ComputerIcon);

// Power, time and other marks

export const BoltGlyph = glyphFrom("BoltGlyph", FlashIcon, { parts: "fill" });

export const BatteryChargingGlyph = glyphFrom("BatteryChargingGlyph", BatteryCharging01Icon);

export const AlarmGlyph = glyphFrom("AlarmGlyph", AlarmClockIcon);

/** A heart, solid. */
export const HeartGlyph = glyphFrom("HeartGlyph", FavouriteIcon, { parts: "fill" });

/** A five-point star, solid, as a rating draws it. */
export const StarGlyph = glyphFrom("StarGlyph", StarIcon, { parts: "fill" });

/** Every glyph by name, for the quality probe and for apps that pick one at run time. */
export const islandGlyphs = {
  timer: TimerGlyph,
  play: PlayGlyph,
  pause: PauseGlyph,
  stop: StopGlyph,
  close: CloseGlyph,
  nextTrack: NextTrackGlyph,
  previousTrack: PreviousTrackGlyph,
  forward: ForwardGlyph,
  backward: BackwardGlyph,
  music: MusicGlyph,
  phone: PhoneGlyph,
  hangUp: HangUpGlyph,
  check: CheckGlyph,
  checkCircle: CheckCircleGlyph,
  warning: WarningGlyph,
  bell: BellGlyph,
  message: MessageGlyph,
  upload: UploadGlyph,
  arrowUp: ArrowUpGlyph,
  documentPlus: DocumentPlusGlyph,
  package: PackageGlyph,
  download: DownloadGlyph,
  terminal: TerminalGlyph,
  pencil: PencilGlyph,
  search: SearchGlyph,
  globe: GlobeGlyph,
  wrench: WrenchGlyph,
  mergeRequest: GitMergeRequestGlyph,
  sparkle: SparkleGlyph,
  microphone: MicrophoneGlyph,
  screenRecord: ScreenRecordGlyph,
  video: VideoGlyph,
  record: RecordGlyph,
  headphones: HeadphonesGlyph,
  car: CarGlyph,
  pin: PinGlyph,
  house: HouseGlyph,
  parcel: ParcelGlyph,
  bicycle: BicycleGlyph,
  airplane: AirplaneGlyph,
  coffee: CoffeeGlyph,
  forkKnife: ForkKnifeGlyph,
  phoneDevice: PhoneDeviceGlyph,
  tablet: TabletGlyph,
  laptop: LaptopGlyph,
  desktop: DesktopGlyph,
  bolt: BoltGlyph,
  batteryCharging: BatteryChargingGlyph,
  alarm: AlarmGlyph,
  heart: HeartGlyph,
  star: StarGlyph,
} as const satisfies Record<string, IslandGlyph>;

export type IslandGlyphName = keyof typeof islandGlyphs;
