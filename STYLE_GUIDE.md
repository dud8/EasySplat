# EasySplat interface guide

EasySplat should feel like a focused Mac utility: quiet by default, precise when expanded, and honest about long-running work.

## The standard

A first-time user should understand the primary action in a few seconds. A working photographer or videographer should find the controls that materially change the result without seeing implementation knobs.

Prefer deletion over decoration. Every label, panel, icon, animation, and control must earn its place.

## Structure

The app uses one `NavigationSplitView`:

- sidebar: projects, search, status filter, sort, New Splat;
- workspace: new project, processing, recovery, or result;
- inspector: selected project and measured result facts.

Only one reconstruction may run. Disable New Splat while it is active. Do not imply concurrent GPU work.

Use source-list rows, toolbars, context menus, `LabeledContent`, dividers, disclosures, and system panels. Do not build a dashboard or a grid of cards.

## New project

The normal reading order is:

1. Create a 3D splat
2. Choose a video or a folder of photos.
3. Choose Input…
4. selected inputs
5. collapsed Options summary
6. comparable historical duration, only when at least three exist
7. Create Splat

The input target is a real button with focus, Return/Space activation, VoiceOver labeling, and drop support.

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

- `Step 2 of 4 · Reconstructing scene`
- native determinate or indeterminate progress
- elapsed time and last update
- a collapsed Technical Details disclosure
- Stop… in the toolbar

Stage-local progress must not masquerade as overall completion. Backend names and raw logs stay in Technical Details.

Failure actions are Try Again, Back to Projects, and an overflow menu for Finder and diagnostics. Copy must reflect what actually survives. Do not mention a checkpoint unless one has been atomically written and validated.

## Result

The splat canvas owns the workspace. The toolbar contains Export…, Share, Inspector, and a small overflow menu. The inspector shows facts with `LabeledContent` and dividers:

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
- glass panels
- metadata chips
- gradients as decoration
- decorative status colors without a second cue

The app icon is a midnight squircle with one cyan-white point-cloud orbit. It has no text or small decorative marks.

## Copy

Write short, specific actions:

- Choose Input…
- Create Splat
- Preparing tools
- Try Again
- Conserve Memory
- Show in Finder

Avoid marketing adjectives, fake reassurance, backend names, explanations of obvious controls, and prose inside buttons.

Use an ellipsis only when the action opens another decision, such as Export… or Stop….

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

- arrows: orbit
- Option-arrows: pan
- `+` and `-`: zoom
- `F`: fit
- `R`: reset

## Review matrix

Before release, check light and dark appearance at 920×640, 1100×760, and 1440×900. Repeat with:

- VoiceOver
- keyboard only
- Reduce Motion
- Increase Contrast
- Differentiate Without Color
- long project and media names

Treat clipping, inaccessible controls, focus loss, stale status, and misleading progress as release bugs.
