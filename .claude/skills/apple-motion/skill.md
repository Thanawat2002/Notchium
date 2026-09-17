---
name: apple-motion
description: Motion and animation rules for SwiftUI/AppKit UI in this project. Use whenever writing or editing any view that expands, collapses, appears, disappears, moves, resizes, or reacts to hover — including the notch island, panels, notifications, and controls. Also use when reviewing existing animation code, tuning timing, or when an animation "feels off", janky, laggy, or cheap.
---

# Apple-style motion

The goal is motion that feels like it belongs in macOS — responsive, physical,
and quiet. Users should never consciously notice the animation; they should only
notice that the UI feels good.

## 1. Springs by default

Use spring for anything that changes **size, position, or shape**. Use easing
only for **opacity and color**.

```swift
// ✅ geometry
.animation(.spring(response: 0.38, dampingFraction: 0.78), value: isExpanded)

// ✅ opacity
.animation(.easeOut(duration: 0.18), value: isVisible)

// ❌ never
.animation(.easeInOut(duration: 0.3), value: size)   // geometry with easing = rubbery
.animation(.linear, value: anything)                  // linear reads as robotic
```

Reason: real objects have mass. `easeInOut` decelerates into a dead stop, which
is why it looks cheap on anything that moves.

## 2. Named tokens — use these, do not invent new numbers

Define once in `Motion.swift` and reference everywhere:

| Token | Value | Use for |
|---|---|---|
| `Motion.expand` | `.spring(response: 0.38, dampingFraction: 0.78)` | island opening, panel growing |
| `Motion.collapse` | `.spring(response: 0.28, dampingFraction: 0.85)` | island closing, panel shrinking |
| `Motion.snappy` | `.spring(response: 0.22, dampingFraction: 0.9)` | button press, toggle, chip state |
| `Motion.fadeIn` | `.easeOut(duration: 0.18)` | content appearing |
| `Motion.fadeOut` | `.easeIn(duration: 0.12)` | content leaving |

**Collapse is always faster than expand** (roughly 30%). Opening can afford to
be leisurely because the user is arriving; closing must get out of the way.

If a new situation genuinely needs different timing, add a token to the table —
do not inline a one-off spring in a view.

## 3. Stagger content, never reveal it all at once

The container resizes first; its contents arrive in layers behind it.

Order for the notch island: **container → artwork → text → controls**

```swift
.opacity(isExpanded ? 1 : 0)
.offset(y: isExpanded ? 0 : 6)
.animation(Motion.fadeIn.delay(isExpanded ? delay : 0), value: isExpanded)
```

Delays when expanding: artwork `0.08`, text `0.16`, progress `0.20`,
controls `0.24`. When collapsing, **all delays go to 0** — content leaves
together and instantly, then the container closes.

Keep total choreography under ~400ms. Past that it stops feeling responsive and
starts feeling slow.

## 4. Never fully erase an element mid-animation

- Do not scale to `0`; floor it at `0.35`–`0.9` depending on the element
- Do not combine `opacity: 0` with `scale: 0` — the element vanishes rather than leaves
- Do not animate `frame` to `0` height or width; hide the parent instead

Elements should look like they moved out of view, not like they were deleted.

## 5. Interruptibility

Every animation must survive being reversed halfway through. If the user hovers
out while the island is still opening, it must smoothly turn around from wherever
it is — not jump, not finish opening first.

- Drive animation from **state**, never from `DispatchQueue.main.asyncAfter`
- Never chain animations with completion handlers to build a sequence; use
  `.delay` on each element instead
- Never use `withAnimation` inside `onChange` of a value that is itself animated

## 6. Hover behaviour

- Expanding on hover: no delay, fire immediately
- Collapsing on hover-out: wait **0.25s** before collapsing, and cancel the
  timer if the pointer returns. Without this the island flickers when the
  pointer crosses a corner.
- The hover target when expanded must cover the full expanded shape plus ~4pt,
  or the island will collapse while the user is reaching for a button

## 7. Shape changes count as motion

Corner radius, blur radius, and shadow opacity all animate with the same spring
as the size change, never separately. If the island grows with `Motion.expand`,
its corner radius uses `Motion.expand` too. Mismatched timing on shape is the
most common reason an expansion looks "wrong" without an obvious cause.

## 8. Respect the system

```swift
@Environment(\.accessibilityReduceMotion) private var reduceMotion

var animation: Animation? {
    reduceMotion ? nil : Motion.expand
}
```

When reduce-motion is on: no springs, no offsets, no scaling. Cross-fade only,
or no animation at all. Never ship an animation that cannot be turned off.

## 9. Window-level animation (AppKit)

SwiftUI animation cannot resize an `NSPanel`. When the panel itself must change
size, keep the panel at its **maximum size permanently** and animate only the
SwiftUI content inside it. Resizing the window per frame causes visible tearing
and drops frames.

If the panel truly must be resized, use:

```swift
NSAnimationContext.runAnimationGroup { ctx in
    ctx.duration = 0.25
    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
    ctx.allowsImplicitAnimation = true
    panel.animator().setFrame(newFrame, display: true)
}
```

and keep the SwiftUI animation duration identical, or the content will lag
behind the window edge.

## Review checklist

Before considering any animated view done:

- [ ] Geometry uses a spring, opacity uses easing
- [ ] Timing comes from a `Motion` token, not an inline literal
- [ ] Collapse is faster than expand
- [ ] Content is staggered on the way in, simultaneous on the way out
- [ ] Reversing the animation halfway looks correct
- [ ] Nothing scales or fades to absolute zero
- [ ] Corner radius animates with the same curve as size
- [ ] Reduce-motion path exists and was tested
- [ ] Total choreography ≤ 400ms
