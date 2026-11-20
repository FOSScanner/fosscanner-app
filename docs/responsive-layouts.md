# Responsive document layout policy

This is display-only sizing: image processing, export bytes, on-device storage,
and privacy behavior are unchanged.

- Home cards use the available body width, 8px gaps, and a minimum card width of
  168 logical pixels at normal text size, growing to 220 at 200% text. Column
  count is bounded to 1–6. A 320px small phone uses one column; ordinary phones
  can use two; tablets use additional columns. Card extent budgets a document
  preview and a text-scaled footer, rather than a fixed aspect ratio that can
  squeeze labels/actions. The camera retains 96px of final-row scroll clearance.
- At widths under 380px, or when 20px text scales above 28px, home keeps gallery
  import visible and moves barcode scan/clear into the existing overflow menu.
  Availability checks and callbacks are shared with the ordinary action path.
- Export/status controls stack at content widths under 300px or large text.
  Labels continue to wrap; text scaling is never disabled. This does not claim
  equal footer height across busy and ready states (tracked separately).
- Crop previews use side-by-side controls only when width is at least 520px and
  exceeds height; narrow short windows keep controls below a flexible canvas.
  Crop actions stack when their available width is below 300px or when 16px
  text scales above 20px, avoiding character-by-character button labels.
- Appearance editing uses a separate scrollable controls pane when it can leave
  at least 280px for the preview and the window is wider than tall. On other
  windows the fixed layout requires at least 640px body height, 300px width, and
  at most 125% scaling at 16px. This budgets at least 240px of preview height
  before flex allocation. Smaller/large-text windows scroll with an explicit
  preview height of 1.1× width, bounded to 160–400px. The 240px useful-preview
  target is asserted around representative breakpoints and in failed states;
  physically shorter windows can only provide their available height.
- Resize does not replace editor state or rerun initialization: crop/filter and
  adjustment values stay owned by the same screen State.

See `test/goldens/README.md` for the bounded visual matrix and validation limits.
These policies do not introduce a foldable hinge arrangement or replace native
Android/iOS acceptance checks. Safe-area work is tracked separately in PR #200.
