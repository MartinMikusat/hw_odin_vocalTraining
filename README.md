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

Install Odin and ensure `odin` is on `PATH`, then build with:

```sh
./build.sh
open build/VocalTraining.app
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

It fingerprints `src/*.odin`, `build.sh`, and `Info.plist` every half-second.
A successful change rebuilds and relaunches the app; a failed build leaves the
currently running app untouched. Press `Ctrl-C` to stop the watcher and app.
Library data remains in Application Support across relaunches.
