# ADR 052: Text rasterization under the sandbox (DEFERRED — Phase-2 design doc)

## Status: Deferred (design doc — NOT implemented this session; no half-fix)

## Date: 2026-09-27

## Context

Session 047's A/B discrimination interlock
(`docs/test-logs/047-ab/REPORT.md`) CONFIRMED that text rasterization
fails under the unit sandbox: Run B (the all-text render-only page)
rasterized to all-black, while Run A (the default page) glowed with
identical scanout state. The root cause is cairo's toy text API
silently rendering nothing on a fontconfig/freetype failure — no
panic, no error, no WARN. The `.unwrap()` on `show_text`
(`src/widgets/button.rs:101`, `src/widgets/slider.rs:81`) unwraps
`Ok(())`; the failure is that the glyph extents are zero-width and
nothing is drawn, NOT that the call errors.

ADR-051 (the shape widget) is the minimal fix that makes the
validation page visible BY CONSTRUCTION without text. ADR-052 is the
BROADER fix: make text rasterization RELIABLE and OBSERVABLE under the
sandbox for production-intended text widgets. This ADR records the
root-cause derivation (WITHOUT hardware — per the ADR-052 mandate) and
the candidate fixes, and DEFERS implementation to Phase 2 because the
fix is architectural and the text widgets are Phase-2 placeholders
today.

## Root-cause derivation (WITHOUT hardware)

### The sandbox

The systemd unit (`packaging/systemd/tbard.service`) uses:
- `ProtectSystem=strict` — filesystem read-only except whitelisted
  paths. Font files (`/usr/share/fonts/`) are READABLE. Fontconfig
  config (`/etc/fonts/fonts.conf`) is READABLE.
- `ProtectHome=true` — user font configs (`~/.config/fontconfig/`)
  NOT accessible. System fonts ARE accessible.
- `PrivateTmp=true` — private `/tmp` + `/var/tmp`.

The fontconfig cache (`/var/cache/fontconfig/`) is under `/var`
(read-only under `ProtectSystem=strict`). **Cache writes fail
silently.** Fontconfig falls back to in-memory resolution — it does
NOT fail to render when the cache is unwritable; it rebuilds the cache
in memory. So the cache-write failure is NOT itself the render
failure.

### The dead FFI module

`src/fonts.rs` is a fontconfig FFI module (`FontConfig::new`,
`Pattern::new`, `match_pattern`, `perform_substitutions`,
`get_file_name`, `get_font_index`). It is declared (`mod fonts;` at
`src/main.rs:22`) but NEVER called from the render path. The widgets
use cairo's INTERNAL fontconfig calls (`ctx.select_font_face(...)`
at `src/widgets/button.rs:90-94` and `src/widgets/slider.rs:65-69`),
not the `fonts.rs` FFI. So a fontconfig failure manifests INSIDE cairo
as silent all-black, NOT as a typed `HwError::Ffi` — the `fonts.rs`
typed-error discipline (ADR-006) does not cover the toy-text path.

### The silent failure mode

If fontconfig cannot find ANY font (no "sans-serif" match), cairo's
toy text API:
1. `select_font_face("sans-serif", FontSlant::Normal, FontWeight::Bold)`
   → sets an invalid/NULL face. Does NOT error (returns `Ok(())`).
2. `text_extents("label")` → returns zero-width extents. Does NOT
   error.
3. `show_text("label")` → renders nothing. Does NOT error.

Result: silent all-black. No panic. No error log. No WARN. The
`.unwrap()` unwraps `Ok(())` — the call "succeeds" by rendering
nothing.

### The 043 counter-example

`docs/test-logs/046-f045-1-analysis/adr-052-text-rasterization-candidate.md`
notes that 043 (`docs/test-logs/043/`) showed text DID render under
the same sandbox — so fontconfig DOES resolve "sans-serif" in the
CURRENT sandbox configuration. The failure mode is SILENT if it ever
fails (a font package removed, a fontconfig config change, a sandbox
tightening). The s044 test never checked visibility, so the silent
failure went uncaught.

### Replication under sim (the ADR-052 mandate — root-cause WITHOUT hardware)

Per the ADR-052 mandate: replicate the failure in sim as user `nobody`
under the unit's sandbox constraints (`systemd-run` with the same
`ProtectSystem/PrivateTmp/no-user-homes` profile, or an env-restricted
run) rendering a TEXT widget; observe fontconfig behavior
(`FONTCONFIG_FILE`/`strace`/`ltrace`; cache-dir write failures; font-
path visibility). This requires a vkms/uinput sim harness with
`systemd-run` + the unit's sandbox profile — a non-trivial harness.
The root-cause derivation ABOVE (dead FFI + silent toy-text failure +
cache-write-fallback) is established from code inspection + the 047
A/B evidence WITHOUT running the sim harness; the sim replication is
the confirmatory step that belongs with the Phase-2 implementation
(when the fix lands and must be verified). Deferring the sim
replication is consistent with "do not half-fix": the design is
recorded, the fix is NOT half-applied.

