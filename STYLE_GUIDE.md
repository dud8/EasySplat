# EasySplat UI Style Guide

This document is the single source of truth for EasySplat's UI and UX design. It defines the visual system, interaction patterns, motion rules, accessibility requirements, and component usage so that every future change remains consistent with the product's intent. If you change or add UI, you must follow this guide and update it when you introduce new patterns.

Audience
- Product designers
- SwiftUI engineers
- QA reviewers
- Anyone touching UI text, layout, or interactions

Scope
- Design and UI only (visuals, interactions, copy, layout, motion, accessibility)
- Applies to all UI in `EasySplatApp/UI` and UI overlays in `EasySplatApp/Viewer`

Non-goals
- Architecture, data models, toolchain, or build/test workflows

---

## 1) Design Philosophy

### Core intent
EasySplat is built for absolute beginners. The UI must feel calm, trustworthy, and simple to understand. We reduce the number of visible elements, then invest in polish and clarity for those elements.

### Guiding principles
1) Simple surface, rich feedback
   - Keep the interface sparse.
   - Make each interaction feel intentional through subtle hover/press feedback.
2) Progress transparency
   - Users should always know what is happening and how far they are in the process.
3) Beginner-friendly language
   - Use clear, short, non-technical language.
4) Consistency beats novelty
   - New UI elements must derive from the existing system, not invent new patterns.

### What "simple" means here
- Minimal number of UI elements on a screen.
- Clear hierarchy: one primary action, a few secondary actions.
- No decorative elements that do not serve clarity or reassurance.
- Visual polish is done through micro-interactions, not extra widgets.

---

## 2) Visual System

### Color system (Theme tokens)
All colors must come from `Theme` in `EasySplatApp/UI/Theme/Theme.swift`.

Current tokens:
- `Theme.background`: app background (window background)
- `Theme.surface`: cards and panels (control background)
- `Theme.border`: subtle outline and separators
- `Theme.accent`: primary action color
- `Theme.success`: completion and positive state
- `Theme.subtle`: secondary text

Destructive color
- Destructive actions use the system red via `SecondaryButtonStyle(variant: .destructive)`.

Rules
- Do not introduce hard-coded colors in views. Always use Theme tokens.
- Accent is reserved for primary actions and active states (current step, primary buttons).
- Border is low-contrast; do not use it for emphasis.
- Success is reserved for completed steps and ready states.
- For destructive actions, use `SecondaryButtonStyle(variant: .destructive)` and a destructive role.

### Typography
We use SwiftUI system fonts with consistent semantic roles. Do not introduce custom fonts or new styles without updating this guide.

Hierarchy (used throughout UI)
- Title: `.largeTitle.weight(.bold)` or `.title2.weight(.semibold)`
- Section heading: `.headline`
- Item title: `.subheadline.weight(.semibold)`
- Secondary label: `.subheadline` or `.caption`
- Monospace diagnostics: `.caption.monospaced()`

Rules
- Headings should be short and explicit.
- Body and secondary text must remain readable without relying on color alone.
- Use `.foregroundStyle(.secondary)` for supporting text.

### Shape language
Rounded rectangles with continuous corners are the standard.

Radius tokens (from `Theme.Radius`):
- `Theme.Radius.button = 10`
- `Theme.Radius.card = 14`
- `Theme.Radius.dropZone = 18`

Rules
- Use continuous corners (`style: .continuous`) for all cards and controls.
- Do not invent new corner radius sizes. Always use `Theme.Radius.button`, `Theme.Radius.card`, or `Theme.Radius.dropZone`.

### Elevation and depth
Depth is subtle and used sparingly for hover affordance.

Rules
- No heavy drop shadows.
- Hover shadows are low-opacity black and only appear during interaction.
- Panels should use borders rather than shadows.

---

## 3) Layout and Spacing System

### Base spacing scale
The UI currently uses a small, consistent set of spacing values:
- 8: tight spacing for related labels or controls
- 12: row-level spacing
- 16: card padding and small container padding
- 20: mid-level spacing
- 24: section spacing
- 32+: major layout spacing for main content areas

### Screen-level padding
- Home screen uses `padding(40)` and `frame(maxWidth: .infinity, alignment: .topLeading)`.
- Processing/Viewer use `padding(32)` to keep focus on core content.

Rules
- All screens should use a single, consistent outer padding value.
- Keep the main content column left-aligned unless a specific viewer requires centering.
- Avoid hard-coded widths for pickers and segmented controls. Prefer adaptive sizing with `ViewThatFits` and min/max width constraints.

### Composition guidance
- Prefer vertical stacks with clear grouping.
- Use cards (surface background + border) to separate groups.
- Avoid nested cards unless it clarifies information hierarchy.

---

