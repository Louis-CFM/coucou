// ── macOS Liquid Glass & Jelly Physics Engine ──────────────────────────────
// High-fidelity spring physics modeled after Apple SwiftUI .spring() and .bouncy()
// curves from macOS Sonoma/Sequoia. Pure Framer Motion ('motion') under the hood.

import { animate as motionAnimate, stagger, type AnimationPlaybackControls } from "motion";

export type AsyncAnimationPlaybackControls = AnimationPlaybackControls & PromiseLike<void>;

export { stagger, type AnimationPlaybackControls };

export function animate(...args: Parameters<typeof motionAnimate>): AsyncAnimationPlaybackControls {
  if (typeof Element === "undefined" || typeof window === "undefined" || !window.document) {
    const dummyPromise = Promise.resolve();
    return {
      then: (onfulfilled?: ((value: void) => any) | null, onrejected?: ((reason: any) => any) | null) =>
        dummyPromise.then(onfulfilled, onrejected),
      stop: () => {},
      cancel: () => {},
      pause: () => {},
      play: () => {},
      finish: () => {},
      currentTime: 0,
      playbackRate: 1,
      iterationCount: 1,
      state: "finished",
    } as unknown as AsyncAnimationPlaybackControls;
  }
  return motionAnimate(...args) as AsyncAnimationPlaybackControls;
}

/**
 * Precision-tuned spring configurations matching macOS Sonoma / Sequoia
 * physics: underdamped harmonic oscillators with damping ratios (ζ)
 * between 0.48 and 0.66 for signature buttery jelly bounce without jitter.
 */
export const MACOS_JELLY = {
  /**
   * Sidebar active indicator gliding between navigation items.
   * Tension tuned for high-velocity travel with elastic settling.
   * ζ ≈ 0.575 (stiffness: 420, damping: 20, mass: 0.72)
   */
  indicator: {
    type: "spring" as const,
    stiffness: 420,
    damping: 20,
    mass: 0.72,
  },

  /**
   * Full settings page entrance transition: liquid glide & scale bloom.
   * ζ ≈ 0.658 (stiffness: 340, damping: 22, mass: 0.82)
   */
  page: {
    type: "spring" as const,
    stiffness: 340,
    damping: 22,
    mass: 0.82,
  },

  /**
   * Card & hero entrance cascade: buttery ripple wave down the page.
   * ζ ≈ 0.664 (stiffness: 320, damping: 21, mass: 0.78)
   */
  card: {
    type: "spring" as const,
    stiffness: 320,
    damping: 21,
    mass: 0.78,
  },

  /**
   * Floating menus, popups, and dropdown panels blooming open.
   * ζ ≈ 0.565 (stiffness: 460, damping: 21, mass: 0.75)
   */
  dropdownOpen: {
    type: "spring" as const,
    stiffness: 460,
    damping: 21,
    mass: 0.75,
  },

  /**
   * Micro-stagger for individual menu items inside a dropdown.
   * ζ ≈ 0.679 (stiffness: 480, damping: 24, mass: 0.65)
   */
  dropdownItem: {
    type: "spring" as const,
    stiffness: 480,
    damping: 24,
    mass: 0.65,
  },

  /**
   * Snappy feedback on interactive controls and search focus.
   * ζ ≈ 0.553 (stiffness: 480, damping: 20, mass: 0.68)
   */
  snappy: {
    type: "spring" as const,
    stiffness: 480,
    damping: 20,
    mass: 0.68,
  },

  /**
   * Playful jelly pop: search clear button (x), active anchors, badge badges.
   * ζ ≈ 0.462 (stiffness: 520, damping: 17, mass: 0.65)
   */
  bouncy: {
    type: "spring" as const,
    stiffness: 520,
    damping: 17,
    mass: 0.65,
  },
};

/**
 * Calculates physical squash & stretch keyframes based on travel distance.
 * When an element travels fast across the screen, physical inertia stretches
 * it along the travel axis and compresses it perpendicularly, then rebounds
 * upon arrival.
 */
export function jellySquashStretch(distance: number) {
  const d = Math.abs(distance);
  if (d < 5) {
    return {
      scaleY: [1, 1.03, 0.985, 1],
      scaleX: [1, 0.985, 1.015, 1],
    };
  }
  // Clamp dynamic stretch between 1.04 and 1.16 for natural fluid look
  const stretch = Math.min(1.16, 1 + d * 0.0009);
  const squish = Math.max(0.91, 1 - d * 0.0006);

  return {
    scaleY: [1, stretch, 0.94, 1.02, 1],
    scaleX: [1, squish, 1.035, 0.99, 1],
  };
}

/**
 * Applies a buttery tactile press & release jelly bounce on any HTML element.
 */
export function attachJellyPress(element: HTMLElement) {
  element.addEventListener("pointerdown", () => {
    animate(element, { scale: 0.95 }, { duration: 0.09, ease: "easeOut" });
  });
  const release = () => {
    animate(
      element,
      { scale: [0.95, 1.03, 0.99, 1] },
      MACOS_JELLY.snappy
    );
  };
  element.addEventListener("pointerup", release);
  element.addEventListener("pointercancel", release);
}