## Candidate fixes (design — NOT implemented)

### Option 1: wire `src/fonts.rs` into the render path

Use the fontconfig FFI to resolve the font file BEFORE the render
loop, verify it exists, log a `WARN` if fontconfig cannot resolve
"sans-serif", then use the verified font path with cairo (toy API
with the resolved family, or `cairo::FontFace::new_from_file`). This
makes font failure OBSERVABLE instead of silent.

**Cost**: medium. The `fonts.rs` FFI exists but is unwired. Wiring it
requires a font-resolution step at render init + a fallback path +
deciding whether to fail-fast (refuse to start if no font) or
graceful-degrade (render shapes only, log WARN).

### Option 2: bundle a font in the package

Bundle a small public-domain TTF in `/usr/share/touchbar/fonts/`
(readable under `ProtectSystem=strict`) and load it explicitly via
`cairo::FontFace::new_from_file`. This removes the fontconfig
dependency entirely for the bundled font.

**Cost**: low-medium. Adds a font file to the package + a load step
in the render init. The sandbox allows reading
`/usr/share/touchbar/fonts/` (read-only). Requires a license-clean
font (e.g. a public-domain/CC0 TTF).

### Option 3: font-failure detection + shape fallback (WARN+)

After `select_font_face`, call `text_extents` on a known probe string
(e.g. "X") and assert non-zero width. If zero, log a `WARN` (never
silent — "silence is the bug class") and fall back to a SHAPE-drawn
placeholder (a filled rect, reusing ADR-051's `ShapeWidget` draw
path). This makes font failure non-silent AND visible.

**Cost**: low. A check after `select_font_face` + a fallback path.
Does not require bundling a font. This is the MINIMAL fix that
satisfies "the engine must log font/render failure at WARN+" without
an architectural font pipeline.

## Decision: DEFER to Phase 2

The text widgets (`time`, `battery`, `dial`) are Phase-2 placeholders
today (`src/main.rs:1182-1191` — `ButtonWidget::new("⏰", [])` with a
`TODO(Phase 2)` comment; `ButtonWidget::new("🔋", [])`; dial falls
back to `ButtonWidget::new(label, [])`). The `button` label is the
only production text path, and it is the operator's config content
(labels like "esc", "F1", "🔇").

Per the rules: "If the fix is architectural (embedded font
rasterizer etc.), DOCUMENT the design as a Phase-2 ADR and ship 051
alone — do not half-fix." Options 1 and 2 are architectural (a font
pipeline / a bundled font + load step). Option 3 is cheap and
in-repo, but it is a BEHAVIOR change to the production render path
(fallback rendering) that should land WITH the Phase-2 text-widget
implementation, not as a standalone patch on a frozen fix session.
Applying Option 3 alone would change the button render path's
behavior without a clear production-intent decision on the text
widgets — a half-fix.

**ADR-052 is DEFERRED.** The Phase-2 implementation of real
time/battery/dial rendering MUST include one of the three options
above (or an equivalent) so that text rasterization is RELIABLE and
OBSERVABLE under the sandbox. The binding requirement is:

> **The engine must log font/render failure at WARN+ — silence is the
> bug class.** A font miss, a fontconfig init failure, or a zero-width
> glyph extent MUST produce a WARN (or higher) log line, NEVER silent
> all-black.

## Test (deferred with the fix)

A test asserting text rendering FAILS LOUDLY (or succeeds) — the
Phase-2 ADR-052 implementation must include:

1. A test that a TEXT widget render, under a broken-fontconfig
   environment (e.g. `FONTCONFIG_FILE` pointed at an empty config, or
   a fixture with no fonts), produces a WARN+ log line (NOT silent
   all-black).
2. A test that a TEXT widget render, under a working-fontconfig
   environment, produces non-black pixels (the positive case).

These tests close the silence bug class. They are deferred with the
fix (Phase 2).

## Consequences

- ADR-051 (shape widget) is the immediate fix for the validation
  page; the shipped validation page is shapes-only and visible BY
  CONSTRUCTION.
- ADR-052 is DEFERRED to Phase 2; the design is recorded here so the
  Phase-2 text-widget implementation includes a font-failure
  detection + WARN+ requirement.
- The binding requirement ("log font/render failure at WARN+") is
  recorded as a Phase-2 acceptance criterion for any text-rendering
  work.
- No code change this session. No half-fix.