## 4) Interaction and Feedback

### Button hierarchy
- Primary actions use `PrimaryButtonStyle()`.
- Secondary actions use `SecondaryButtonStyle()`.
- Disclosure rows use `DisclosureButtonStyle()`.

Rules
- Each screen should have a single primary action, if any.
- Secondary actions should never visually compete with the primary action.
- Destructive actions must use `SecondaryButtonStyle(variant: .destructive)` plus a destructive role and remain secondary in prominence.
- Use `SecondaryButtonStyle(variant: .subtleAccent)` for “return” or “back” actions that should be noticeable but not primary.

### Hover and press feedback
Hover and press feedback is required for every interactive control.

Primary button behavior (from `PrimaryButtonStyle`)
- Hover: subtle light overlay + slight lift
- Press: darker overlay + slight scale down

Secondary button behavior (from `SecondaryButtonStyle`)
- Hover: subtle accent-tinted overlay + border tint + slight lift
- Press: slightly stronger overlay

Disclosure row behavior (from `DisclosureButtonStyle`)
- Hover: subtle surface tint with faint border
- Press: slightly stronger tint

Rules
- Feedback must be subtle and quick; no large movement or color shifts.
- Visual changes must be visible but not distracting.

### Target affordances
Drop zones and clickable rows should show hover feedback when interactive. This provides confidence without increasing UI density.

---

## 5) Motion System and Reduce Motion

### Motion tokens
Defined in `Theme.Motion`:
- `hover`: 0.12s easeOut
- `press`: 0.08s easeOut
- `reveal`: 0.18s easeInOut

### Motion rules
- Use motion to communicate state changes (hover, press, reveal).
- Do not animate purely decorative elements.
- Use opacity-based transitions for view-state changes.

### Reduce Motion requirements
If `accessibilityReduceMotion` is enabled:
- All hover/press animations must be disabled (no animated transitions or scale).
- View transitions must be instant.
- Shimmer effects must be disabled.
- Continuous or looping animations must not run.

Every animated view must explicitly gate animations using `@Environment(\.accessibilityReduceMotion)`.

---

## 6) Component Specifications

### PrimaryButtonStyle (`EasySplatApp/UI/Components/PrimaryButtonStyle.swift`)
Purpose
- Main call-to-action (e.g., Start, Choose Video, Open in Brush)

Visual
- Background: `Theme.accent`
- Text: white
- Radius: `Theme.Radius.button`
- Hover: light overlay, slightly stronger shadow
- Press: darker overlay, subtle scale down

Interaction
- Hover animation duration: `Theme.Motion.hover`
- Press animation duration: `Theme.Motion.press`
- Reduce Motion disables scale and animation

### SecondaryButtonStyle (`EasySplatApp/UI/Components/SecondaryButtonStyle.swift`)
Purpose
- Secondary actions (Show in Finder, Clear All, Remove)

Visual
- Background: `Theme.surface`
- Border: `Theme.border`
- Text: `.primary` (or red for `.destructive`)
- Hover: subtle accent tint and border tint
- Press: slightly stronger tint

Variants
- `.standard`: default secondary styling
- `.subtleAccent`: faint accent-tinted fill to highlight soft-priority actions (must be visibly distinct from `.standard`)
- `.destructive`: red-tinted border and label to signal destructive actions

Interaction
- Same motion rules as primary
- Reduce Motion disables scale and animation

### DisclosureButtonStyle (`EasySplatApp/UI/Components/DisclosureButtonStyle.swift`)
Purpose
- Inline disclosure rows (LogDrawerView toggle)

Visual
- Transparent background by default
- Hover: surface tint and faint border
- Press: stronger tint

Interaction
- No scale; only background change
- Reduce Motion disables animation

### DropZoneView (`EasySplatApp/UI/Components/DropZoneView.swift`)
Purpose
- Primary input surface on Home screen

Visual
- Surface background with dashed border
- Radius: `Theme.Radius.dropZone`
- Hover: accent-tinted background overlay
- Drag targeted: stronger accent overlay and border

Interaction
- Hover feedback required
- On drop: accept file URLs only

Reduce Motion
- Hover transitions are disabled if Reduce Motion is on

### ShimmeringProgressView (`EasySplatApp/UI/Components/ShimmeringProgressView.swift`)
Purpose
- Display pipeline progress in Processing screen

Rules
- Track uses `Theme.border`
- Fill uses `Theme.accent`
- Shimmer overlay is visible only when Reduce Motion is off
- Progress fill animation is disabled when Reduce Motion is on

### StepperProgressView (`EasySplatApp/UI/Components/StepperProgressView.swift`)
Purpose
- Show pipeline stages in processing

