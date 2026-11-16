"use client";

import { useId } from "react";

import { islandFont } from "./theme";

interface AvatarProps {
  /** The person's name. The initials come from it. */
  name: string;
  /** A photo, drawn over the monogram (which shows while it loads or if it fails). Defaults to none. */
  src?: string;
  /** Size in pt. Defaults to 22, the compact glyph size. */
  size?: number;
}

/** Up to two initials, from letters only: "+1 555 0100" or "" gives none. */
const initialsOf = (name: string) =>
  name
    .split(/\s+/)
    .map((part) => part.match(/\p{L}/u)?.[0] ?? "")
    .filter((letter) => letter.length > 0)
    .slice(0, 2)
    .map((letter) => letter.toLocaleUpperCase())
    .join("");

/**
 * The monogram's dusky violet grey, lighter at the top, measured on a phone's incoming call
 * (#554f66 to #36294f). Dark and nearly neutral, it reads as "no photo yet" on the black island
 * without competing with the green and red call buttons beside it.
 */
const monogram = { top: "#554f66", bottom: "#36294f" } as const satisfies Record<"top" | "bottom", string>;

/**
 * A round avatar: a photo, or a contact-style monogram (white semibold initials in the system
 * font on a dusky gradient). With no letters in the name (a phone number) it shows a person's
 * silhouette instead.
 */
export const Avatar = ({ name, src, size = 22 }: AvatarProps) => {
  const id = `icn${useId().replace(/[^a-zA-Z0-9_-]/g, "")}`;
  const initials = initialsOf(name);
  return (
    <span aria-hidden style={{ display: "block", position: "relative", width: size, height: size, flex: "none", borderRadius: "50%", overflow: "hidden", background: monogram.bottom }}>
      <svg width={size} height={size} viewBox="0 100" style={{ position: "absolute", inset: 0, display: "block" }}>
        <defs>
          <linearGradient id={`${id}-disc`} x1={0} y1={0} x2={0} y2={1}>
            <stop offset={0} stopColor={monogram.top} />
            <stop offset={1} stopColor={monogram.bottom} />
          </linearGradient>
          <clipPath id={`${id}-clip`}>
            <circle cx={50} cy={50} r={50} />
          </clipPath>
        </defs>
        <circle cx={50} cy={50} r={50} fill={`url(#${id}-disc)`} />
        {initials.length > 0 ? (
          // One letter's cap is 38% of the disc (54% type, as measured on a 50 pt call avatar); two letters sit smaller.
          <text
            x={50}
            y={50}
            dy="0.35em"
            fill="#fff"
            fontFamily={islandFont}
            fontWeight={600}
            fontSize={initials.length > 1 ? 40 : 54}
            textAnchor="middle"
            letterSpacing={initials.length > 1 ? 0.4 : 0}
          >
            {initials}
          </text>
        ) : (
          // Head and shoulders, the shoulders running off the bottom of the disc.
          <g fill="#fff" clipPath={`url(#${id}-clip)`}>
            <circle cx={50} cy={39} r={18} />
            <ellipse cx={50} cy={96} rx={36} ry={30} />
          </g>
        )}
      </svg>
      {src ? <span style={{ position: "absolute", inset: 0, background: `center / cover no-repeat url(${JSON.stringify(src)})` }} /> : null}
    </span>
  );
};
