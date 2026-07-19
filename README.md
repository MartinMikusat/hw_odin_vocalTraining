# Vocal Training

An Apple Silicon macOS application for turning sections of YouTube vocal
lessons into reusable practice exercises.

## AI-assisted development disclosure

**This application was built using GPT-5.6-Sol.**

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
initial playhead hints. Import fetches the best available MP4 video and M4A
audio streams and merges them without transcoding. Import prefers an English
caption track and otherwise accepts YouTube's original-language automatic
captions. Right-click a source to open the Source Details dialog. It shows the
duration, resolution, frame rate, codecs, container, format ID, and local file
size. The app loads missing file metadata in the background after startup.
Select **Refetch at Best Available Quality** to replace its media, metadata, and
captions.
The refetch operation also rebuilds each saved exercise from that source at the
new resolution.

Select a source, load its captions, and click a timed transcript row to seek.
Mark the start and end of a useful section, then commit the range as an
exercise. Saved exercises appear in the exercise bank and play as standalone
clips when selected. The Source Monitor volume controls adjust playback in 10%
steps and retain that level when another source is loaded during the session.

When no text field has focus, press **Space** to toggle playback or **1–8** to
activate the matching numbered transport control.

Download and export diagnostics are stored as `yt-dlp.log` and `ffmpeg.log` in
the application-support directory. Use the **Data** control to open that
directory in Finder.

## Development guide

### Architecture

A thin AppKit shell creates the window and forwards input. Odin calculates
every visible control, while Metal renders the interface through one
`CAMetalLayer`. CoreText rasterizes the text overlay, AVFoundation decodes
video, and Core Video maps decoded frames into Metal textures.

The interface uses Berkeley Mono and a measured immediate-mode layout.
Typography uses 10.5 points throughout the interface, including the compact
`VOCAL TRAINING` title. Container text is shaped as a complete CoreText line,
then positioned from its measured
advance and ascent/descent metrics. Measurement, alignment, truncation, and
drawing reuse that same shaped line, preserving kerning, ligatures, fallback
fonts, combining marks, bidirectional ordering, and complex-script shaping.

SQLite stores sources, transcript segments, hints, exercises, and source
metadata. The main thread commits state changes in transactions. A startup
worker fills missing metadata from existing yt-dlp files.

### Memory ownership

The renderer owns two virtual-memory arenas. The frame arena holds solid
geometry until `setVertexBytes` copies it into Metal's command stream, then the
next frame resets the complete arena. The redraw arena holds the scaled RGBA
overlay until `replaceRegion` copies it into the retained text texture, then
the next dirty redraw resets that arena. Debug builds print each arena's
high-water mark, reset count, and allocation-failure count at shutdown.

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

Install Odin and ensure `odin` is on `PATH`. The default build is unoptimized,
includes debug information and assertions, and emits a matching dSYM:

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

The same binary supports scripted imports for diagnostics:

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
