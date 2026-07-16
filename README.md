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

The application stores its library in
`~/Library/Application Support/VocalTraining`. Only download media you are
authorized to download.

### Workflow

Paste one or more YouTube URLs into the command field and press **Execute**.
URLs are normalized by video ID, while timestamps supplied through `t`,
`start`, or `youtu.be` URL forms become initial playhead hints. Import prefers
an English caption track and otherwise accepts YouTube's original-language
automatic captions.

Select a source, load its captions, and click a timed transcript row to seek.
Mark the start and end of a useful section, then commit the range as an
exercise. Saved exercises appear in the exercise bank and play as standalone
clips when selected.

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
Typography uses 10.5 points throughout the interface and 21 points for the
`VOCAL TRAINING / SIGNAL WORKBENCH` title and `EXECUTE` action. Container text
is shaped as a complete CoreText line, then positioned from its measured
advance and ascent/descent metrics. Measurement, alignment, truncation, and
drawing reuse that same shaped line, preserving kerning, ligatures, fallback
fonts, combining marks, bidirectional ordering, and complex-script shaping.

The command field uses a segmented-border heading. Its top border stops eight
points before the heading and resumes eight points after the declared heading
width; the text origin, width, and border gap remain paired.

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
