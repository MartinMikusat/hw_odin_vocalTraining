# Vocal Training

An Apple Silicon macOS application written in Odin. A thin AppKit shell creates
the application window and forwards input, while Odin lays out every visible
control and Metal renders the complete interface through one `CAMetalLayer`.
CoreText rasterizes the text overlay, and AVFoundation supplies decoded video
frames that Core Video maps into Metal textures. `yt-dlp` downloads YouTube
video metadata and timed captions and `ffmpeg` exports clips.
Import prefers an English caption track when available and otherwise accepts
YouTube's original-language automatic caption track.

## Interface

The interface uses the installed Berkeley Mono variable font and treats the
window as one technical instrument rather than a collection of native widgets.
The source register, video monitor, timed transcript, exercise bank, command
line, and transport rail share a measured grid.

The command field uses a reusable segmented-border heading: the box's top
border stops eight points before the heading and resumes eight points after its
declared width. Keep the heading text origin, declared width, and border gap
paired when applying this treatment to another field.

Typography uses two sizes: 10.5 points throughout the interface and 21 points
for the `VOCAL TRAINING / SIGNAL WORKBENCH` title only.

When no text field has focus, press **Space** to toggle playback or **1–8** to
activate the matching numbered transport control.

## Prerequisites

```sh
brew install yt-dlp ffmpeg
```

Install Odin and ensure `odin` is on `PATH`, then build with:

```sh
./build.sh
open build/VocalTraining.app
```

The same binary supports scripted imports for diagnostics:

```sh
build/VocalTraining.app/Contents/MacOS/VocalTraining --import 'https://youtu.be/VIDEO_ID?t=SECONDS'
```

## Development reload loop

Run the dependency-free watcher during development:

```sh
./dev.sh
```

It fingerprints `src/*.odin`, `build.sh`, and `Info.plist` every half-second.
A successful change rebuilds and relaunches the app; a failed build leaves the
currently running app untouched. Press `Ctrl-C` to stop the watcher and app.
Library data remains in Application Support across relaunches.

The application stores its working data in
`~/Library/Application Support/VocalTraining`. Only download media you are
authorized to download.

## Current workflow

Paste one or more YouTube URLs into the import field and press **Import**. URLs
are normalized by video ID, and `t`, `start`, or `youtu.be` timestamp forms are
retained as initial playhead hints. Imported media and metadata are written to
the application-support directory. The app exposes source, transcript, range,
and exercise-library panes. Select a source, press **Load Captions**, click timed
transcript rows to seek, capture start and end positions, then save the range.
The generated exercise appears in the right sidebar and plays as a standalone
clip when selected.

Download and export diagnostics are stored as `yt-dlp.log` and `ffmpeg.log` in
the application-support directory. Use **Data Folder** in the app to open that
directory in Finder.
