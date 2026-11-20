"use client";

import type { CSSProperties } from "react";

import { islandMetrics } from "@/lib/island";

import { Artwork, artworkColors } from "./artwork";
import { AudioOutputGlyph, PlayerBackGlyph, PlayerForwardGlyph, PlayerPauseGlyph, PlayerPlayGlyph } from "./glyphs";
import { IslandRoundButton } from "./island-button";
import { ExpandedBottom } from "./island-layout";
import { ExpandedSubtitle, ExpandedTitle, MinimalPair, tabularFigures } from "./island-text";
import { LevelMeter } from "./level-meter";
import { TimeProgress } from "./linear-progress";
import { islandFont, islandInk } from "./theme";
import { formatClock, TickingTime } from "./ticking-time";
import { useActivity, useLatest } from "./use-activity";

/**
 * The expanded player, measured on a music player's expanded island (371 pt wide, horizontal
 * positions scaled to the engine's 374.34). Positions are in pt from the engine's content box
 * (18.18 below the island's top, 18.5 in from its leading edge, 17.81 from its trailing one)
 * unless they say otherwise.
 */
const player = {
  /** Cover art: 59.5 pt with continuous corners of about 14, 21.7 from the leading edge and 21.9 from the top. */
  art: 59.5,
  artRadius: 14,
  artInset: { x: 3.2, y: 3.72 },
  /** Title and artist: both 16 pt, the title semibold white and the artist regular grey. */
  textSize: 16,
  textLine: 20,
  /** The title starts 98 pt from the island's leading edge, 16.6 after the art. */
  textInset: 4.8,
  /**
   * The title's baseline sits 47.3 pt below the island's top, 9.05 below where the engine starts
   * the center region; a 16 pt line 20 tall puts its baseline about 15.5 down, so the stack rises
   * by the difference, less 1.5: the engine draws the sensor over content, and at the measured
   * height its bottom edge (36.9 below the top) trimmed the ascenders of a title running under it. The artist's baseline is 17.1 below the title's: the second line's box
   * overlaps the first by 3.8, which measures 17.1 in Chrome (its baseline lands 0.9 lower than
   * the line heights alone say).
   */
  textLift: -5.1,
  artistGap: 16.2 - 20,
  /** Level meter: six bars 2.4 wide and 1.9 apart, 20 tall, 26 pt from the trailing edge, centred 36.3 below the top. */
  meter: { bars: 6, barWidth: 2.4, gap: 1.9, height: 20, right: 8.2, top: 8.3 },
  /**
   * Time row, centred 102.7 below the island's top: 11 pt grey figures at the ends of a 6 pt
   * capsule, from 22.4 pt in on the leading side to 24 on the trailing one, the bar from 55.4 to 60.
   */
  timeSize: 11,
  timeLine: 14,
  timeTop: 6.3,
  timeInset: { start: 3.9, end: 5.2 },
  elapsedColumn: 33,
  remainingColumn: 36,
  timeGap: 8,
  bar: 6,
  /** The unfilled bar: white at 20% (#333 on black). */
  track: "rgba(255, 255, 0.2)",
  /** The artist and the times: the player's own neutral grey, without the kit's blue cast. */
  grey: "#898989",
  /** The meter's shape: a distinct peak in the second bar, as the player's meter draws it. */
  meterEnvelope: [0.5, 1, 0.7, 0.4, 0.6, 0.35],
  /**
   * Transport row: the pause centred on the island at 142 pt below its top (143.1 on a 182.5 pt
   * island; the engine stops at 180), back and forward 73.5 either side, the output button's
   * centre 40.2 from the trailing edge. 36 pt buttons, whose touch areas still reach 44.
   */
  rowGap: 16.3,
  button: 36,
  skipOffset: 73.5,
  outputCenter: 40.2 - (islandMetrics.expanded.padding.trailing ?? islandMetrics.expanded.padding.side),
  /** Room under the row: none, the 2 pt went into `rowGap` so the controls sit as low as the 180 pt cap allows. */
  bottomPad: 0,
  glyph: { pause: 30, skip: 34, output: 27.5 },
} as const satisfies Record<string, unknown>;

