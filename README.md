# Vocal Training

An Apple Silicon macOS application for turning sections of YouTube vocal
lessons into reusable practice exercises.

## AI-assisted development disclosure

Models used:

- **GPT-5.6-Sol**

## User guide

### Requirements

Install the media tools:

```sh
brew install yt-dlp ffmpeg
```

The app validates both tools at startup and immediately before each media
operation. It prefers executables packaged in
`Contents/Resources/helpers/`, then searches the development machine's
`PATH`; it never installs or downloads tools itself.

The application stores its SQLite library and downloaded media in
`~/Library/Application Support/VocalTraining`. It migrates and removes the old
`library.json` file after it verifies the new database. Only download media you
are authorized to download.

### Workflow

Use the mode control in the title strip to separate the two workflows. **Create**
shows source ingest, the timed transcript, range markers, exercise naming, and
export controls. **Play** shows the saved-exercise library, a larger practice
monitor, and only playback controls.

Press **Add** in the Source Register to open the ingest dialog, then paste one
or more YouTube URLs with one URL per line. URLs are normalized by video ID,
while timestamps supplied through `t`, `start`, or `youtu.be` URL forms become
initial playhead hints. The dialog checks each URL in the background and shows
its title, duration, and available video resolutions. Select a resolution for
each video before import. The default is the best available resolution at or
below 1080p, or the lowest available resolution when all options are higher.
Import fetches the selected MP4 video and M4A audio streams and
merges them without transcoding. Import prefers an English
caption track and otherwise accepts YouTube's original-language automatic
captions. Right-click a source to open the Source Details dialog. It shows the
duration, resolution, frame rate, codecs, container, format ID, and local file
size. The app loads missing file metadata in the background after startup.
Select **Refetch / Select Quality** to replace its media, metadata, and
captions. Refetch checks the source again and opens the same per-video quality
selector before it downloads replacement media.
The refetch operation also rebuilds each saved exercise from that source at the
new resolution.
During a download, the footer shows its completion, current stream size,
transfer speed, and remaining time. Select **Stop** to terminate yt-dlp and
leave the source library unchanged.
The app downloads into staging files. It verifies H.264 video and AAC audio,
decodes one second of both tracks, and then replaces the active source files.

The Source Register marks a source as **MISSING** when its merged MP4 file is
not available. Right-click that source and refetch it. Inspect `yt-dlp.log` if
the refetch fails.

Select a source, load its captions, and click a timed transcript row to seek.
Use the transcript search field to rank fuzzy caption matches. Clear the field
to restore the transcript's time order.
Mark the start and end of a useful section, then commit the range as an
exercise. Saved exercises appear in the exercise bank and play as standalone
clips when selected. The Source Monitor volume controls adjust playback in 10%
steps and retain that level when another source is loaded during the session.
Its transport can play, pause, stop at zero, reset to the imported URL
timestamp, and scrub across the complete source.
If a source has multiple imported timestamps, the Reset control becomes a
timestamp selector. Selecting a value seeks there and saves it as the source's
active timestamp.
The speed controls adjust playback from `0.1x` to `2.0x` in `0.1x` steps.

When no text field has focus, press **Space** to toggle playback or **1–8** to
activate the matching numbered transport control.

Press **Control-K** to open the command palette from any application state.
Type to search commands, sources, and exercises in one list. Use the arrow
keys to move, Return to select, and Escape to close the palette. Commands that
do not apply to the current mode remain visible with their unavailable reason.
Selecting a source switches to Create and loads it. Selecting an exercise
switches to Play and starts it.

