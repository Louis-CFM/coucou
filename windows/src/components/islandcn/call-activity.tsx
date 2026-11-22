"use client";

import { type CSSProperties, type ReactNode, useEffect, useRef } from "react";

import { islandMetrics } from "@/lib/island/index";

import { Avatar } from "./avatar";
import { Glyph } from "./glyph";
import { IslandStyle } from "./island-style";
import { HangUpGlyph, PhoneGlyph } from "./glyphs";
import { IslandRoundButton } from "./island-button";
import { CompactText, ExpandedSubtitle, ExpandedTitle, MinimalPair, withBubble } from "./island-text";
import { LevelMeter } from "./level-meter";
import { islandAccent, islandInk } from "./theme";
import { TickingTime } from "./ticking-time";
import { useActivity, useLatest } from "./use-activity";

/** Ringing until answered, then active with a start time. */
export type CallState = { kind: "ringing" } | { kind: "active"; since: number };

/** The voice meter's shape: two broad lobes, as a call's level meter draws a voice, not a row of even dashes. */
const voiceEnvelope = [0.2, 0.55, 0.9, 1, 0.85, 0.65, 0.4, 0.35, 0.65, 0.85, 1, 0.95, 0.75, 0.45] as const;

export interface CallActivityProps {
  /** Activity id. Defaults to "call". */
  id?: string;
  /** Higher priority takes the main pill when two activities run. Defaults to 2. */
  priority?: number;
  /** Who is calling. */
  caller: string;
  /** The small grey line above the name while ringing: the kind of call, such as "mobile" or "Video call". Defaults to "Audio call". */
  subtitle?: string;
  /**
   * The caller's contact photo, an image src: whatever picture the contact is saved with, a face or
   * a pet. Shows in the 50 pt circle while ringing and the 22 pt one in compact. Defaults to the
   * caller's initials on a dusky disc, which also show while the photo loads.
   */
  avatar?: string;
  state: CallState;
  /** Accept button while ringing. */
  onAccept: () => void;
  /** Decline while ringing, end while active. */
  onDecline: () => void;
}

/** The call buttons' fills, measured on a phone's incoming call (#fe4345 and #31d259). */
const red = "#fe4345";
const green = "#31d259";
/**
 * The call's glyphs and time on the island itself, lighter than the accept button: measured on the
 * answered compact, where the time is #76fb73, the meter's green bars #7afd74 and the handset
 * #6cf16a. The button green there read dull and dark. While it still rings, the compact phone keeps
 * the accept button's green, the button it stands for.
 */
const talkGreen = "#76fb73";
/** The answered meter: a green half and an orange half, each bar with a pale core. */
const meterTones = { near: talkGreen, far: islandAccent.orange, core: "#fffde0" } as const satisfies Record<string, string>;

const expanded = islandMetrics.expanded;
const trailingPad = expanded.padding.trailing ?? expanded.padding.side;

/**
 * The incoming call, measured on a phone's 3x capture (84 pt island, 371 pt wide; horizontal
 * positions scaled to the engine's 374.34). Insets are in pt from the island's edges, rows from
 * its top.
 */
const call = {
  /** The island stays at its shortest, 84 pt: the row must fit the content box (84 less 36.53). */
  row: 47,
  /** Avatar: 50 pt, 16.3 from the leading edge, centred 41.8 below the top. */
  avatar: 50,
  avatarInset: 16.3,
  /** Decline and accept: 50 pt circles 10.1 apart (10.5 here, so the pair spans the measured 110.9), the accept 16.1 from the trailing edge. */
  button: 50,
  buttonGap: 10.5,
  buttonInset: 16.1,
  /** Handset glyph boxes: the decline's handset is 25.7 pt across, the accept's 20 by 20. */
  handset: 28,
  /**
   * The grey line is 14 pt regular, its baseline 48.2 below the top; the name 17 pt semibold, its
   * baseline 68.3. Both start 76.5 from the leading edge, 10 after the avatar. Here they sit 1 and
   * 2.5 pt higher (47.7 and 66.2): the engine clips content 13.5 pt inside an 84 pt island's bottom
   * edge (at 70.5), which cut a name's descenders ("y", "q") at the measured baseline.
   */
  labelSize: 14,
  labelLine: 18,
  labelLift: -4.5,
  nameLift: -2,
  textInset: -1.4,
  /** The center column's box: the text overflows it downward without making the island taller. */
  textBox: 27,
} as const satisfies Record<string, number>;

