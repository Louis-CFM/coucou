/**
 * AvatarLifecycleManager — Coucou Interactive Avatar Reliability & Lifecycle Manager.
 *
 * Provides a resilient state machine, health monitoring, error containment,
 * GPU context-loss recovery, and visibility synchronization for the Coucou
 * interactive avatar (Mochi / botCanvas).
 */

export type AvatarLifecycleState =
  | "UNINITIALIZED"
  | "INITIALIZING"
  | "READY"
  | "RENDERING"
  | "PAUSED"
  | "INTERRUPTED"
  | "RECOVERING"
  | "FAILED";

export interface AvatarHealthSnapshot {
  state: AvatarLifecycleState;
  totalFrames: number;
  consecutiveErrors: number;
  totalRecoveries: number;
  lastFrameTimestamp: number;
  lastRecoveryTimestamp: number;
  lastError: string | null;
  contextLost: boolean;
  isWindowVisible: boolean;
  isHealthy: boolean;
}

export class AvatarLifecycleManager {
  private _state: AvatarLifecycleState = "UNINITIALIZED";
  private _totalFrames = 0;
  private _consecutiveErrors = 0;
  private _totalRecoveries = 0;
  private _lastFrameTimestamp = 0;
  private _lastRecoveryTimestamp = 0;
  private _lastError: string | null = null;
  private _contextLost = false;
  private _isWindowVisible = true;

  /** Maximum consecutive errors allowed before entering cool-off in FAILED state */
  readonly maxConsecutiveErrors: number;
  /** Cool-off duration in ms before FAILED state auto-resets to allow recovery */
  readonly failureCooloffMs: number;

  constructor(options?: { maxConsecutiveErrors?: number; failureCooloffMs?: number }) {
    this.maxConsecutiveErrors = options?.maxConsecutiveErrors ?? 5;
    this.failureCooloffMs = options?.failureCooloffMs ?? 3000;
    if (typeof document !== "undefined") {
      this._isWindowVisible = document.visibilityState !== "hidden";
    }
  }

  get state(): AvatarLifecycleState {
    return this._state;
  }

  get isContextLost(): boolean {
    return this._contextLost;
  }

  get isWindowVisible(): boolean {
    return this._isWindowVisible;
  }

  get consecutiveErrors(): number {
    return this._consecutiveErrors;
  }

  get totalRecoveries(): number {
    return this._totalRecoveries;
  }

  /**
   * Initializes the manager into READY state.
   */
  initialize(): void {
    this._state = "READY";
    this._consecutiveErrors = 0;
  }

  /**
   * Called at the start of a frame execution.
   */
  onFrameStart(): void {
    if (this._state === "READY" || this._state === "PAUSED") {
      this._state = "RENDERING";
    }
  }

  /**
   * Called when a frame completes successfully without throwing.
   */
  onFrameSuccess(): void {
    this._totalFrames++;
    this._consecutiveErrors = 0;
    this._lastFrameTimestamp = Date.now();
    if (this._state === "RENDERING" || this._state === "RECOVERING") {
      this._state = "READY";
    }
  }

  /**
   * Called when an unhandled exception occurs inside a frame.
   * Prevents loop death and decides whether recovery should be initiated.
   */
  onFrameError(error: unknown): boolean {
    this._consecutiveErrors++;
    this._lastError = error instanceof Error ? `${error.name}: ${error.message}` : String(error);
    this._state = "INTERRUPTED";

    if (this._consecutiveErrors >= this.maxConsecutiveErrors) {
      this._state = "FAILED";
      this._lastRecoveryTimestamp = Date.now();
      return false;
    }
    return true;
  }

  /**
   * Called when the GPU context is lost (e.g. sleep/wake, D3D reset).
   */
  onContextLost(): void {
    this._contextLost = true;
    this._state = "INTERRUPTED";
  }

  /**
   * Called when the GPU context is restored.
   */
  onContextRestored(): void {
    this._contextLost = false;
    this._state = "READY";
  }

  /**
   * Called when window visibility changes (e.g. minimize, lock screen, restore).
   */
  onVisibilityChange(visible: boolean): void {
    this._isWindowVisible = visible;
    if (!visible) {
      if (this._state === "RENDERING" || this._state === "READY") {
        this._state = "PAUSED";
      }
    } else {
      if (this._state === "PAUSED") {
        this._state = "READY";
      }
    }
  }

  /**
   * Predicate determining if canvas rendering is currently viable.
   */
  canRender(): boolean {
    if (this._contextLost) return false;

    // Check if cool-off period has passed for FAILED state
    if (this._state === "FAILED") {
      const now = Date.now();
      if (now - this._lastRecoveryTimestamp > this.failureCooloffMs) {
        this._state = "READY";
        this._consecutiveErrors = 0;
        return true;
      }
      return false;
    }

    return true;
  }

  /**
   * Executes a safe recovery procedure with circuit breaking.
   */
  recover(recoveryFn: () => void): boolean {
    if (this._state === "FAILED") {
      const now = Date.now();
      if (now - this._lastRecoveryTimestamp <= this.failureCooloffMs) {
        return false;
      }
    }

    this._state = "RECOVERING";
    this._totalRecoveries++;
    this._lastRecoveryTimestamp = Date.now();

    try {
      recoveryFn();
      this._consecutiveErrors = 0;
      this._state = "READY";
      return true;
    } catch (e) {
      this._consecutiveErrors++;
      this._lastError = e instanceof Error ? e.message : String(e);
      if (this._consecutiveErrors >= this.maxConsecutiveErrors) {
        this._state = "FAILED";
      } else {
        this._state = "INTERRUPTED";
      }
      return false;
    }
  }

  /**
   * Returns a diagnostic snapshot of the avatar rendering health.
   */
  getSnapshot(): AvatarHealthSnapshot {
    const now = Date.now();
    const isRecent = this._lastFrameTimestamp > 0 && now - this._lastFrameTimestamp < 5000;
    const isHealthy =
      this._state !== "FAILED" &&
      !this._contextLost &&
      (this._state === "PAUSED" || isRecent || this._consecutiveErrors === 0);

    return {
      state: this._state,
      totalFrames: this._totalFrames,
      consecutiveErrors: this._consecutiveErrors,
      totalRecoveries: this._totalRecoveries,
      lastFrameTimestamp: this._lastFrameTimestamp,
      lastRecoveryTimestamp: this._lastRecoveryTimestamp,
      lastError: this._lastError,
      contextLost: this._contextLost,
      isWindowVisible: this._isWindowVisible,
      isHealthy,
    };
  }
}
