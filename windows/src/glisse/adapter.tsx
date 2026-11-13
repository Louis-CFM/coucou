// ── Glisse Liquid Glass DOM Adapter Bridge ─────────────────────────────────
// Allows React-based Glisse components (Switch, Button, SegmentedControl,
// Slider, Glass, SearchField, Menu) to drop seamlessly into Coucou's Vanilla
// DOM tree without breaking FlowBridge or existing event hooks.

import "glisse/styles.css";
import "./glisse.css";
import React, { useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import {
  Button as GButton,
  Switch as GSwitch,
  Slider as GSlider,
  SegmentedControl as GSegmentedControl,
  Glass as GGlass,
  SearchField as GSearchField,
} from "glisse";

/**
 * Creates a Glisse Liquid Glass toggle switch with a real-time draggable
 * optical lens thumb and Apple spring physics.
 * Observes `el.classList.contains("on")` for backward compatibility with existing Coucou callers.
 */
export function glisseSwitch(
  initialChecked: boolean,
  onChange: (checked: boolean) => void,
  ariaLabel = "Toggle"
): HTMLElement & { setChecked(checked: boolean): void; destroy(): void } {
  const container = document.createElement("div");
  container.className = `glisse-switch-host ${initialChecked ? "on" : ""}`.trim();

  let setExternalChecked: ((v: boolean) => void) | null = null;
  let currentVal = initialChecked;

  function SwitchWrapper() {
    const [checked, setChecked] = useState(initialChecked);
    setExternalChecked = setChecked;

    return (
      <GSwitch
        checked={checked}
        aria-label={ariaLabel}
        onCheckedChange={(next) => {
          currentVal = next;
          setChecked(next);
          container.classList.toggle("on", next);
          onChange(next);
        }}
      />
    );
  }

  const root: Root = createRoot(container);
  root.render(<SwitchWrapper />);

  // Synchronize legacy `el.classList.toggle("on", bool)` calls with React state
  const observer = new MutationObserver(() => {
    const hasOn = container.classList.contains("on");
    if (hasOn !== currentVal) {
      currentVal = hasOn;
      setExternalChecked?.(hasOn);
    }
  });
  observer.observe(container, { attributes: true, attributeFilter: ["class"] });

  const el = container as unknown as HTMLElement & {
    setChecked(checked: boolean): void;
    destroy(): void;
  };

  el.setChecked = (v: boolean) => {
    currentVal = v;
    container.classList.toggle("on", v);
    setExternalChecked?.(v);
  };

  el.destroy = () => {
    observer.disconnect();
    root.unmount();
  };

  return el;
}

/**
 * Creates a Glisse Liquid Glass button with specular border reflections,
 * dynamic tinting, and fluid click dynamics.
 */
export function glisseButton(
  label: string,
  onClick: () => void,
  variant: "glass" | "filled" = "glass",
  options: { destructive?: boolean; tint?: string; icon?: React.ReactNode; small?: boolean } = {}
): HTMLElement & { setLabel(text: string): void; destroy(): void } {
  const container = document.createElement("div");
  container.className = `glisse-button-host ${options.small ? "small" : ""}`.trim();

  let setExternalLabel: ((text: string) => void) | null = null;

  function ButtonWrapper() {
    const [btnLabel, setBtnLabel] = useState(label);
    setExternalLabel = setBtnLabel;

    return (
      <GButton
        variant={variant}
        destructive={options.destructive}
        tint={options.tint ?? (variant === "filled" ? "#fb923c" : undefined)}
        icon={options.icon}
        onClick={onClick}
      >
        {btnLabel}
      </GButton>
    );
  }

  const root: Root = createRoot(container);
  root.render(<ButtonWrapper />);

  const el = container as unknown as HTMLElement & {
    setLabel(text: string): void;
    destroy(): void;
  };

  el.setLabel = (text: string) => {
    setExternalLabel?.(text);
  };

  el.destroy = () => {
    root.unmount();
  };

  return el;
}

/**
 * Creates a Glisse Liquid Glass SegmentedControl with an internal sliding
 * optical glass lens on a stationary track, eliminating layout shift and hover jitter.
 */
export function glisseSegmented<T extends string>(
  options: [T, string][],
  initialValue: T,
  onChange: (v: T) => void
): HTMLElement & { setValue(v: T): void; destroy(): void } {
  const container = document.createElement("div");
  container.className = "glisse-segmented-host";

  let setExternalValue: ((v: string) => void) | null = null;

  function SegmentedWrapper() {
    const [val, setVal] = useState<string>(initialValue);
    setExternalValue = setVal;

    const items = options.map(([value, labelText]) => ({
      value,
      label: labelText,
    }));

    return (
      <GSegmentedControl
        items={items}
        value={val}
        onValueChange={(nextVal) => {
          setVal(nextVal);
          onChange(nextVal as T);
        }}
      />
    );
  }

  const root: Root = createRoot(container);
  root.render(<SegmentedWrapper />);

  const el = container as unknown as HTMLElement & {
    setValue(v: T): void;
    destroy(): void;
  };

  el.setValue = (v: T) => {
    setExternalValue?.(v);
  };

  el.destroy = () => {
    root.unmount();
  };

  return el;
}

/**
 * Creates a Glisse Liquid Glass Slider featuring a draggable crystal lens thumb
 * and frosted track.
 */
export function glisseSlider(
  initialValue: number,
  onChange: (v: number) => void,
  options: { min?: number; max?: number; step?: number; ariaLabel?: string } = {}
): HTMLElement & { setValue(v: number): void; destroy(): void } {
  const container = document.createElement("div");
  container.className = "glisse-slider-host";

  let setExternalValue: ((v: number) => void) | null = null;

  function SliderWrapper() {
    const [val, setVal] = useState<number>(initialValue);
    setExternalValue = setVal;

    return (
      <GSlider
        value={val}
        min={options.min ?? 0}
        max={options.max ?? 100}
        step={options.step ?? 1}
        aria-label={options.ariaLabel ?? "Slider"}
        onValueChange={(next) => {
          setVal(next);
          onChange(next);
        }}
      />
    );
  }

  const root: Root = createRoot(container);
  root.render(<SliderWrapper />);

  const el = container as unknown as HTMLElement & {
    setValue(v: number): void;
    destroy(): void;
  };

  el.setValue = (v: number) => {
    setExternalValue?.(v);
  };

  el.destroy = () => {
    root.unmount();
  };

  return el;
}

/**
 * Wraps content in a Glisse Refractive Glass container.
 */
export function glisseGlassContainer(
  className = "",
  style: React.CSSProperties = {}
): { container: HTMLElement; content: HTMLElement; destroy(): void } {
  const host = document.createElement("div");
  host.className = `glisse-glass-host ${className}`.trim();

  const contentEl = document.createElement("div");
  contentEl.className = "glisse-glass-content";

  function GlassWrapper() {
    return (
      <GGlass style={style}>
        <div ref={(node) => {
          if (node && !node.contains(contentEl)) {
            node.appendChild(contentEl);
          }
        }} />
      </GGlass>
    );
  }

  const root: Root = createRoot(host);
  root.render(<GlassWrapper />);

  return {
    container: host,
    content: contentEl,
    destroy: () => root.unmount(),
  };
}

/**
 * Glisse SearchField wrapper with integrated magnifier, clear button, and spring focus.
 */
export function glisseSearchField(
  placeholder: string,
  onValueChange: (val: string) => void,
  onEnter?: () => void
): HTMLElement & { setValue(val: string): void; focus(): void; destroy(): void } {
  const container = document.createElement("div");
  container.className = "glisse-search-host";

  let setExternalValue: ((val: string) => void) | null = null;
  let inputRef: HTMLInputElement | null = null;

  function SearchWrapper() {
    const [val, setVal] = useState("");
    setExternalValue = setVal;

    return (
      <GSearchField
        ref={(el) => { inputRef = el; }}
        placeholder={placeholder}
        value={val}
        onValueChange={(next) => {
          setVal(next);
          onValueChange(next);
        }}
        onKeyDown={(e) => {
          if (e.key === "Enter") onEnter?.();
        }}
      />
    );
  }

  const root: Root = createRoot(container);
  root.render(<SearchWrapper />);

  const el = container as unknown as HTMLElement & {
    setValue(val: string): void;
    focus(): void;
    destroy(): void;
  };

  el.setValue = (v: string) => {
    setExternalValue?.(v);
  };

  el.focus = () => {
    inputRef?.focus();
  };

  el.destroy = () => {
    root.unmount();
  };

  return el;
}