/**
 * The answered compact, measured against the pill's 36.85 pt height: a 14 pt handset and the time
 * 5.2 after its ink (the 18 pt box has 2.25 of air each side), a 14-bar meter 2.25 wide and 1.13
 * apart, 17.3 tall, its end 9.8 from the pill's (2.8 more than the engine's trailing padding).
 */
const compactCall = { handset: 18, gap: 2.5, bars: 14, barWidth: 2.25, barGap: 1.13, height: 17.3, meterInset: 2.8, side: 66 } as const satisfies Record<string, number>;

/**
 * The answered pill is 241 pt wide on the reference, the time and the meter each in a side about 73
 * pt out from the sensor, with air between them and it. Sized to their content the sides made a
 * 209 pt pill that read as a smaller, different thing. Each side is `compactCall.side` wide (66, plus
 * the engine's 7.18 edge padding) in the compact pill only: in the split's pills the same content
 * keeps its own width, so the split still fits its pair beside the bubble.
 */
const answeredCss = `
.icn-call-side { display: flex; align-items: center; }
[data-slot="leading"] .icn-call-side, [data-slot="trailing"] .icn-call-side { width: ${compactCall.side}px; }
[data-slot="trailing"] .icn-call-side { justify-content: flex-end; }
`;

/**
 * Lets the text take the whole center column, so it starts beside the avatar. The engine centres
 * the center region's content at its own width; a width wider than any island makes it give the
 * side columns their own widths and this box the rest (capped at the column).
 */
const fillCenter = { width: 640, maxWidth: "100%" } as const satisfies CSSProperties;

/** The call buttons' measured fills, for islands that draw their own call buttons. */
export const callColors = { decline: red, accept: green } as const satisfies Record<string, string>;

/** The call buttons' size and their handset glyphs' box, in pt. */
export const callButton = { size: call.button, handset: call.handset } as const satisfies Record<string, number>;

/**
 * The 50 pt caller photo, out toward the corner as the system sets it. The row is no taller than
 * the content box of an 84 pt island; the photo overflows it by 1.5 pt each way, as it reaches past
 * the engine's padding on the reference.
 */
export const CallAvatar = ({ name, src }: {
  /** Whose initials and colour, when there is no photo. */
  name: string;
  /** Photo. Defaults to initials. */
  src?: string;
}) => (
  <div style={{ display: "flex", alignItems: "center", height: call.row, marginLeft: call.avatarInset - expanded.padding.side }}>
    <Avatar name={name} src={src} size={call.avatar} />
  </div>
);

/**
 * The 14 pt grey line over the 17 pt name, starting right after the photo, in a box that ends
 * inside the row so the name's line below it doesn't make the island taller.
 */
export const CallText = ({ line, name, lineColor = islandInk.secondary }: {
  /** The line above the name: the kind of call, or the call time once answered. */
  line: ReactNode;
  /** The caller's name. */
  name: string;
  /** The line's colour. Defaults to grey. */
  lineColor?: string;
}) => (
  <div style={{ ...fillCenter, height: call.textBox, minWidth: 0, textAlign: "left", marginLeft: call.textInset }}>
    <ExpandedSubtitle color={lineColor} style={{ fontSize: call.labelSize, lineHeight: `${call.labelLine}px`, marginTop: call.labelLift }}>
      {line}
    </ExpandedSubtitle>
    <ExpandedTitle style={{ marginTop: call.nameLift }}>{name}</ExpandedTitle>
  </div>
);

/** The trailing row the call's buttons sit in, 10.5 pt apart, the last one 16.1 pt from the island's edge. */
export const CallButtonRow = ({ children }: {
  /** The buttons, `callButton.size` round. */
  children: ReactNode;
}) => <div style={{ display: "flex", alignItems: "center", gap: call.buttonGap, height: call.row, marginRight: call.buttonInset - trailingPad }}>{children}</div>;