Press **/** when no text field has focus to show keyboard labels on all visible
discrete controls. Each label is a compact mnemonic with two or three
characters. For example, Mark In uses `mi` and Mark Out uses `mo`. A unique
mnemonic activates its control immediately. If controls share one mnemonic,
use Tab or Shift-Tab to select a control, then press Return. Press **Escape**,
click, scroll, or resize the window to cancel label mode. A slash typed in a
focused text field remains normal text. Press **Escape** to leave a focused
text field and make Flash navigation available again.

Download and export diagnostics are stored as `yt-dlp.log` and `ffmpeg.log` in
the application-support directory. Use the **Data** control to open that
directory in Finder.

### Command-line control

The debug build creates `build/vocal-training`. Each command writes one JSON
result to standard output. Failed media commands include the diagnostic path.

```sh
build/vocal-training source add --url 'https://youtu.be/VIDEO_ID?t=120'
build/vocal-training source list
build/vocal-training transcript get --source VIDEO_ID
build/vocal-training clip create \
  --source VIDEO_ID \
  --from-segment VIDEO_ID-12 \
  --to-segment VIDEO_ID-18 \
  --name 'Descending scale'
build/vocal-training clip list --source VIDEO_ID
```

`source add` selects compatible media at or below 1080p. Use `--max-height N`
to set another limit. The command downloads one URL at a time.

`clip create` starts at the first segment start. It ends at the last segment
start plus its duration. The command saves the MP4 as an exercise.

The GUI owns the library while it runs. CLI commands then use its private local
socket. When the GUI is closed, the CLI locks and updates the library directly.

Structural UI commands require the running development application. Capture a
baseline before an interaction, then check the completed background state:

```sh
./scripts/dev-cli.sh ui snapshot
./scripts/dev-cli.sh ui check --baseline '/absolute/path/from-the-snapshot-result.json'
```

Each command returns compact JSON. The snapshot result contains the baseline
artifact path. The check result contains counts for retained, added, disabled,
removed, changed, and unexpected controls. Complete artifacts stay in
`build/dev-support/ui-checks/`. The app keeps the newest 20 artifacts and
removes older files after each successful write. UI commands return
`gui_not_running` when the development application is closed.

## Development guide

### Architecture

A thin AppKit shell creates the window and forwards input. Odin calculates
every visible control, while Metal renders the interface through one
`CAMetalLayer`. The custom Metal view conforms to `NSTextInputClient` and
routes typing through `interpretKeyEvents`, so Command shortcuts and input
methods stay on the AppKit path. AVPlayer decodes muted video, and Core Video
maps its frames into Metal textures. AVAudioEngine routes audio through a
time-pitch unit, so speed changes preserve vocal pitch without restarting the
audio stream.

The interface uses Iosevka Aile and a measured immediate-mode layout.
Typography uses 10.5 points throughout the interface, including the compact
`VOCAL TRAINING` title. Container text is shaped as a complete CoreText line,
then positioned from its measured
advance and ascent/descent metrics. Measurement, alignment, truncation, and
drawing reuse that same shaped line, preserving kerning, ligatures, fallback
fonts, combining marks, bidirectional ordering, and complex-script shaping.

The application builds each visible interactive control once per frame. Each
control record contains a stable functional name, rectangle, action, state,
and capability flags. Pointer input, macOS accessibility, and Flash navigation
consume the same records. Dynamic controls include a durable source, segment,
or exercise identifier in their functional name. Static panels and labels stay
outside the control registry.

The structural UI checker rebuilds and serializes the current control registry
on the main thread. A background-state check compares it with an idle baseline.
It permits expected disabling and the import Stop control. It rejects removed
controls, changed actions, changed rectangles, and unexpected additions. The
checker writes full snapshots and diffs to application support, while the CLI
returns only compact counts.

The sibling `hw_odin_ui_flash` package consumes opaque control identifiers and
Flash labels from the application registry. A control keeps its unique
functional name separate from its short Flash label. Repeated row actions share
one Flash label and form a spatial selection group. The package generates
compact mnemonics and manages ambiguous selection groups. The app retains
control of Metal rendering and action execution. If a Flash label has no ASCII
letter or digit, the app derives a fallback from the control action.

The sibling `hw_odin_ui_commandPalette` package owns command-palette state,
context evaluation, keyboard selection, and match-sorter ranking. The
application supplies curated actions and data, renders the Metal modal, and
executes the selected opaque identifier.

SQLite stores sources, transcript segments, hints, exercises, and source
metadata. The main thread commits state changes in transactions. A startup
worker fills missing metadata from existing yt-dlp files.

The repository contains the canonical development library in
`testdata/library.sqlite3`. Development launches use `build/dev-support`, and
tests use temporary copies. Installed builds continue to use the standard
macOS Application Support directory. Database file paths are relative to the
selected support directory.

### Memory ownership

The renderer owns two virtual-memory arenas. The frame arena holds the control
registry and solid geometry. `setVertexBytes` copies the geometry into Metal's
command stream before the next frame resets the arena. Accessibility bindings
retain stable control identifiers instead of pointers into the frame arena.
The redraw arena holds the scaled RGBA overlay until `replaceRegion` copies it
into the retained text texture. The next dirty redraw resets that arena. Debug
builds print each arena's high-water mark, reset count, and allocation-failure
count at shutdown.

Each import or export worker owns a private growing arena and never reads the
mutable UI or application arrays. The main thread joins the worker, clones its
small durable records into the heap, swaps any completed transcript generation
into `App_State`, and destroys the worker arena. Transcript segments and every
string reachable from them share one generation arena, so replacement installs
the new generation before destroying the old one.

Sources, import hints, exercises, and mutable UI strings remain individually
heap-owned because they change independently. Core Foundation, Objective-C,
AVFoundation, and Metal objects retain explicit release calls; an arena reset
never substitutes for framework reference counting.

### Build

Install Odin and ensure `odin` is on `PATH`. Clone `hw_odin_matchSorter`,
`hw_odin_ui_flash`, and `hw_odin_ui_commandPalette` next to this repository.
The build imports them as the `match_sorter`, `flash`, and `command_palette`
collections. The default build is unoptimized, includes debug information and
assertions, and emits a matching dSYM:

```sh
./build.sh
open build/VocalTraining.app
```

Other build modes use separate output directories:

```sh
./build.sh trace    # debug build with Core Foundation lifetime logging
./build.sh asan     # AddressSanitizer
./build.sh release  # optimized production build
```

The legacy scripted import form remains available and returns JSON:

```sh
build/VocalTraining.app/Contents/MacOS/VocalTraining --import 'https://youtu.be/VIDEO_ID?t=SECONDS'
```

### Release TODO

The current release build is suitable for local development, but it is not yet
a self-contained build for non-technical users. Complete these items before
external distribution:

- Package pinned standalone `yt-dlp` and relocatable Apple Silicon `ffmpeg`
  executables under `Contents/Resources/helpers/`. Ship helper updates through
  new app releases; do not install Homebrew, mutate the user's global `PATH`, or
  download executables on first launch.
- Build the bundled FFmpeg configuration without the current GPL `libx264`
  dependency, switch clip encoding to `h264_videotoolbox`, and include the
  required FFmpeg license notice, build configuration, and corresponding source
  location with the release.
- Add a packaging pipeline that signs each helper and then the app with a
  Developer ID Application certificate and hardened runtime, submits the
  archive for notarization, and staples the accepted ticket. No valid signing
  identity is currently installed on the development machine.
- Verify the quarantined artifact on a clean Apple Silicon Mac: Gatekeeper
  accepts a normal double-click launch, startup helper validation passes,
  import and clip export complete without Homebrew, and the final app size and
  embedded helper versions are recorded.

### Reload loop

Run the dependency-free watcher during development:

```sh
./dev.sh
```

It fingerprints the source, build scripts, and `Info.plist` every half-second.
A successful change rebuilds and relaunches the debug app; a failed build
leaves the currently running app untouched. Metal validation is enabled.
Press `Ctrl-C` to stop the watcher and app.

The watcher initializes `build/dev-support/library.sqlite3` from the canonical
development library. It preserves this working copy between launches.

Reset the working copy when a test scenario must start from the baseline:

```sh
./scripts/library-fixture.sh reset
```

Add representative feature data through the application. Validate and promote
the working copy only when that data must become part of the shared baseline:

```sh
./scripts/library-fixture.sh validate
./scripts/library-fixture.sh promote
```

Promotion validates SQLite integrity and foreign keys. It also regenerates
`testdata/library.sql` for review. Media binaries are not committed. A fresh
working copy therefore reports media as missing until its support directory
contains the referenced `sources/` and `clips/` files.

Run the complete test suite against an isolated copy:

```sh
./test.sh
```

If the app exits abnormally, the watcher copies the exact executable, its
dSYM, the newest macOS crash report, the binary UUID, and the Git revision into
`build/crashes/<timestamp>-<mode>/` before another build can replace them.

### Crash diagnosis

Run the app under LLDB when reproducing a deterministic interaction crash:

```sh
./dev-lldb.sh
```

LLDB prints all thread backtraces, ARM64 registers, the caller frame, and its
instructions when the process faults. Each launch stores the LLDB transcript,
exact executable, dSYM, UUID, and Git revision in
`build/lldb-sessions/<timestamp>/`. Run AddressSanitizer for heap use-after-free,
buffer overruns, and double releases:

```sh
./dev-asan.sh
```

Run the lifetime-tracing build to print CoreText and Core Video object
creation, retention, drawing, and release transitions:

```sh
./dev-trace.sh
```

Apple's allocator diagnostics are available as separate debug profiles:

```sh
./dev-memory.sh scribble
./dev-memory.sh guard-edges
./dev-memory.sh zombies
./dev-memory.sh guard-malloc
```

`scribble` poisons released allocations, `guard-edges` guards large heap
boundaries, `zombies` reports Objective-C messages sent after release, and
`guard-malloc` places allocations behind guard pages. These modes deliberately
consume more memory and run more slowly than `./dev.sh`.