Visual
- Card surface with subtle border
- Active stage uses accent and a ring indicator
- Completed stages use success with a checkmark indicator
- Upcoming stages use a hollow indicator

Motion
- Active step breathes when Reduce Motion is off
- Static when Reduce Motion is on

Accessibility
- Each stage must include an explicit accessibility value: “Completed”, “In progress”, or “Upcoming”.

### LogDrawerView (`EasySplatApp/UI/Components/LogDrawerView.swift`)
Purpose
- Show detailed logs and diagnostic text

Behavior
- Disclosure button toggles visibility
- Transition uses opacity + move when Reduce Motion is off
- Instant toggle when Reduce Motion is on
- Do not show a divider unless there is actual detail text

Visual
- Logs are monospaced caption text
- Container is a surface card with subtle border

### ProjectListView (`EasySplatApp/UI/Home/ProjectListView.swift`)
Purpose
- List existing projects

Visual
- Each row is a card with `Theme.surface` and `Theme.border`
- Status indicator uses `Theme.success`, `Theme.accent`, or red for failure

Interaction
- Row actions are secondary buttons; destructive actions use `SecondaryButtonStyle(variant: .destructive)`

Layout
- Project titles must truncate to a single line.
- Status labels must remain visible (use fixed size or layout priority).

### Viewer Overlay (`EasySplatApp/Viewer/SplatViewerView.swift`)
Purpose
- Provide viewer controls (Reset, Fit, Controls)

Visual
- Buttons in a `ultraThinMaterial` panel
- Buttons use secondary style

---

## 7) Before/After Examples

These are concrete, real-world examples of how to apply the style guide. Use them as templates for future UI changes.

### Buttons: Secondary actions
Before (avoid)
```
Button("Show in Finder") { ... }
    .buttonStyle(.bordered)
```
After (preferred)
```
Button("Show in Finder") { ... }
    .buttonStyle(SecondaryButtonStyle())
```

Why
- Secondary buttons should inherit the app's subtle surface + border language, not the system's generic bordered style.

### Buttons: Primary action emphasis
Before (avoid)
```
Button("Start") { ... }
    .buttonStyle(SecondaryButtonStyle())
```
After (preferred)
```
Button("Start") { ... }
    .buttonStyle(PrimaryButtonStyle())
```

Why
- Primary actions must be visually distinct and clearly dominant within their screen context.

### Disclosure rows (log drawer)
Before (avoid)
```
Button(action: { expanded.toggle() }) { ... }
    .buttonStyle(.plain)
```
After (preferred)
```
Button(action: { toggleExpanded() }) { ... }
    .buttonStyle(DisclosureButtonStyle())
```

Why
- Disclosure rows need a soft hover affordance without becoming button-like in weight.

### Drop zone hover vs. target state
Before (avoid)
- Drop zone only changes when dragging a file; idle hover is indistinguishable.

After (preferred)
- Idle hover: subtle accent tint + border shift.
- Drag target: stronger accent tint + border.

Why
- Users should feel confident the drop zone is interactive even before dragging.

### Reduce Motion gating
Before (avoid)
```
.animation(.easeOut(duration: 0.2), value: progress)
```
After (preferred)
```
.animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: progress)
```

Why
- All optional animation must be disabled when Reduce Motion is enabled.

### View transitions
Before (avoid)
- Views snap between states with no transition or motion gating.

After (preferred)
```
.transition(.opacity)
.animation(reduceMotion ? nil : Theme.Motion.reveal, value: model.viewState)
```

Why
- Transitions should be subtle and legible, and never override accessibility preferences.

### Segmented controls: responsive sizing
Before (avoid)
```
Picker("Quality", selection: $model.qualityPreset) { ... }
    .pickerStyle(.segmented)
    .frame(width: 320)
```
After (preferred)
```
ViewThatFits(in: .horizontal) {
    HStack { qualityPicker; modePicker }
    VStack(alignment: .leading) { qualityPicker; modePicker }
}
```

Why
- Segmented controls must remain readable at narrow window sizes and under localization.

### Buttons: destructive actions
Before (avoid)
```
Button("Delete") { ... }
    .buttonStyle(SecondaryButtonStyle())
```
After (preferred)
```
Button("Delete", role: .destructive) { ... }
    .buttonStyle(SecondaryButtonStyle(variant: .destructive))
```

Why
- Destructive actions must be visually distinct and clearly risky without stealing primary-action emphasis.

### Card surfaces
Before (avoid)
- Card backgrounds use `Theme.surface` with no border.

After (preferred)
- Card backgrounds use `Theme.surface` plus a faint `Theme.border` stroke.

Why
- Borders clarify grouping without adding visual weight or extra elements.

---

## 8) Screen-Level Guidance

