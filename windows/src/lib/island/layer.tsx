"use client";

import { type CSSProperties, type ReactNode, useLayoutEffect, useRef, useState } from "react";

import type { IslandMetrics } from "./metrics";
import type { IslandPresentation } from "./types";

/** Named DOM nodes inside a layer that the frame loop positions or the renderer measures. */
export type SlotName =
  | "root"
  | "leading"
  | "trailing"
  | "attached"
  | "detached"
  | "splitAttachedLeading"
  | "splitAttachedTrailing"
  | "splitDetachedLeading"
  | "splitDetachedTrailing"
  | "expanded"
  | "expandedClip"
  | "expandedInner"
  | "expandedLeading"
  | "expandedCenter"
  | "expandedTrailing"
  | "expandedBottom";

export type RegisterSlot = (slot: SlotName, element: HTMLElement | null) => void;

interface IslandLayerProps {
  /** What this layer shows. */
  presentation: IslandPresentation;
  /** Collects slot nodes for the frame loop. */
  register: RegisterSlot;
  metrics: IslandMetrics;
  /** Width the expanded regions lay out at. */
  expandedWidth: number;
  /** Leaving layers are hidden from assistive tech and can't take focus. */
  leaving: boolean;
}

// Slots start at the stage origin; the frame loop moves them with transforms every frame.
const slotBase: CSSProperties = {
  position: "absolute",
  top: 0,
  left: 0,
  display: "flex",
  alignItems: "center",
  willChange: "transform, opacity, filter",
  transformOrigin: "50%",
};

/**
 * Text that outgrows a compact slot ends in an ellipsis instead of being cut by the pill's edge.
 * Other content is clipped at the slot's width (`metrics.compact.maxSlotWidth`).
 */
