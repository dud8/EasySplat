# EasySplat interface guide

EasySplat should feel like a focused Mac utility: quiet by default, precise when expanded, and honest about long-running work.

## The standard

A first-time user should understand the primary action in a few seconds. A working photographer or videographer should find the controls that materially change the result without seeing implementation knobs.

Prefer deletion over decoration. Every label, panel, icon, animation, and control must earn its place.

## Structure

The app uses one `NavigationSplitView`:

- sidebar: search, status filter, sort, projects;
- toolbar: New Splat over the sidebar column, workspace actions on the right;
- workspace: new project, processing, recovery, or result;
- inspector: selected project and measured result facts.

Only one reconstruction may run. Disable New Splat while it is active. Do not imply concurrent GPU work — with one exception: the Train phase may preview the run in flight. The preview is subordinate to the run that produced it, never a second job, and it yields the GPU rather than competing for it.

Accent color belongs to selection, active progress, and the primary action — nowhere else. Sidebar filter, sort, and row actions render in label colors, not accent.

Ready rows carry only the title and date. Only exceptional states — In Progress, Failed, Unfinished — earn a status caption; VoiceOver still hears the full status on every row.

Use source-list rows, toolbars, context menus, `LabeledContent`, dividers, disclosures, and system panels. Do not build a dashboard or a grid of cards.

## New project

The normal reading order is:

1. Create a 3D splat
2. Choose Input…
3. selected inputs
4. collapsed Options summary
5. comparable historical duration, only when at least three exist
6. Create Splat

The input target is a real button with focus, Return/Space activation, VoiceOver labeling, and drop support. It reads as a drop target: dashed hairline border, one secondary import glyph, and the accent border only while a drag hovers. Say the instruction once — the target's own subtitle carries it; no separate explanatory line above.

Initial keyboard focus belongs to the input target, not the sidebar search field. No control shows a focus ring before the user has touched anything.

Professional controls stay in one disclosure. Use plain consequences:

- Capture Path
- Detail
- Camera Source
- Lens
- Input Order
- Resource Use
- Photo Use, only with photo input

Never expose a model, mapper, device, thread count, chunk size, iteration count, or raw resolution in product UI.

## Processing

User phases are Prepare, Reconstruct, Train, and Finish.

Show:

- the phase phrase as the heading, such as `Reconstructing scene`
- the project title and input summary under it, so the wait names its subject
- a four-phase rail (Prepare · Reconstruct · Train · Finish) with done, current, and pending states carried by symbol and weight, never color alone
- native determinate or indeterminate progress
- elapsed time and last update
- the comparable historical duration, when at least three similar runs exist — fresh runs only; resumes and retrains skip stages and would make it misleading
- a collapsed Technical Details disclosure
- Stop Run… in the toolbar

While a run is active the window subtitle mirrors the step, so Mission Control and the Dock name the phase without raising the window.

Stage-local progress must not masquerade as overall completion. Backend names and raw logs stay in Technical Details.

While training, the workspace may show a live preview of the splat. It is off with one command and remembered. When it is on, the canvas takes the workspace and the phase heading, rail, progress, and timing move onto it in one system-material panel — one panel, not several. The preview is thinned and trails the model, so it says so; it never names an iteration and never reads as the finished result. A run that cannot spare the memory withholds it and says why in Technical Details, and training is unaffected either way.

Outside the window, the Dock icon carries a progress bar only for stages with real fractional progress, and a notification fires when a run finishes or fails while the app is in the background. A user-initiated stop never notifies.

Failure actions are Try Again, Back to Projects, and an overflow menu for Finder and diagnostics. Copy must reflect what actually survives. Do not mention a checkpoint unless one has been atomically written and validated.

## Result

The splat canvas owns the workspace, edge to edge — no padding or corner treatment between the canvas and the window chrome. The toolbar contains Export…, Share, Inspector, and a small overflow menu.

The inspector opens by default only when the workspace leaves the canvas useful room beside it; below that it starts closed. An explicit show or hide — toolbar or View menu (⌃⌘I) — is remembered and always wins. The inspector shows facts with `LabeledContent` and dividers:

- Output
- Capture
- Reconstruction
- Timing
- Notes
- Technical

Keep registered views, points, residuals, and timings. Do not convert them into Strong/Fair/Low ratings or fleet comparisons.

Notes save independently from pipeline metadata and preserve the final keystroke during project changes.

## Visual tokens

Use system typography and semantic colors. `Theme` contains the few shared values:

- spacing: 8, 12, 20, 32
- radius: 12
- workspace transition: 0.16 seconds

Accent blue is reserved for selection, active progress, and the primary action. Use system separator and control-background colors for structure.

Do not add:

- generic card components
- custom button styles
- hover scaling or lift
- breathing, shimmer, or entrance animation
- ornamental shadows
- glass panels — with one exception: overlays floating on the splat canvas use system material because legibility over arbitrary 3D content requires it
- metadata chips
- gradients as decoration
- decorative status colors without a second cue

The app icon is a midnight squircle with one cyan-white point-cloud orbit. It has no text or small decorative marks.

## Shell

- Commands live in the menu bar first; toolbar buttons mirror them. File holds New Splat (⌘N), Export… (⌘E), and Close; View holds Show or Hide Sidebar (⌃⌘S), Show Inspector / Hide Inspector (⌃⌘I) on the result screen, and Enter Full Screen.
- About uses the standard about panel. The one-line description lives in its credits, in small secondary type. Hardware details belong in diagnostics, not About.
- The Help menu holds EasySplat Help (opens the project page) and Copy Diagnostics for Current Project.
- View Releases… lives in the application menu, under About.
- The Info.plist declares a display name, an application category, and a human-readable copyright.
- When a run finishes or fails while the app is unattended, a notification says so. A user-initiated stop never notifies. The Dock icon carries the same honest progress the window shows.

## Copy

Write short, specific actions:

- Choose Input…
- Create Splat
- Preparing tools
- Try Again
- Conserve Memory
- Show in Finder

Avoid marketing adjectives, fake reassurance, backend names, explanations of obvious controls, and prose inside buttons.

Use an ellipsis only when the action opens another decision, such as Export… or Stop Run….

## Accessibility

Every workflow must work with keyboard only and VoiceOver.

- Follow visual reading order in accessibility order.
- Do not hide labels from assistive technology when using icon-only toolbar buttons.
- Keep focus rings visible.
- Give drop targets button semantics.
- Never rely on color alone.
- Support Increase Contrast and Differentiate Without Color through system colors and explicit text or icons.
- Disable the workspace animation under Reduce Motion.
- Truncate long filenames visually while exposing the complete name through help and accessibility text.

Viewer keyboard controls:

- `W`/`A`/`S`/`D` held: fly forward, left, back, right
- `E`/`Q` held: fly up and down
- Shift held: sprint
- arrows: orbit
- Option-arrows: pan
- `+` and `-`: zoom
- `F`: fit
- `R`: reset

Pointer and trackpad controls:

- drag: orbit
- right-drag or Control-drag: look around
- Option-drag or middle-drag: pan
- scroll or pinch: zoom

## Review matrix

Before release, check light and dark appearance at 920×640, 1100×760, and 1440×900. Repeat with:

- VoiceOver
- keyboard only
- Reduce Motion
- Increase Contrast
- Differentiate Without Color
- long project and media names

Treat clipping, inaccessible controls, focus loss, stale status, and misleading progress as release bugs.