### Home Screen (`EasySplatApp/UI/Home/HomeView.swift`)
- Hero section: title + short supportive line
- Drop zone is the primary surface; it must be large and visually dominant
- "Choose Video" is primary action; "Choose Photos Folder" is secondary
- Selected inputs card shows current selections and must support removal
- Start button is primary, aligned to right

Do not
- Add extra panels or settings on this screen
- Introduce new colors or icons without reason

### Processing Screen (`EasySplatApp/UI/Project/ProcessingView.swift`)
- Primary focus is progress and current status
- Stepper is secondary but always visible
- Status headline stays stable per stage; a detail line shows live progress when available
- Errors are shown in red and must be short, direct
- Log drawer remains collapsed by default
- During Brush training, show an optional “Show live preview” checkbox (default off). If enabled, embed the preview below the progress bar with a short secondary caption (“May slow training. Updates every few minutes.”).
- When live preview is enabled, keep the left status column scrollable so Details and controls remain accessible at smaller window heights.
- Training live-preview overlays use compact viewer controls (Reset/Fit/Controls) so controls stay visible but do not dominate the preview canvas.
- On larger windows, scale preview and expanded Details panel heights with available space while keeping current visual hierarchy and readability.
- Training live preview polling is adaptive by training progress (`5s` early, `10s` mid, `15s` late) to reduce reload churn near the tail end of training.
- While users are actively manipulating the preview, defer applying new snapshot reloads until the interaction is idle, then apply only the latest queued snapshot.

### Viewer Screen (`EasySplatApp/UI/Project/ViewerView.swift`)
- Splat preview is the center of attention
- Viewer controls are subtle and placed in the overlay
- Post-completion action uses secondary style (Start Another)

---

## 9) Edge Cases and Empty States

The UI must remain calm and clear when data is missing, partial, or in transition. Use these existing patterns as a baseline and do not introduce new messages without updating this guide.

### Home Screen
- No selected inputs
  - Show: "No inputs selected yet."
  - Start action is disabled.
- Multiple video inputs
  - List each file with a removable row.
- Long file names
  - Prefer truncation over multi-line wrapping to avoid shifting layout or control alignment.

### Project List
- No projects
  - Show: "No projects yet."
- Failed project
  - Show error text in red (caption).
- Retrying project
  - Show "Previous attempt failed: ..." in secondary text.

### Processing Screen
- Error present
  - Show the error in red beneath status.
- Status detail present
  - Show the live detail line under the headline and mirror it in the log drawer details.
- Log drawer expanded with no content
  - Show: "No details yet."

### Viewer Screen
- Output missing
  - Show: "No output found yet."
- Splat loading
  - Display loading indicator with minimal copy: "Loading splat..."

### Drop Zone
- Not hovered or targeted
  - Remain neutral with subtle border.
- Hovered
  - Show a light accent tint to signal interactivity.
- Targeted (drag active)
  - Show stronger accent tint + border.

### Log Drawer
- Copy button only appears if copy text exists.
- Empty details and lines must show the empty state text.

### Reduce Motion
- All animations must be removed in Reduce Motion mode; UI should still communicate state via color and layout.

---

## 10) Copy and Language

Tone
- Friendly, direct, and minimal
- Avoid technical jargon when possible

Rules
- Button labels are verb-first ("Start", "Show in Finder")
- Use ellipsis for file pickers ("Choose Video...")
- Error text should be short and actionable

Examples
- Good: "Drop a video or photos folder"
- Bad: "Select input assets for processing"

---

## 11) Accessibility

Reduce Motion
- All optional animations must be disabled when Reduce Motion is enabled
- The UI must remain fully usable without motion cues

Contrast
- Text must be legible on `Theme.surface` and `Theme.background`
- Avoid using color alone to convey meaning
- For status, include a secondary cue (icon, shape, or label) plus an explicit accessibility value

Touch/Click targets
- Buttons must remain at least the size implied by their padding and control size

---

## 12) Do and Do Not

Do
- Use Theme tokens for colors and motion
- Keep layouts sparse and easy to scan
- Add hover/press feedback for all interactive elements
- Gate all animations with Reduce Motion

Do Not
- Add new colors outside Theme
- Add extra UI elements for decoration
- Add animations that are not tied to meaningful state
- Increase UI density without a strong reason

---

## 13) Change Management

If you add or change UI:
1) Implement using existing styles or extend them in `Theme`.
2) Update this document with any new component rules.
3) Validate Reduce Motion behavior.
4) Ensure no hard-coded radii or fixed-width segmented controls were introduced.
5) Ensure status is communicated with non-color cues and accessibility values.
6) Ensure the new UI preserves the "simple surface, rich feedback" principle.

The style guide must stay current. If it drifts from the actual UI, it is no longer authoritative.