const fitText = (children: ReactNode, maxWidth: number) =>
  typeof children === "string" || typeof children === "number" ? (
    <span style={{ display: "block", maxWidth, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{children}</span>
  ) : (
    children
  );

const Slot = ({ name, register, style, children }: { name: SlotName; register: RegisterSlot; style: CSSProperties; children?: ReactNode }) => (
  <div data-slot={name} ref={(element) => register(name, element)} style={style}>
    {children}
  </div>
);

export const IslandLayer = ({ presentation, register, metrics, expandedWidth, leaving }: IslandLayerProps) => {
  const rootStyle: CSSProperties = {
    position: "absolute",
    inset: 0,
    pointerEvents: presentation.kind === "expanded" && !leaving ? "auto" : "none",
  };
  const root = (children: ReactNode) => (
    <div
      ref={(element) => register("root", element)}
      data-layer={presentation.kind}
      aria-hidden={leaving || undefined}
      inert={leaving}
      style={rootStyle}
    >
      {children}
    </div>
  );

  switch (presentation.kind) {
    case "idle":
      return root(null);
    case "compact": {
      const max = metrics.compact.maxSlotWidth;
      // Clipped across only, so rings and glows can still spill a little above and below.
      const style: CSSProperties = { ...slotBase, height: metrics.compact.height, maxWidth: max, overflowX: "clip" };
      return root(
        <>
          <Slot name="leading" register={register} style={style}>
            {fitText(presentation.leading, max)}
          </Slot>
          <Slot name="trailing" register={register} style={style}>
            {fitText(presentation.trailing, max)}
          </Slot>
        </>,
      );
    }
    case "minimal": {
      const box: CSSProperties = { ...slotBase, height: metrics.minimal.height };
      const split = presentation.split;
      // Both layouts render; the frame loop shows the split when it fits and `minimal` otherwise.
      return root(
        <>
          <Slot name="attached" register={register} style={box}>
            {presentation.attached}
          </Slot>
          {presentation.detached === undefined ? null : (
            <Slot name="detached" register={register} style={box}>
              {presentation.detached}
            </Slot>
          )}
          {split ? (
            <>
              <Slot name="splitAttachedLeading" register={register} style={box}>
                {split.attached.leading}
              </Slot>
              <Slot name="splitAttachedTrailing" register={register} style={box}>
                {split.attached.trailing}
              </Slot>
              <Slot name="splitDetachedLeading" register={register} style={box}>
                {split.detached.leading}
              </Slot>
              <Slot name="splitDetachedTrailing" register={register} style={box}>
                {split.detached.trailing}
              </Slot>
            </>
          ) : null}
        </>,
      );
    }
    case "expanded":
      // The content clip sits inside the layer's blur, so the blur softens the clip's cut too.
      return root(
        <Slot name="expandedClip" register={register} style={{ position: "absolute", inset: 0 }}>
          <ExpandedGrid presentation={presentation} register={register} metrics={metrics} expandedWidth={expandedWidth} />
        </Slot>,
      );
    default: {
      const exhaustive: never = presentation;
      return exhaustive;
    }
  }
};

type ExpandedPresentation = Extract<IslandPresentation, { kind: "expanded" }>;

// Sizes a region's content at its own width, up to its column's.
const intrinsic: CSSProperties = { width: "max-content", maxWidth: "100%" };
// Space between the expanded regions' columns.
const gap = 10;

/**
 * The expanded regions. Leading and trailing get equal columns as wide as the wider of the two,
 * so the center region keeps the island's centre line and takes the rest of the row (unless that
 * would cut the center short: then each side keeps its own width). A spanning bottom region
 * (`contain: inline-size`) never widens the side columns.
 *
 * Every region of the top row starts at the row's top: leading and trailing at the padding,
 * center below the sensor. A taller center does not push the sides down (held-out wide-expand:
 * W's 36 pt circle sits at y 32.0 beside a two-line center, the same inset as A's 52 pt square).
 * Content that wants centring brings its own frame, as a SwiftUI region does.
 */
const ExpandedGrid = ({
  presentation,
  register,
  metrics,
  expandedWidth,
}: {
  presentation: ExpandedPresentation;
  register: RegisterSlot;
  metrics: IslandMetrics;
  expandedWidth: number;
}) => {
  const e = metrics.expanded;
  const hasBottom = presentation.bottom !== undefined && presentation.bottom !== null;
  // ActivityKit puts the center region below the sensor: its top is the sensor's bottom edge.
  const sensorBottom = metrics.top + metrics.idle.height;
  const centerTop = Math.max(0, sensorBottom - (e.top + e.padding.top)) + e.centerTop;
  const centerShift = ((e.padding.trailing ?? e.padding.side) - e.padding.side) / 2;
  // Each region moves on its own while the shape morphs (content follows the container).
  // No will-change here: a layer per region would snap to device pixels on top of the slot's
  // own snap and land the content a third of a point high.
  const region: CSSProperties = { minWidth: 0, transformOrigin: "50%" };
  const inner = useRef<HTMLDivElement | null>(null);
  const leading = useRef<HTMLDivElement>(null);
  const center = useRef<HTMLDivElement>(null);
  const trailing = useRef<HTMLDivElement>(null);
  // Null until measured: the first layout gives each side its own content width.
  const [columns, setColumns] = useState<string | null>(null);

  useLayoutEffect(() => {
    // Each wrapper's own max-content width, read with its cap lifted (a capped wrapper would
    // never report text that grew, after a font loads for instance).
    const natural = (element: HTMLElement | null) => {
      if (!element) return 0;
      const cap = element.style.maxWidth;
      element.style.maxWidth = "none";
      // The used width: fractional (a column a fraction narrower than its text ellipsizes it) and
      // untransformed (regions scale while they come in).
      const width = Number.parseFloat(getComputedStyle(element).width) || 0;
      element.style.maxWidth = cap;
      return Math.ceil(width) + 1;
    };
    const measure = () => {
      const l = natural(leading.current);
      const t = natural(trailing.current);
      const c = natural(center.current);
      const room = (inner.current?.clientWidth ?? 0) - 2 * gap;
      const side = Math.max(l, t);
      // Equal sides keep the center on the island's centre line. When that would squeeze the
      // center below its own width, each side keeps its own width and the center takes the rest.
      const next = c + 2 * side <= room ? `${side}px minmax(0, 1fr) ${side}px` : `${l}px minmax(0, 1fr) ${t}px`;
      setColumns((previous) => (previous === next ? previous : next));
    };
    measure();
    let live = true;
    void document.fonts?.ready.then(() => {
      if (live) measure();
    });
    if (typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(measure);
    for (const element of [inner.current, leading.current, center.current, trailing.current]) if (element) observer.observe(element);
    return () => {
      live = false;
      observer.disconnect();
    };
  }, []);

  return (
    <Slot
      name="expanded"
      register={register}
      style={{
        ...slotBase,
        display: "block",
        width: expandedWidth,
        boxSizing: "border-box",
        padding: `${e.padding.top}px ${e.padding.trailing ?? e.padding.side}px ${e.padding.bottom}px ${e.padding.side}px`,
        transformOrigin: "50% 0",
      }}
    >
      <div
        ref={(element) => {
          inner.current = element;
          register("expandedInner", element);
        }}
        style={{
          display: "grid",
          gridTemplateColumns: columns ?? "max-content minmax(0, 1fr)",
          gridTemplateAreas: hasBottom ? '"leading center trailing" "bottom bottom bottom"' : '"leading center trailing"',
          columnGap: gap,
          rowGap: hasBottom ? e.rowGap : 0,
          alignItems: "start",
        }}
      >
        <div ref={(element) => register("expandedLeading", element)} style={{ ...region, gridArea: "leading" }}>
          <div ref={leading} style={intrinsic}>
            {presentation.leading}
          </div>
        </div>
        {/* The center region sits below the sensor, top-aligned, centred on the island. */}
        <div
          ref={(element) => register("expandedCenter", element)}
          style={{
            ...region,
            gridArea: "center",
            alignSelf: "start",
            // Centred on the island, not on the content between unequal side paddings (round 23:
            // the title sat 0.16 to 0.34 pt right of the simulator's with the trailing inset 17.81).
            position: "relative",
            left: centerShift,
            paddingTop: centerTop,
            display: "flex",
            justifyContent: "center",
            textAlign: "center",
          }}
        >
          <div ref={center} style={intrinsic}>
            {presentation.center}
          </div>
        </div>
        <div ref={(element) => register("expandedTrailing", element)} style={{ ...region, gridArea: "trailing", justifySelf: "end" }}>
          <div ref={trailing} style={intrinsic}>
            {presentation.trailing}
          </div>
        </div>
        {hasBottom ? (
          <div
            ref={(element) => register("expandedBottom", element)}
            style={{ ...region, gridArea: "bottom", paddingInline: e.bottomInset, contain: "inline-size" }}
          >
            {presentation.bottom}
          </div>
        ) : null}
      </div>
    </Slot>
  );
};
