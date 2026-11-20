# islandcn engine (`island-core`)

A Dynamic Island-style pill for React. It depends on React and React DOM only: the springs, the shape and the crossfades are solved in these files.

## Quick start

```tsx
import { Island, IslandProvider, useIsland } from "@/lib/island";

// The island draws at the top centre of its nearest positioned ancestor.
<IslandProvider>
  <div style={{ position: "relative" }}>
    <Island />
    <Checkout />
  </div>
</IslandProvider>;

const Checkout = () => {
  const island = useIsland();
  const pay = () => {
    const upload = island.start({
      id: "payment",
      label: "Payment processing",
      compact: { leading: <CardIcon />, trailing: <Spinner /> },
      minimal: <Spinner />,
      expanded: { leading: <CardIcon />, center: "Processing", trailing: "$42", bottom: <Progress value={0.3} /> },
    });
    upload.update({ compact: { trailing: <Check /> }, alert: true });
    setTimeout(() => upload.end(), 3000);
  };
  return <button onClick={pay}>Pay</button>;
};
```

On a desktop page, pin it to the window instead: `<Island placement="viewport" />`. Wider containers clamp the island to phone width (402 pt), so the expanded view is 374 wide everywhere.

## Presentations

| Presentation | When | What draws |
| --- | --- | --- |
| `idle` | No activity | The resting pill (94.85 x 36.84, 13.91 from the top) |
| `compact` | One activity | `compact.leading` left of the sensor, `compact.trailing` right of it. Each side fits its own content, but neither reaches less than `metrics.compact.balance` (0.7475) of the other; the short side grows and its content stays at the outer edge |
| `minimal` (the split) | Two activities | Both pills show their activity's compact content, as on iOS 27: the primary's `compact.leading` and `compact.trailing` side by side left of the sensor (the pill ends at the sensor's right edge and grows left), the second's in a detached capsule 7.82 to the right, which pinches off with a gooey neck. The capsule is 62.18 wide whatever its trailing content, which sits centred after the leading content and ends in an ellipsis when it is wider. When the content is too wide (`metrics.split.maxSpan`), each pill falls back to its `minimal` view |
| `expanded` | Long-press, `expand()`, or an alerting update | 374.34 wide on a phone, 13.83 from the sides and top; `leading`, `center`, `trailing` on the top row (all top-aligned: give content its own frame to centre it) and `bottom` below. Height follows the content (84 to 180) |

Primary means highest `priority`, then first started, among the activities on show: activities that share a `group` show one at a time. `minimal` falls back to `compact.leading`. On the iOS 27 simulator the split never showed `minimal`; it stays as the fallback for content that doesn't fit.

## API

```ts
// Provider: owns the activity stack and the clock.
interface IslandProviderProps {
  children: ReactNode;
  clock?: IslandClock;                       // read once; default requestAnimationFrame
  devtools?: boolean | { sequences?: Record<string, IslandSequence> }; // default false
  metrics?: IslandMetricsOverrides;          // deep-partial overrides of islandMetrics
  motion?: IslandMotionOverrides;            // deep-partial overrides of islandMotion
  reducedMotion?: "user" | "always" | "never"; // default "user"
}

// The stack-driven island.
interface IslandProps {
  placement?: "container" | "viewport";      // default "container"
  label?: string;                            // region name, default "Live activities"
  className?: string;
  style?: CSSProperties;
  keyline?: "auto" | "on" | "off";           // default "auto"
  backdrop?: string;                         // page colour behind the island, sets keyline strength
}

const useIsland: () => IslandApi;            // subscribes
const useIslandActions: () => IslandApi;     // same API, never re-renders the caller
const useIslandReducedMotion: () => boolean;

interface IslandApi {
  start(options: ActivityOptions): ActivityHandle; // same id again updates it
  update(id: string, update: ActivityUpdate): void;
  end(id: string): void;                     // dismiss with the system motion
  expand(id?: string): void;                 // default: the primary activity
  collapse(): void;
  readonly activities: readonly Activity[];  // primary first, hidden group members included
  readonly presentation: "idle" | "compact" | "minimal" | "expanded";
}

interface ActivityOptions {
  id: string;
  label?: string;                            // spoken by screen readers, default the id
  priority?: number;                         // default 0
  onPress?: () => void;                      // tap (shorter than a long-press)
  alert?: boolean;                           // expand briefly on start
  group?: string;                            // share a group to show one at a time (one app's activities)
  compact?: { leading?: ReactNode; trailing?: ReactNode };
  minimal?: ReactNode;
  expanded?: { leading?: ReactNode; trailing?: ReactNode; center?: ReactNode; bottom?: ReactNode };
}

// Partial: nested content merges, so { compact: { trailing } } keeps the leading slot.
interface ActivityUpdate {
  compact?: { leading?: ReactNode; trailing?: ReactNode };
  minimal?: ReactNode;
  expanded?: { leading?: ReactNode; trailing?: ReactNode; center?: ReactNode; bottom?: ReactNode };
  label?: string;
  priority?: number;
  onPress?: () => void;
  alert?: boolean;                           // expands with the old content, applies this after motion.alertContentDelay, back after motion.alertHold
  transition?: "update" | "crossfade";       // default "update" (in place)
}

interface ActivityHandle {
  readonly id: string;
  update(update: ActivityUpdate): void;
  end(): void;
}

// One presentation, controlled, without the stack. Not pressable. For docs, Studio, captures.
interface IslandViewProps {
  presentation:
    | { kind: "idle" }
    | { kind: "compact"; leading?: ReactNode; trailing?: ReactNode }
    | { kind: "minimal"; attached: ReactNode; detached?: ReactNode; split?: { attached: CompactContent; detached: CompactContent } }
    | { kind: "expanded"; leading?: ReactNode; trailing?: ReactNode; center?: ReactNode; bottom?: ReactNode };
  contentKey?: string;                       // new key crossfades, same key updates in place
  pressed?: boolean;                         // the hold squish
  placement?: "container" | "viewport";
  label?: string;
  liveLabel?: string;
  clock?: IslandClock;
  metrics?: IslandMetricsOverrides;
  motion?: IslandMotionOverrides;
  reducedMotion?: "user" | "always" | "never";
  className?: string;
  style?: CSSProperties;
  keyline?: "auto" | "on" | "off";           // default "auto"
  backdrop?: string;                         // page colour behind the island
}
```

`IslandView` works inside or outside a provider. Inside, it uses the provider's clock, metrics and motion.

## Groups

Activities that share a `group` show one at a time, as one app's Live Activities do on iOS. The first started shows and the others wait hidden (`activities` still lists them).

- An alert on a hidden one hands over: the shown one leaves to idle with the dismiss motion, the island stays idle for `motion.group.handoff` (1.445 s), then expands the alerting one from idle, already showing its update, and returns to it compact `motion.group.window` (6.014 s) after the departure. The one that left stays hidden until it is brought forward again.
- `expand(id)` on a hidden one brings it forward without the pause. Ending the one brought forward shows the first started again.
- Without `group`, every activity shows, as before.

## Interaction and accessibility

- The island is a `region` with a label. The pill is a real `button` named after the activity, with `aria-expanded`. A polite live region reads the activity labels when they change.
- Every press swells the pill from touch-down: a uniform scale about its centre, about 97 pt/s in width, toward x1.12. Content scales with it.
- Still held at `motion.press.decide` (0.1 s), the press is a long-press: the island expands at `motion.longPress` (0.22 s after touch-down), from the swollen shape and with its speed, even if the finger lifts in between. Hold the detached capsule to expand the second activity: only the capsule swells, then its content goes black, it joins the pill and the island expands through about idle size.
- Released before 0.1 s, it is a tap: `onPress` runs on release, and the swell turns back at `motion.press.tapReturn` (0.22 s) on an overdamped spring (`motion.press.release`, 0.30 / 1.5), at rest by about +0.9 s.
- The idle island swells the same way and springs back at `motion.press.holdReturn` (0.236 s), even with the finger down: it has nothing to expand. Its height returns on `motion.press.idleRelease`, while its width runs on: it widens about 1.1 pt on `motion.press.idleWiden` and comes back about 0.57 s after the turn, as the simulator's idle pill does. Its hit area is hidden from assistive tech, since it does nothing.
- These timings come from reference round 2, which timed the touch with an on-screen marker. Round 1's 0.5 s long-press came from host command times that carry 0.3 to 1 s of latency, so round 2 wins. A controlled `IslandView pressed` squishes gently instead.
- Enter or Space toggles expanded. Escape, or a press outside the island, collapses it. Focus inside content that goes away moves back to the pill.
- Expanded content takes pointer events and focus, so buttons inside it work.
- `prefers-reduced-motion`: the shape eases over 0.2 s with no overshoot, and content crossfades with no blur or scale.

## Motion

Springs use SwiftUI's parameters and are solved in closed form (`spring.ts`): `response` is the undamped period in seconds and `dampingFraction` the damping ratio. A retarget starts the new spring from the current value and velocity, so interrupting expand with collapse never jumps. `blendDuration` blends from the motion in flight into the new spring.

Every value in `motion.ts` is fitted to the iPhone 18 Pro simulator (iOS 27) with this solver (`scripts/fidelity/fit.ts`) and names the take it came from. Each presentation change picks a transition (`ShapeTransition`), and `choreography.ts` turns it into springs per property:

| Transition | When | Shape |
| --- | --- | --- |
| `appear` | idle to compact | edges 0.483 / 0.62 (8 to 11% overshoot) |
| `expand` | compact to expanded, same activity (alert, `expand()`) | edges 0.517 / 0.824, height 0.497 / 0.825 |
| `pressExpand` | the same out of a long-press swell | 0.387 / 0.792, starting from the swollen shape and its speed |
| `appearExpand` | idle straight to expanded (an activity that starts with `alert`) | 0.54 / 0.811 |
| `swap` | to expanded for another activity than the one showing, or from the split | edges aim at idle, retarget after 0.231 s; height waits for the retarget. From the split the bubble joins as a lobe (as in `unsplit`), is gone at the retarget, and the retarget comes at the unsplit's 0.203 s (the turn of any change that absorbs the bubble) |
| `collapse` | expanded to compact | edges aim at idle on 0.479 / 0.894, retarget after 0.311 s on 0.46 / 0.555 (the waist to about 105 wide and the bounce back); height 0.453 / 0.928; top lifts 1.4 |
| `alertCollapse` | expanded to compact when an alert's hold runs out | as `collapse`: edges 0.535 / 0.84, retarget after 0.29 s on 0.466 / 0.59; height 0.481 / 0.908; top lifts 1.4 |
| `collapseSplit` | expanded to the split | an alert's return starts 0.045 s late (`lag`), a press outside at once; the whole right side shrinks as one tall blob to about 290, the bubble sits at its place inside it, then the pill pulls back to the sensor (0.3 / 1) and that pinches the bubble off (frame 854); the attached pill settles 5.5 wider on the left first; height 0.45 / 0.9 |
| `split` | compact to the split | edges through idle (retarget 0.215 s); the bubble's right edge rides the same spring, its left edge springs out of the pill (0.376 / 0.811 from +0.345 s) and pinches off at about +0.53 s |
| `unsplit` | split to compact | the bubble's left edge closes the gap within a tick (the neck), the bubble slides left under the sensor as its own lobe (0.38 / 1) and is gone at +0.19 s; the pill contracts through idle (retarget 0.203 s) |
| `dismiss` | to idle | 0.442 / 0.97 |
| `resize` | content changed size in place | 0.5 / 0.82 |

Content follows the container. Each layer is laid out for its own resting shape; while the shape morphs, every slot keeps its centre at the same fraction of the current shape's width and height, and scales by (width ratio x height ratio) ^ (`metrics.content.follow` / 2). On the simulator the compact circle grows and slides toward the expanded square as the island opens, and expanded content shrinks inside the island as it closes, so content always fits the outline and is never cut by it while it is still sharp. The expanded view moves its four regions separately.

On top of that, layers crossfade per transition (`motion.contentTiming`). The outgoing and incoming layers overlap, so the island never shows an empty black interval. Presence p drives blur ((1 - p) x `blur` px), scale (from `scale`) and opacity (p ^ `fade`: a `fade` under 1 keeps a layer bright while it blurs, as iOS does). `bubbleDelay` holds the detached bubble's content back further than the attached pill's (split: blue shows from about +0.39 s). `bubbleExit` (optional, defaults to `exit`) takes the bubble's content out on its own timing when the bubble joins the pill: `swap` from the split cuts it 0.023 s before the join (a negative `delay`: a decided long-press on the bubble knows when it will join; any other swap cuts at its start), so the lobe is black as it merges, while unsplit blurs it out with the rest. The timings are fitted on colour mass, blur width and position per frame with `scripts/fidelity/content.py`.

The sensor housing (the idle capsule, `metrics.sensor`) is drawn above the content and never moves. Content that slides under it is hidden there, which is the crescent a fading circle leaves on iOS in dismiss, split, unsplit and collapse.

An alerting update (`update({ ..., alert: true })`) expands with the content the activity had, then applies the update in place `motion.alertContentDelay` (0.12 s) after the expansion starts, as iOS does: the bar starts moving then, and a changed digit waits a little longer (`numberMotion.inDelay`).

Frames never re-render React. The frame loop writes the SVG path, the content transforms and the clip path directly.

## Content primitives

Live Activities animate content that changes in place. Two primitives do the same on the island's clock, so captures stay exact:

```tsx
import { IslandNumber, IslandProgress } from "@/lib/island";

<IslandNumber value={43} style={{ fontSize: 34, fontWeight: 700 }} />; // changed digits turn over with a blur
<IslandProgress value={0.8} color="#30D158" track="#414141" height={8} />; // the fill eases to the new value
```

`IslandNumber` aligns the old and new text from the right and turns over only the characters that changed: the old one shrinks to 0.7 and blurs over the first 0.21 s, still bright, then fades out by +0.26 s; the new one starts at +0.2 s, fades in over 0.08 s, grows from 0.72 over 0.25 s and sharpens linearly, sharp by +0.48 s (alert-t1, frames 261 to 287). `numberMotion` holds the timing. Its characters are plain inline text, so a slot that cuts text to fit (the split capsule) ends it in an ellipsis, as it does a string. `IslandProgress` springs its fill (response 0.97, damping 0.74 by default, fitted on alert-t1). Under reduced motion a changed digit crossfades over 0.08 s and the fill eases over 0.2 s.

## Hooks

- `useIsland()` subscribes: the caller re-renders when activities or the presentation change.
- `useIslandActions()` returns the same API without subscribing, for components that only start, update and end activities.
- `useIslandReducedMotion()` returns whether the island runs reduced motion (the provider's setting resolved against the system's).

## Updates

`update(content)` changes content in place: same layer, and primitives like `IslandNumber` animate the change. `update({ ..., transition: "crossfade" })` replaces the layer with the transition's blur and fade instead, for content that is different rather than newer (a new track, a new step). Compact slots never grow past `metrics.compact.maxSlotWidth`: a plain string ends in an ellipsis, other content is clipped at that width. In the split capsule, text wider than its room ends in an ellipsis whatever wraps it (a string, an `IslandNumber`, a span), and other content is clipped.

## Keyline

On dark pages the simulator draws a thin grey band just outside the black edge (1.5 pt, white at 0.16 over #000, fading to nothing by about #2C2C2E). `<Island keyline backdrop>` and `<IslandView keyline backdrop>` control it:

- `keyline`: "auto" (default) draws it when `backdrop` is dark, or in dark mode when no `backdrop` is given (assuming a near-black page); "on" draws it whatever the scheme; "off" never.
- `backdrop`: the page colour behind the island, hex or rgb(). Its luma sets the strength (`metrics.keyline`).

It shows on compact, the split (both pills), the bubble and expanded (7% weaker there), never on idle, and dims to 15% and back over 1.1 s during a collapse (`motion.keyline`).

## Shape

The shape is one SVG with three paths: the pill, the detached capsule and the neck between them. Every outline has continuous corners, as measured: a circular arc with eased transitions into the straight edges (`metrics.corner.smoothing`, 0.72), each edge using only the smoothing that fits in half its length, so capsules keep round ends with soft shoulders. The expanded island's arc is r = 47.9 (`metrics.expanded.radius`). Smoothing 0 draws plain circular corners, and then `metrics.expanded.cornerAspect` and `cornerExponent` draw superellipse corners if you override them. Content is clipped to a rounded rectangle concentric with the island whose corner radius is capped at `metrics.contentClip.radius` (34.4): on the expanded island that arc cuts the square's corner and the bar's ends as on the simulator, and capsules are not inset at all. (`contentClip.chamfer` above 0 restores the old 45-degree cut.) The neck is an analytic metaball path that thins to nothing as the gap reaches `metrics.bridge.maxGap` (5), so edges stay crisp at rest. The expanded island casts a two-layer shadow drawn by one SVG filter (`metrics.expanded.shadow`): a key layer 10.7 down with a 30.76 blur at 0.353, and a faint tail 23.4 down with an 81 blur at 9% of that, both a little wider than tall (`aspect`). Its strength follows the expansion. It was fitted to the median of every iOS take's expanded rest through the recorder's path, light and dark stage at once, and every band around the island is within 1.07 levels of iOS (`scripts/fidelity/REST.md`).

## Tables

All geometry lives in `metrics.ts` (`islandMetrics`) and all timing in `motion.ts` (`islandMotion`), both measured on the iPhone 18 Pro simulator (track A's `reference/MEASUREMENTS.md`). Override per app with the provider's `metrics` and `motion` props.

Additions in this round (all optional for overrides; existing keys keep their meaning):

- `metrics.split` (iOS 27 split layout and `maxSpan`), `metrics.compact.innerPadding`, `metrics.expanded.top`, `metrics.expanded.bottomInset`, `metrics.contentClip.chamfer`, `metrics.press.swell`.
- `motion.body`, `motion.viaIdle`, `motion.retarget`, `motion.collapseLift`, `motion.contentTiming`, `motion.bubble.collapseSplit`, `motion.press.swell` and `motion.press.swellTime`. `motion.shape` is still the edge spring per transition; `ShapeTransition` gained `pressExpand`, `appearExpand`, `swap` and `collapseSplit` (all listed in the exported `shapeTransitions`).
- The `minimal` presentation takes an optional `split` with both activities' compact content.

Additions in the fidelity round (ICN-3, judge round 1), all optional:

- `metrics.content.follow`, `followMin`, `followMax`; `metrics.sensor`; `metrics.keyline`; `metrics.contentClip.radius` (the clip is now concentric with a capped radius; `chamfer` defaults to 0).
- `motion.contentTiming[*].fade`, `exitFade`, `bubbleDelay` and `bottomAnchor` (how far expanded content follows the card's bottom edge while it grows or shrinks); round 31 adds `trailingRide` (the trailing slot keeps its distance from the pill's right end), `trailingExitAnchor` (the leaving text slides in under the sensor), `partStep` (the attached slots step toward the bubble as it parts), `follow` (a transition's own content follow) and `bubbleExitAccent` (cut the bubble's accent, let its text blur out); `motion.press.decide`, `release`, `idleRelease`, `idleWiden`, `tapReturn`, `holdReturn`; `motion.alertContentDelay`; `motion.keyline`; `motion.lag`; `motion.bubble.unsplitSlide`, `unsplitAbsorb`, `collapseSplitVia`, `collapseSplitSpread`.
- Judge round 6: `motion.bubble.collapseSplitLift` (the pill lifts about 1.1 pt during the return into the split, the bubble stays) and `motion.bubble.collapseSplitSpread.rightPeel` (the body's right edge pulls in under the bulb ahead of the bubble's). Overrides are optional like the rest; a full `IslandMotion` object needs both.
- Changed values: `metrics.expanded.bottomInset` 2.5 to 0 (the clip's arc hides the bar's ends, which is what made it look inset), `motion.bubble.split.delay` 0.327 to 0.345 (the rendered neck breaks early).
- Changed meaning: `motion.longPress` is now 0.22 s from touch-down (was 0.5 s) and `motion.press.swellTime` 0.22 (the swell starts at touch-down). `metrics.expanded.centerTop` is now extra space below the sensor's bottom edge, where the center region starts (ActivityKit's rule); before, it was extra space above a center region centred on the top row.
- New exports: `IslandNumber`, `IslandProgress`, `numberMotion`, `useIslandActions`, `useIslandReducedMotion`, `colourLuma`, `keylineAlphaFor`, `KeylineSetting`. `ActivityUpdate.transition`. `Island` and `IslandView` take `keyline` and `backdrop`.

Additions from the held-out set (ICN-3), all optional for overrides. Every rule fits both the tuning content (A and B) and the held-out content (W) with one set of numbers:

- `ActivityOptions.group` and `Activity.group`: activities sharing a group show one at a time, as one app's Live Activities do on iOS. The first started shows; an alert on a hidden one hands over (the shown one leaves to idle, the island waits `motion.group.handoff`, expands the alerting one, and returns to it compact `motion.group.window` after the departure; the one that left stays hidden). `expand(id)` on a hidden one brings it forward. `activities` still lists hidden ones. Without `group` nothing changes.
- `metrics.compact.balance` (0.7475): when both compact sides have content, neither reaches less than this fraction of the other beyond the sensor. The short side grows and its content stays at the pill's outer edge. 0 restores sides that fit their own content only.
- `metrics.split.detached.width` (62.18), `slotGap`, `slotEnd`: the bubble keeps one width whatever its trailing content; that content is centred between `slotGap` after the leading content and `slotEnd` before the edge, and text wider than that room ends in an ellipsis (other content is clipped). `width` 0 restores the content-sized bubble (`gap`, `trailingPadding`).
- The expanded top row is top-aligned: leading and trailing start at the padding beside the sensor, whatever the center's height. Content that should sit centred brings its own frame, as a SwiftUI region does (the lab's A trailing is `frame(height: 52)`, like the sample app's).
- A long-press on the bubble swells only the bubble (the attached pill holds still), and the swap to its expanded view absorbs the bubble as a lobe, as unsplit does, until the shape turns toward expanded.
- `motion.group` (`handoff` 1.458, `window` 6.014). Changed meaning: `motion.lag` now applies only to an alert's return (a press outside starts the same motion at once).

Round 9 (ICN-3), timing only, no new fields:

- A change that absorbs the bubble as a lobe turns toward its target when the lobe is gone: at `motion.viaIdle.unsplit` (0.203 s) toward compact (unsplit-t1, `scripts/fidelity/fit-turn.ts absorb`), at `motion.bubble.absorbExpand` (0.214 s, round 16) toward an expanded view (the long-press on the bubble, fitted to the median of split-expand-b-t1, t2, t9 and t10 with `scripts/fidelity/fit-open.ts`). The body and corner wait for that turn.
- `ContentMotion.absorb` (optional): the incoming layer's `enter` and `centerDelay` on a change that absorbs the bubble. `swap` brings the expanded view in 0.025 s sooner on a slower spring (0.35) with the center held 0.045 s, so the long-press's circle shows faint and blurred first and the title stays soft longer, as iOS does; a swap out of a single pill keeps `enter`.
- `motion.viaIdle.swap` 0.236 to 0.231, `body.swap.delay` 0.236 to 0.231, `corner.swap.delay` 0.268 to 0.263, `lag.collapseSplit` 0.05 to 0.045: the same moments in split-alert-t1, measured from the lab's aligned event (5.1 ms later; `scripts/fidelity/README.md`, "Event alignment").
- `motion.group.handoff` 1.458 to 1.449: swap-t2's expansion from idle was 6 ms late.

Round 10 (ICN-3), judge round 9, no change for existing overrides:

- `ContentMotion.bubbleExit` (optional, defaults to `exit`): how the bubble's content leaves when the bubble joins the pill. `swap` cuts it (`response` 0) 0.023 s ahead of a long-press's join (`delay` -0.023), as split-expand-b-t1 goes black 15 to 31 ms before it merges; other transitions are unchanged.
- `IslandNumber` renders its characters as plain inline text (was `inline-flex`), so the split capsule ends a long number in an ellipsis ("4…") instead of clipping it mid-digit.

Round 14 (ICN-3), content texture, no change for existing overrides (`scripts/fidelity/BLUR.md`):

- Changed values: every `contentTiming[*].blur` (the leaving layer's peak blur) is 0.55 to 0.75 of what it was (`pressExpand` 16 to 10.5, `expand` 14 to 9.5, `appearExpand` 12 to 8, `collapse` 12 to 7, `alertCollapse` 12 to 8.5, `collapseSplit` 10 to 7, `swap` 10 to 8, `split` 8 to 5.5, `unsplit` 8 to 6, `dismiss` 6 to 4.5, `resize` 8 to 5.5); incoming blurs (`enterBlur`, `bubbleBlur`) keep theirs. The blur of the sharpest edge left in the leaving content read 1.2 to 2.0 times iOS's at the same moment on every transition. `pressExpand.sharpen` 1 to 1.2 (the title is sharp about two frames sooner). `collapse`: `exitFade` 1 to 0.6 and `enter.delay` 0.38 to 0.36 (the expanded content stays bright into the shrink; the circle comes back sooner).
- `ContentMotion.bubbleStretch` (optional, defaults to 0): the bubble's incoming content is stretched across by 1 + `bubbleStretch` x (1 - presence) ^ `sharpen`, its height unchanged, so the returning circle comes back as a horizontal patch cut by the sensor and narrows into the circle. `collapseSplit` uses 0.8 with `bubbleSpread` 2.2 to 1 and `bubbleDelay` -0.055 to -0.065.

Round 17 (ICN-3), content on one blur, no change for existing overrides (`scripts/fidelity/CONTENT.md`):

- An expanded layer blurs as a whole after its content clip, and the island's outline cuts the container: the clip's cut on the square and the bar softens with the rest, as on iOS. Other layers keep their order (blur per slot, then the clip).
- `ContentMotion.regions` (optional): per expanded region, `fade` and `blur` lag its opacity and its blur in seconds, and `soften` keeps it blurrier until the end. A listed center ignores `centerDelay`. `expand`, `pressExpand`, `appearExpand` and `swap` (and its `absorb`) now sharpen the center with the rest and only lag its opacity (0.04 to 0.1 s; `appearExpand` 0.07); `expand` and `pressExpand` lag the number's 0.03 s.
- `ContentMotion.anchor` below 0 pushes the compact leading slot toward the island's end while it comes in. `collapse`, `alertCollapse` and `unsplit` use -2.
- Changed values: `expand.fade` 1 to 1.8; `appearExpand.sharpen` 1 to 0.85; `alertCollapse.exit` 0.24 / 1 to 0.26 / 0.8 (underdamped, so the leaving card ends instead of tailing off).
- `resolveMotion` keeps a `bubbleBlurMax` override (it dropped it before).

Round 18 (ICN-3), the bubble's return, entries from idle and the shadow's ramp, no change for existing overrides (`scripts/fidelity/R18.md`):

- `ContentMotion.bubbleOrigin`, `bubbleHold` and `bubbleFade` (optional): the bubble's incoming content grows about a point on its row (0 its top) instead of riding the collapsing shape's middle, holds that larger, stretched form until presence `bubbleHold`, then resolves on `bubbleSharpen`'s power; `bubbleFade` is its own opacity power. `collapseSplit` uses origin 0, hold 0.55, fade 1.5, `bubbleScale` 1.25 to 1.5, `bubbleStretch` 0.55 to 0.27 and `bubbleDelay` -0.065 to -0.085: the returning circle keeps its top near the row's top while the row cuts its bottom, and the sensor bites it along its whole end.
- `ContentMotion.bubbleResolve` (optional, defaults to `bubbleSharpen`): the power the bubble's returning form (its scale and `bubbleStretch`) resolves on past `bubbleHold`, apart from its blur's. `collapseSplit` uses 2 under its blur's 1.2 (round 22: the green patch narrows into the circle over about ten frames, as on split-collapse-b-t1, t2, t9).
- `ContentMotion.afterAlert` (optional): `enter`, `bubbleDelay`, `bubbleFade`, `bubbleResolve` and `bubbleTrailingFade` for a change that leaves an alert whose hold ran out, over the transition's own. `collapseSplit` brings split-alert's content in 15 ms later than a press outside and its bubble text on presence ^ 10 (round 22: iOS's "7" shows nothing until +846 on split-alert-t1, t2, t9).
- `islandMotion.shadowRamp` (new, a spring, 0.36 / 1): out of a capsule the expanded shadow eases in from the change's start and is the lesser of that and the expansion, so it trails the opening shape as on iOS. Collapses keep following the shape.
- Changed values: `appearExpand.enter` 0.3 / 0.055 s to 0.36 / 0.02 s and `swap.enter` 0.3 / 0.3 s to 0.36 / 0.26 s (content shows while the card opens from idle; `swap`'s title lags 0.08 s, was 0.04); `pressExpand.trailingExitPower` 1 to 1.5; `metrics.minimal.attached` gap 7 to 5.65 and inner padding 6.83 to 8.18 (the same pill, the trailing text 1.35 pt closer to the leading).

Round 26 (ICN-3), centred on every seen take (canonical, -t1/-t2/-t3, -t9/-t10, -t11/-t12, -t13/-t14), no change for existing overrides (`scripts/fidelity/R26.md`):

- `islandMotion.alertHoldIdle` (optional, defaults to `alertHold`): the hold of an alert that starts an activity on an idle island, 5.969 s (appear-alert's takes return about 6 ms sooner than alert's). An override of `alertHold` alone moves it too.
- Changed values: `longPress` 0.214 to 0.216, `longPressBubble` 0.22 to 0.224, `group.handoff` 1.449 to 1.445; `alertCollapse.exit` 0.26 / 0.8 from 0.045 s to 0.30 / 0.8 from 0.03 s; `dismiss.exitSharpen` 2.5 to 2, `exitFade` 0.85 to 0.7, `trailingExitPower` 1 to 1.5; `split.exit` 0.2 to 0.3 s with `exitScale` 1, `exitBlur` 10 and `exitFade` 0.8 to 0.6; `swap.exit` 0.4 to 0.33 s with `exitSharpen` 0.6; `unsplit.trailingExitPower` 1 to 1.5 and a `bubbleExit` of 0.08 s from 0.04 s. `bubble.unsplitSlide` 0.38 to 0.42 s, `unsplitAbsorb` 0.19 to 0.205 s. `viaIdle.swap` 0.231 to 0.223 with `body.swap.delay` 0.223 and `corner.swap.delay` 0.255, `swap.enter.delay` 0.26 to 0.252 (split-alert's B out of idle). Leaving content now stays bright and spreads where iOS's does, so the sensor cuts it.

Round 28 (ICN-3), centred on every seen take with -t19/-t20 added, no change for existing overrides (`scripts/fidelity/R28.md`):

- `bubble.absorbExpandCorner` (optional, a delayed spring, defaults to `corner.swap` with its wait after the swap's turn): the corner of the opening that absorbs a long-pressed bubble, from that change's turn. 0.49 / 0.826 from 0.001 s: at equal height iOS's growing island keeps near-capsule ends (R 0.97 of half its height at 44 pt, 0.93 at 60).
- `bubble.joinLead` (optional, defaults to 0): a long-press on the bubble is decided before the bubble joins the pill, and the join's shape (the bubble's left edge closing on `bubble.unsplit`, the merge's neck) starts this long ahead of it, 0.012 s. The turn and the content keep their time. `ShapeAnimation.joinFrom` carries it; `leadJoin` (choreography) sets it for the surface and the sim.
- Changed values: every opening's corner spring, refitted at equal height on all seen takes (`scripts/fidelity/fit-corner-h.ts`): `corner.expand` 0.464 / 0.847 / 0.022 to 0.448 / 0.87 / 0.018, `pressExpand` 0.328 / 0.816 / 0.024 to 0.32 / 0.831 / 0.019, `appearExpand` 0.519 / 0.836 / 0.017 to 0.452 / 0.865 / 0.02, `swap` 0.419 / 0.886 / 0.255 to 0.41 / 0.888 / 0.244; `appear.sharpen` 1 to 1.35 (incoming compact content sharp sooner); `split.trailingEnter.delay` 0.37 to 0.375 and `split.bubbleTrailingFade` 1.2 to 1.6.

How each rule was found and what it fits: `scripts/fidelity/HELDOUT.md`, "Rules this round added". Not adopted: a content-dependent appear damping (W appears with ζ 0.72, A with 0.63), for want of evidence that tells a rule from a fit to two contents.

## Clock and devtools

All motion reads time from an `IslandClock`:

```ts
interface IslandClock {
  now(): number;                                         // ms
  onFrame(onFrame: (now: number) => void): () => void;   // per frame until unsubscribed
  at(at: number, run: (due: number) => void): () => void; // timer on island time
}
```

`createFrameClock()` returns the default `requestAnimationFrame` clock, which you can pause, step and seek (`ControllableClock`). With `<IslandProvider devtools={{ sequences }}>`, `window.__islandcn` exposes:

```ts
interface IslandDevtools {
  pause(): void;
  resume(): void;
  step(ms: number): number;        // advance paused time, firing timers at their exact times
  seek(ms: number): number;        // replays the loaded sequence from 0, so the frame is exact
  play(name: string, options?: { paused?: boolean }): { duration: number };
  now(): number;
  setTimeScale(scale: number): void;
  readonly sequences: readonly string[];
  presentation(): "idle" | "compact" | "minimal" | "expanded";
  stats(): FrameStats;             // frame gaps and per-frame work while animating
  clearStats(): void;
}

interface IslandSequence {
  setup?: (island: SequenceIsland) => void;  // runs instantly before time 0
  events: readonly { at: number; run: (island: SequenceIsland) => void }[];
  duration: number;                          // ms
}
// SequenceIsland is IslandApi plus press(target?: "pill" | "bubble") and release().
```

State changes made by timers render synchronously under devtools, and springs start at the event's clock time rather than the render time. The same build therefore produces the same pixels for the same frame on every run. Leave devtools off in production.

## Files

| File | What |
| --- | --- |
| `index.ts` | Public exports |
| `provider.tsx`, `island-root.tsx`, `view.tsx`, `use-island.ts` | React API |
| `store.ts` | Activity stack, alerts, long-press, scene derivation |
| `surface.tsx`, `layer.tsx`, `frame.ts` | Renderer: frame loop, content layers, per-frame geometry |
| `geometry.ts` | Target shape for each presentation, and which transition a change uses |
| `choreography.ts` | Springs per property for each transition: through idle, the swell hand-off, the bubble pinch and merge |
| `path.ts` | Rounded rectangles, capsules, the content mask, the metaball neck |
| `spring.ts` | Closed-form springs, `AnimatedValue` |
| `clock.ts`, `devtools.ts`, `perf.ts` | Clock, `window.__islandcn`, frame timing |
| `platform.ts` | Apple's WebKit: blurred content as its own layer, CSS shadows in place of the SVG filter |
| `primitives.tsx` | `IslandNumber`, `IslandProgress` |
| `metrics.ts`, `motion.ts`, `config.ts` | The two tables and their override merge |
| `types.ts`, `context.ts` | Shared types, React context, reduced-motion hook |