/**
 * Lets the title stack take the whole center column, so it starts beside the art. The engine
 * centres the center region's content at its own width; a width wider than any island makes the
 * engine give the side columns their own widths and this box the rest (capped at the column).
 */
const fillCenter = { width: 640, maxWidth: "100%" } as const satisfies CSSProperties;

/** The bottom region spans the content box, which sits 0.35 pt right of the island's centre line. */
const centreShift = ((islandMetrics.expanded.padding.trailing ?? islandMetrics.expanded.padding.side) - islandMetrics.expanded.padding.side) / 2;

const timeText = {
  ...tabularFigures,
  display: "block",
  fontFamily: islandFont,
  fontSize: player.timeSize,
  fontWeight: 400,
  lineHeight: `${player.timeLine}px`,
  color: player.grey,
  whiteSpace: "nowrap",
  WebkitFontSmoothing: "antialiased",
} as const satisfies CSSProperties;

/** A transport button centred `offset` pt from the island's centre line. */
const transportSlot = (offset: number): CSSProperties => ({
  position: "absolute",
  top: 0,
  left: `calc(50% + ${offset + centreShift - player.button / 2}px)`,
});

/** Playing from a moment (epoch ms when the track would have started), or paused at a position. */
export type PlaybackState = { kind: "playing"; startedAt: number } | { kind: "paused"; position: number };

/** The expanded cover: 59.5 pt with the player's corner, set a few points further in than the content box. */
export const PlayerCover = ({ seed, src }: {
  /** Text the generated cover is drawn from, such as the title and artist. */
  seed: string;
  /** Cover image. Defaults to the generated cover. */
  src?: string;
}) => (
  <div style={{ paddingLeft: player.artInset.x, paddingTop: player.artInset.y }}>
    <Artwork seed={seed} src={src} size={player.art} radius={player.artRadius} />
  </div>
);

/**
 * The title and artist, both 16 pt, starting right after the cover and centred on it: the stack
 * rises from where the engine starts the center region until its baselines sit where the player's do.
 */
export const PlayerTitle = ({ title, artist }: {
  /** The track, semibold white. */
  title: string;
  /** The artist, regular grey. */
  artist: string;
}) => {
  const text = { fontSize: player.textSize, lineHeight: `${player.textLine}px`, letterSpacing: 0 } as const satisfies CSSProperties;
  return (
    <div style={{ ...fillCenter, display: "grid", minWidth: 0, textAlign: "left", paddingLeft: player.textInset, marginTop: player.textLift }}>
      <ExpandedTitle style={text}>{title}</ExpandedTitle>
      <ExpandedSubtitle color={player.grey} style={{ ...text, marginTop: player.artistGap }}>{artist}</ExpandedSubtitle>
    </div>
  );
};

/**
 * The player's level meter: six bars 2.4 wide and 1.9 apart. "expanded" sits in the top corner at
 * 20 pt, "compact" is 17 pt tall in the pill, "minimal" keeps four bars for the split's bubble.
 */
export const PlayerMeter = ({ color, active = true, size }: {
  /** Bar colour. */
  color: string;
  /** Moves while true. Defaults to true. */
  active?: boolean;
  /** Where it sits. */
  size: "compact" | "minimal" | "expanded";
}) => {
  if (size !== "expanded") {
    // 17 pt in the 36.85 pt pill (a call's compact meter is 17.3), as wide as the art.
    return <LevelMeter bars={size === "compact" ? player.meter.bars : 4} color={color} height={17} barWidth={player.meter.barWidth} gap={player.meter.gap} active={active} />;
  }
  return (
    <div style={{ paddingRight: player.meter.right, paddingTop: player.meter.top }}>
      <LevelMeter bars={player.meter.bars} color={color} height={player.meter.height} barWidth={player.meter.barWidth} gap={player.meter.gap} active={active} envelope={player.meterEnvelope} />
    </div>
  );
};

