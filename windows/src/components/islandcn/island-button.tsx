"use client";

import type { CSSProperties, MouseEvent, ReactNode } from "react";

import { useIslandReducedMotion } from "@/lib/island/index";

import { IslandStyle } from "./island-style";
import { islandFont, islandInk, islandSize, trackingFor } from "./theme";

const css = `
.icn-button {
  appearance: none; border: 0; margin: 0; cursor: pointer; user-select: none;
  -webkit-tap-highlight-color: transparent; touch-action: manipulation;
  position: relative; display: inline-flex; align-items: center; justify-content: center; gap: 6px;
  font-family: ${islandFont}; font-weight: 600; -webkit-font-smoothing: antialiased;
  background: var(--icn-bg); color: var(--icn-fg);
  transition: transform 160ms cubic-bezier(0.22, 1, 0.36, 1), filter 160ms ease-out, background-color 160ms ease-out;
}
@media (hover: hover) and (pointer: fine) { .icn-button:hover { filter: brightness(1.12); } }
/* Buttons drawn smaller than 44 pt still take a 44 pt touch. */
.icn-button::after { content: ""; position: absolute; inset: min(0px, calc((100% - 44px) / 2)); }
.icn-button:active { transform: scale(0.96); filter: brightness(0.9); }
.icn-button:focus-visible { outline: 2px solid var(--icn-ring); outline-offset: 2px; }
.icn-button:disabled { cursor: default; opacity: 0.4; transform: none; filter: none; }
@media (prefers-reduced-motion: reduce) { .icn-button { transition: none; } .icn-button:active { transform: none; } }
/* The island's own reduced-motion setting ("always"), which the media query can't see. */
.icn-button[data-reduced] { transition: none; }
.icn-button[data-reduced]:active { transform: none; }
`;

type ButtonTone =
  /** Filled with the accent: the action you expect, such as Approve or Accept. */
  | { kind: "accent"; color: string; text?: string }
  /** Translucent white: the other choice, such as Deny or Cancel. */
  | { kind: "neutral" };

interface IslandButtonProps {
  children: ReactNode;
  /** Called on click, tap, Enter or Space. */
  onPress: () => void;
  /** Filled with an accent or translucent white. Defaults to neutral. */
  tone?: ButtonTone;
  /** Grow to fill the row. Defaults to true. */
  fill?: boolean;
  /** Turns the button off. Defaults to false. */
  disabled?: boolean;
  /** Accessible name when the label alone isn't enough. Defaults to the text. */
  label?: string;
  /** "regular" is 17 pt text with 18 pt sides; "compact" is 15 pt with 12 pt sides, for a row that shares space. Both are 44 pt tall. Defaults to "regular". */
  size?: "regular" | "compact";
}

const toneVars = (tone: ButtonTone) =>
  tone.kind === "accent"
    ? { "--icn-bg": tone.color, "--icn-fg": tone.text ?? "#000", "--icn-ring": tone.color }
    : { "--icn-bg": islandInk.fill, "--icn-fg": islandInk.primary, "--icn-ring": islandInk.primary };

/** Label size in pt per button size. */
const labelSize = { regular: 17, compact: 15 } as const satisfies Record<NonNullable<IslandButtonProps["size"]>, number>;

// Presses inside island content must not bubble into the island's own long-press handling.
const stop = (event: MouseEvent) => event.stopPropagation();

/**
 * A capsule button for the expanded view: 44 pt tall (the minimum touch target), 17 pt
 * semibold. Works with mouse, touch and keyboard because it is a real `<button>`.
 */
export const IslandButton = ({ children, onPress, tone = { kind: "neutral" }, fill = true, disabled = false, label, size = "regular" }: IslandButtonProps) => {
  const reduced = useIslandReducedMotion();
  const style = {
    height: islandSize.button,
    padding: size === "compact" ? "0 12px" : "0 18px",
    borderRadius: islandSize.button / 2,
    fontSize: labelSize[size],
    letterSpacing: trackingFor(labelSize[size]),
    whiteSpace: "nowrap",
    flex: fill ? "1 0" : "none",
    minWidth: 0,
    ...toneVars(tone),
  } as const satisfies CSSProperties & Record<`--icn-${string}`, string | number>;
  return (
    <button type="button" className="icn-button" data-reduced={reduced ? "" : undefined} style={style} disabled={disabled} aria-label={label} onClick={(event) => {
      stop(event);
      onPress();
    }} onPointerDown={(event) => event.stopPropagation()}>
      <IslandStyle id="button" css={css} />
      {children}
    </button>
  );
};

interface IslandRoundButtonProps {
  /** The icon inside, usually an islandcn glyph at about half the size. */
  children: ReactNode;
  /** Accessible name, since the button shows only an icon. */
  label: string;
  /** Called on click, tap, Enter or Space. */
  onPress: () => void;
  /** Background colour. Defaults to translucent white. */
  color?: string;
  /** Icon colour. Defaults to white. */
  iconColor?: string;
  /** Diameter in pt. Defaults to 44. */
  size?: number;
  /** Turns the button off. Defaults to false. */
  disabled?: boolean;
}

/** A round icon button: accept and decline, pause and cancel, stop. */
export const IslandRoundButton = ({
  children,
  label,
  onPress,
  color = islandInk.fill,
  iconColor = islandInk.primary,
  size = islandSize.button,
  disabled = false,
}: IslandRoundButtonProps) => {
  const reduced = useIslandReducedMotion();
  const style = {
    width: size,
    height: size,
    padding: 0,
    borderRadius: "50%",
    flex: "none",
    "--icn-bg": color,
    "--icn-fg": iconColor,
    // The icon colour always shows on black, even when the button itself is transparent.
    "--icn-ring": iconColor,
  } as const satisfies CSSProperties & Record<`--icn-${string}`, string | number>;
  return (
    <button type="button" className="icn-button" data-reduced={reduced ? "" : undefined} style={style} aria-label={label} disabled={disabled} onClick={(event) => {
      stop(event);
      onPress();
    }} onPointerDown={(event) => event.stopPropagation()}>
      <IslandStyle id="button" css={css} />
      {children}
    </button>
  );
};