/**
 * A phone call. Ringing shows the expanded view (avatar, the kind of call over the caller's name,
 * decline and accept) and holds it there; once answered it settles to compact with a green handset
 * and the call time on the leading side and a two-tone meter on the trailing one.
 */
export const CallActivity = ({ id = "call", priority = 2, caller, subtitle = "Audio call", avatar, state, onAccept, onDecline }: CallActivityProps) => {
  const handlers = useLatest({ onAccept, onDecline });
  const stateKey = state.kind === "ringing" ? "ringing" : `active${state.since}`;

  const controls = useActivity(() => {
    const ringing = state.kind === "ringing";
    const decline = (
      <IslandRoundButton label={ringing ? `Decline call from ${caller}` : `End call with ${caller}`} color={red} size={call.button} onPress={() => handlers.current.onDecline()}>
        <HangUpGlyph size={call.handset} />
      </IslandRoundButton>
    );
    const accept = (
      <IslandRoundButton label={`Accept call from ${caller}`} color={green} size={call.button} onPress={() => handlers.current.onAccept()}>
        <PhoneGlyph size={call.handset} />
      </IslandRoundButton>
    );
    const time = state.kind === "active" ? <TickingTime source={{ kind: "elapsed", since: state.since }} /> : null;
    const meter = (bars: number) => (
      <LevelMeter
        envelope={voiceEnvelope}
        bars={bars}
        colors={Array.from({ length: bars }, (_, index) => (index < bars / 2 ? meterTones.near : meterTones.far))}
        core={meterTones.core}
        height={compactCall.height}
        barWidth={compactCall.barWidth}
        gap={compactCall.barGap}
      />
    );
    const avatarSide = <CallAvatar name={caller} src={avatar} />;
    const textStack = (line: ReactNode, lineColor: string) => <CallText line={line} name={caller} lineColor={lineColor} />;
    const trailingSide = (children: ReactNode) => <CallButtonRow>{children}</CallButtonRow>;
    const handset = <Glyph icon={PhoneGlyph} color={talkGreen} size={compactCall.handset} />;
    return {
      id,
      priority,
      label: ringing ? `Incoming call from ${caller}` : `On a call with ${caller}`,
      compact: withBubble(
        ringing
          ? { leading: <Avatar name={caller} src={avatar} />, trailing: <Glyph icon={PhoneGlyph} color={green} /> }
          : {
              leading: (
                <span className="icn-call-side" style={{ gap: compactCall.gap }}>
                  <IslandStyle id="call-answered" css={answeredCss} />
                  {handset}
                  <CompactText color={talkGreen}>{time}</CompactText>
                </span>
              ),
              trailing: (
                <span className="icn-call-side">
                  <span style={{ display: "block", paddingRight: compactCall.meterInset }}>{meter(compactCall.bars)}</span>
                </span>
              ),
            },
        <Glyph icon={PhoneGlyph} color={ringing ? green : talkGreen} />,
      ),
      minimal: ringing ? <Glyph icon={PhoneGlyph} color={green} /> : <MinimalPair leading={<Glyph icon={PhoneGlyph} color={talkGreen} />} trailing={<CompactText color={talkGreen}>{time}</CompactText>} />,
      expanded: ringing
        ? {
            leading: avatarSide,
            center: textStack(subtitle, islandInk.secondary),
            trailing: trailingSide(
              <>
                {decline}
                {accept}
              </>,
            ),
            bottom: undefined,
          }
        : {
            leading: avatarSide,
            center: textStack(time, talkGreen),
            trailing: trailingSide(
              <>
                {meter(8)}
                {decline}
              </>,
            ),
            bottom: undefined,
          },
    };
  }, [id, priority, caller, subtitle, avatar, stateKey]);

  const ringing = state.kind === "ringing";
  const { expand } = controls;
  const { collapse } = controls;
  const wasRinging = useRef(ringing);
  useEffect(() => {
    if (ringing) expand();
    else if (wasRinging.current) collapse();
    wasRinging.current = ringing;
  }, [ringing, expand, collapse]);

  return null;
};