/**
 * The expanded player's bottom: the elapsed and remaining times at the ends of a white scrubber,
 * then the transport row placed by centre, with the output button at its end. A button shows when
 * its handler is set; with none, the time row is the last row.
 */
export const PlayerControls = ({ playback, duration, onToggle, onPrevious, onNext, onOutput }: {
  /** Where playback is. */
  playback: PlaybackState;
  /** Track length in ms. */
  duration: number;
  /** Play or pause button; shown when set. Defaults to none. */
  onToggle?: () => void;
  /** Previous track button; shown when set. Defaults to none. */
  onPrevious?: () => void;
  /** Next track button; shown when set. Defaults to none. */
  onNext?: () => void;
  /** Audio output button at the row's trailing end; shown when set. Defaults to none. */
  onOutput?: () => void;
}) => {
  const playing = playback.kind === "playing";
  const elapsed = playing ? <TickingTime source={{ kind: "elapsed", since: playback.startedAt }} /> : <TickingTime source={{ kind: "fixed", ms: playback.position }} />;
  // A real minus sign (U+2212): a hyphen in tabular figures is a digit wide, which leaves a gap after it.
  const remaining = playing ? (
    <TickingTime source={{ kind: "remaining", until: playback.startedAt + duration }} format={(ms) => `\u2212${formatClock(ms)}`} />
  ) : (
    <TickingTime source={{ kind: "fixed", ms: duration - playback.position }} format={(ms) => `\u2212${formatClock(ms)}`} />
  );
  const anyControl = onToggle !== undefined || onPrevious !== undefined || onNext !== undefined || onOutput !== undefined;
  return (
    // With no buttons under it, the time row is the last one and its ends sit in the corner arcs,
    // which cut the last digit of the remaining time: pull it in until they clear.
    <ExpandedBottom gap={player.rowGap} reach={anyControl ? "none" : "inset"} style={{ paddingTop: player.timeTop, paddingBottom: anyControl ? player.bottomPad : 0 }}>
      <div
        style={{
          display: "grid",
          gridTemplateColumns: `minmax(${player.elapsedColumn}px, max-content) minmax(0, 1fr) minmax(${player.remainingColumn}px, max-content)`,
          alignItems: "center",
          paddingLeft: anyControl ? player.timeInset.start : 0,
          paddingRight: anyControl ? player.timeInset.end : 0,
        }}
      >
        <span style={{ ...timeText, paddingRight: player.timeGap }}>{elapsed}</span>
        <TimeProgress
          source={playing ? { kind: "elapsed", since: playback.startedAt } : { kind: "fixed", ms: playback.position }}
          duration={duration}
          color={islandInk.primary}
          track={player.track}
          height={player.bar}
          ends="square"
        />
        <span style={{ ...timeText, paddingLeft: player.timeGap, textAlign: "right" }}>{remaining}</span>
      </div>
      {anyControl ? (
        // Placed by their centres, not by flex gaps, so the pause stays on the island's centre
        // line whichever buttons are there.
        <div style={{ position: "relative", height: player.button }}>
          {onPrevious === undefined ? null : (
            <span style={transportSlot(-player.skipOffset)}>
              <IslandRoundButton label="Previous track" color="transparent" size={player.button} onPress={onPrevious}>
                <PlayerBackGlyph size={player.glyph.skip} />
              </IslandRoundButton>
            </span>
          )}
          {onToggle === undefined ? null : (
            <span style={transportSlot(0)}>
              <IslandRoundButton label={playing ? "Pause" : "Play"} color="transparent" size={player.button} onPress={onToggle}>
                {playing ? <PlayerPauseGlyph size={player.glyph.pause} /> : <PlayerPlayGlyph size={player.glyph.pause} />}
              </IslandRoundButton>
            </span>
          )}
          {onNext === undefined ? null : (
            <span style={transportSlot(player.skipOffset)}>
              <IslandRoundButton label="Next track" color="transparent" size={player.button} onPress={onNext}>
                <PlayerForwardGlyph size={player.glyph.skip} />
              </IslandRoundButton>
            </span>
          )}
          {onOutput === undefined ? null : (
            <span style={{ position: "absolute", top: 0, right: player.outputCenter - player.button / 2 }}>
              <IslandRoundButton label="Audio output" color="transparent" size={player.button} onPress={onOutput}>
                <AudioOutputGlyph size={player.glyph.output} />
              </IslandRoundButton>
            </span>
          )}
        </div>
      ) : null}
    </ExpandedBottom>
  );
};

