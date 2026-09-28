// Port of IslandStateMachine.swift

export type FsmState = "hidden" | "petit" | "home" | "coucou";

export interface IslandStateMachineOptions {
  homeToPetitDelay?: number;
  petitToHiddenDelay?: number;
  greetAutoCollapseDelay?: number;
  greetHoverCollapseDelay?: number;
  now?: () => number;
  schedule?: (fn: () => void, delayMs: number) => number;
  cancel?: (id: number) => void;
}

const defaultSchedule = (fn: () => void, delayMs: number): number =>
  window.setTimeout(fn, delayMs);
const defaultCancel = (id: number): void => window.clearTimeout(id);

export class IslandStateMachine {
  private _state: FsmState = "hidden";
  onTransition: ((from: FsmState, to: FsmState) => void) | null = null;

  homeToPetitDelay = 15;
  petitToHiddenDelay = 60;
  greetAutoCollapseDelay = 0.6;
  greetHoverCollapseDelay = 10;

  private petitHideTimer: number | null = null;
  private homeCollapseTimer: number | null = null;
  private greetCollapseTimer: number | null = null;

  private readonly schedule: (fn: () => void, delayMs: number) => number;
  private readonly cancelTimer: (id: number) => void;

  constructor(options: IslandStateMachineOptions = {}) {
    if (options.homeToPetitDelay !== undefined) {
      this.homeToPetitDelay = options.homeToPetitDelay;
    }
    if (options.petitToHiddenDelay !== undefined) {
      this.petitToHiddenDelay = options.petitToHiddenDelay;
    }
    if (options.greetAutoCollapseDelay !== undefined) {
      this.greetAutoCollapseDelay = options.greetAutoCollapseDelay;
    }
    if (options.greetHoverCollapseDelay !== undefined) {
      this.greetHoverCollapseDelay = options.greetHoverCollapseDelay;
    }
    this.schedule = options.schedule ?? defaultSchedule;
    this.cancelTimer = options.cancel ?? defaultCancel;
  }

  get state(): FsmState {
    return this._state;
  }

  launch(): void {
    this.cancelTimers();
    this.transition("coucou");
  }

  mouseEntered(): void {
    switch (this._state) {
      case "hidden":
        this.cancelTimers();
        this.transition("petit");
        break;
      case "petit":
        if (this.petitHideTimer !== null) {
          this.cancelTimer(this.petitHideTimer);
          this.petitHideTimer = null;
        }
        break;
      case "home":
        if (this.homeCollapseTimer !== null) {
          this.cancelTimer(this.homeCollapseTimer);
          this.homeCollapseTimer = null;
        }
        break;
      case "coucou":
        this.scheduleGreetCollapse(this.greetHoverCollapseDelay * 1000);
        break;
    }
  }

  mouseLeft(): void {
    switch (this._state) {
      case "hidden":
        break;
      case "petit":
        this.schedulePetitHide();
        break;
      case "home":
        this.scheduleHomeCollapse();
        break;
      case "coucou":
        if (this.greetCollapseTimer !== null) {
          this.cancelTimer(this.greetCollapseTimer);
          this.greetCollapseTimer = null;
        }
        this.transition("petit");
        break;
    }
  }

  click(): void {
    if (this._state !== "petit") return;
    this.cancelTimers();
    this.transition("home");
  }

  greetComplete(): void {
    if (this._state !== "coucou") return;
    if (this.greetCollapseTimer === null) {
      this.scheduleGreetCollapse(this.greetAutoCollapseDelay * 1000);
    }
  }

  reveal(): void {
    if (this._state !== "hidden") return;
    this.cancelTimers();
    this.transition("petit");
    this.schedulePetitHide();
  }

  cancelTimers(): void {
    if (this.petitHideTimer !== null) {
      this.cancelTimer(this.petitHideTimer);
      this.petitHideTimer = null;
    }
    if (this.homeCollapseTimer !== null) {
      this.cancelTimer(this.homeCollapseTimer);
      this.homeCollapseTimer = null;
    }
    if (this.greetCollapseTimer !== null) {
      this.cancelTimer(this.greetCollapseTimer);
      this.greetCollapseTimer = null;
    }
  }

  private scheduleGreetCollapse(delayMs: number): void {
    if (this.greetCollapseTimer !== null) {
      this.cancelTimer(this.greetCollapseTimer);
    }
    this.greetCollapseTimer = this.schedule(() => {
      this.greetCollapseTimer = null;
      if (this._state === "coucou") {
        this.transition("petit");
      }
    }, delayMs);
  }

  private schedulePetitHide(): void {
    if (this.petitHideTimer !== null) {
      this.cancelTimer(this.petitHideTimer);
    }
    this.petitHideTimer = this.schedule(() => {
      this.petitHideTimer = null;
      if (this._state === "petit") {
        this.transition("hidden");
      }
    }, this.petitToHiddenDelay * 1000);
  }

  private scheduleHomeCollapse(): void {
    if (this.homeCollapseTimer !== null) {
      this.cancelTimer(this.homeCollapseTimer);
    }
    this.homeCollapseTimer = this.schedule(() => {
      this.homeCollapseTimer = null;
      if (this._state === "home") {
        this.transition("petit");
      }
    }, this.homeToPetitDelay * 1000);
  }

  private transition(to: FsmState): void {
    if (to === this._state) return;
    const from = this._state;
    this._state = to;
    this.onTransition?.(from, to);
  }
}