export interface NowPlayingActivityProps {
  /** Activity id. Defaults to "now-playing". */
  id?: string;
  /** Higher priority takes the main pill when two activities run. Defaults to 0. */
  priority?: number;
  title: string;
  artist: string;
  /** Track length in ms. */
  duration: number;
  playback: PlaybackState;
  /** Cover image. Defaults to a gradient generated from the title and artist. */
  artwork?: string;
  /** Accent for the level meter. Defaults to a colour taken from the generated art. */
  accent?: string;
  /** Play or pause button; shown when set. Defaults to none. */
  onToggle?: () => void;
  /** Previous track button; shown when set. Defaults to none. */
  onPrevious?: () => void;
  /** Next track button; shown when set. Defaults to none. */
  onNext?: () => void;
  /** Audio output button at the trailing end of the transport row, to pick where the sound plays; shown when set. Defaults to none. */
  onOutput?: () => void;
}

/**
 * Now playing. Compact shows the art and a level meter tinted from it; expanded shows the art
 * with the title and artist beside it, the meter at the top corner, a white scrubber between the
 * elapsed and remaining times, and the transport row with an output button at its end.
 */
export const NowPlayingActivity = ({
  id = "now-playing", priority = 0,
  title,
  artist,
  duration,
  playback,
  artwork,
  accent,
  onToggle,
  onPrevious,
  onNext,
  onOutput,
}: NowPlayingActivityProps) => {
  const handlers = useLatest({ onToggle, onPrevious, onNext, onOutput });
  const controls = { toggle: onToggle !== undefined, previous: onPrevious !== undefined, next: onNext !== undefined, output: onOutput !== undefined };
  const playbackKey = playback.kind === "playing" ? `p${playback.startedAt}` : `s${playback.position}`;

  useActivity(() => {
    const seed = `${title} ${artist}`;
    const tone = accent ?? artworkColors(seed).accent;
    const playing = playback.kind === "playing";
    const art = <Artwork seed={seed} src={artwork} size={22} radius={6} />;
    // Read when pressed, so a new callback each render never rebuilds the content.
    const press = (handler: "onToggle" | "onPrevious" | "onNext" | "onOutput", shown: boolean) => (shown ? () => handlers.current[handler]?.() : undefined);
    return {
      id,
      priority,
      label: playing ? `Playing ${title} by ${artist}` : `Paused: ${title} by ${artist}`,
      compact: {
        leading: art,
        trailing: <PlayerMeter color={tone} size="compact" active={playing} />,
      },
      minimal: <MinimalPair leading={art} trailing={<PlayerMeter color={tone} size="minimal" active={playing} />} />,
      expanded: {
        leading: <PlayerCover seed={seed} src={artwork} />,
        center: <PlayerTitle title={title} artist={artist} />,
        trailing: <PlayerMeter color={tone} size="expanded" active={playing} />,
        bottom: (
          <PlayerControls
            playback={playback}
            duration={duration}
            onToggle={press("onToggle", controls.toggle)}
            onPrevious={press("onPrevious", controls.previous)}
            onNext={press("onNext", controls.next)}
            onOutput={press("onOutput", controls.output)}
          />
        ),
      },
    };
  }, [id, priority, title, artist, duration, playbackKey, artwork, accent, controls.toggle, controls.previous, controls.next, controls.output]);

  return null;
};
