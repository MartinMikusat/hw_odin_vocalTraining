# hw_videoClips

An Apple Silicon macOS application for turning source videos into reusable
Vocal and Dancing clips.

## AI-assisted development disclosure

Models used:

- **gpt-5.6-sol**

## User guide

### Requirements

Install the media tools. Homebrew's FFmpeg formula supplies both `ffmpeg` and
`ffprobe`:

```sh
brew install yt-dlp ffmpeg
```

The app validates `yt-dlp`, `ffmpeg`, and `ffprobe` at startup and immediately before each media
operation. It prefers executables packaged in
`Contents/Resources/helpers/`, then searches the development machine's
`PATH`; it never installs or downloads tools itself.

The application requests the system monospaced interface font from AppKit.

The application opens as a square, borderless window without a native shadow.
Use the first three controls at the upper left to close, minimize, or zoom the
window. Use the gear control beside them to open Settings. Drag the title strip
to move the window. Drag a window edge or corner to resize it. The minimum
window size is 1100 by 720 points. The title shows the active workflow and
workspace beside `hw_videoClips`.

Use the gear control or `Command-,` to open the searchable two-column Settings
modal. Select `Styling` to choose HW Light or HW Dark. Select `Shortcuts` to
configure the Flash leader. The application stores both selections in its
local database.

Each project-styled modal uses one 80-percent backdrop over the visible
interface. Escape, Cancel, and a backdrop click dismiss ordinary modals. An
edited form requests confirmation before it discards unsaved changes. Required
recovery and backup decisions remain blocking.

The application stores its SQLite library and downloaded media in
`~/Library/Application Support/hw_videoClips`. On first launch, it moves an
existing `~/Library/Application Support/VocalTraining` directory to the new
location. It retains both directories when both contain a database. Existing
sources and clips migrate into the Vocal workflow. A pre-workflow backup can
restore missing Vocal clips once while preserving current clips and logged
deletions. The application archives an old `library.json` file after it
verifies the SQLite database. It never replaces an existing SQLite library
with the JSON file. Only download media you are authorized to download.

The application validates all required library rows before it enables writes.
If the read fails, the application blocks normal controls and opens Library
Recovery. It can restore the newest verified backup alone, or add valid newer
records and logged deletions. If no backup exists, it can build a library from
valid readable rows. Recovery keeps the failed database and its SQLite sidecar
files in the `Recovery` directory.

If the database comes from a newer application schema, this version keeps it
read-only and asks for a compatible application. It does not offer recovery
actions that could replace the newer database.

The application keeps the newest 10 verified database backups in `Backups`.
It creates a backup before source imports, source refetches, library
replacement, and schema migration. If a pre-change backup fails, the GUI
requires explicit confirmation before it continues.

### Workflow

The first title-strip control selects the independent **Vocal** or **Dancing**
workflow. Each workflow owns its own Sources and Clips. The second control
selects **Sources** or **Clips**. Sources shows ingest, the timed transcript,
range markers, clip naming, and export controls. The application saves this
workflow and workspace pair and restores it on the next launch.
Each workflow also saves its selected source and selected clip. A workspace
switch or application launch restores the saved row and loads its media without
starting playback.

Vocal uses Ochre in HW Light and Coffee in HW Dark for its primary interface
accent. Dancing uses `#36516F` in HW Light and `#7896B3` in HW Dark.
Both workflows use the same green colors for active and successful states.
Warnings and exceptional actions keep the orange accent in both workflows.

Vocal Clips gives 40% of the content width to a single column that stacks
the clip library above the video player, and 60% to the pitch monitor.
Vocal source and clip playback share one saved speed.

Dancing Clips gives 20% of the content width to the clip library, 60% to
video, and 20% to Dance Tools. Each Dancing clip stores its own playback speed,
horizontal mirror state, loop state, visual count-in, count-each-loop state,
and count-in BPM. Speed changes use 0.1x steps. A new Dancing clip starts at
1.0x, 120 BPM, with mirror, loop, and count-in disabled.

Press **31 Start Pitch** to begin live microphone analysis. The first start asks
macOS for microphone access. The app does not record or store microphone audio.
The chart keeps the newest 12 seconds of stable pitch and preserves the trace
when tracking stops. Starting again clears the trace. An input-only Core Audio
queue captures the microphone without connecting to the playback graph. When
the default input is a Bluetooth headset, the app uses the Mac's built-in
microphone to preserve high-quality headphone playback. Clip playback and
pitch tracking can run together.

The pitch settings select the A4 reference from 400 to 480 Hz, the visible
pitch window from 1 to 6 octaves, note labels, chromatic transposition, and
nearest-note highlight. The chart re-centers on the current voiced pitch and
holds position during silence, while the detector continues to accept the
full C1-to-C8 band so the window can catch up after a jump. The app
stores these settings locally. Label and transposition settings change only
the displayed note names. Select the pitch monitor **?** control for the
complete setting rules and microphone behavior.

In Clips, select **Randomize** to choose from the complete workflow clip library
and start playback. An active search does not limit the random pool. When two
or more clips exist, Randomize does not select the active clip.
Clips skipped by recent Randomize selections receive up to three times the
selection weight. Manual playback does not change this history. The application
stores the history locally and does not include it in library exports.
Select the **?** control inside Randomize to inspect the weighting rules and the
ten clips with the highest probability in the next draw.

Select **Play Next** to play the next clip in the filtered clip list.
The selection wraps to the first visible clip after the last result.
Enable **Shuffle** to make Play Next use the Randomize weighting rules within
the filtered results. Enable **Autoplay** to run Play Next when the current
clip finishes. Autoplay uses the current Shuffle state and current filter.

Dancing **Mirror** flips only the decoded video texture horizontally. Text and
controls retain their normal direction. **Count-in** cycles through Off, 4,
and 8. When a beat grid is available, the app schedules accented count clicks
against the audio host clock and preserves clip timestamp zero. **Metronome**
continues the four-beat click pattern during playback and is saved per clip.
**Count Each Loop** repeats the count before each loop. Selecting a clip or
pressing Play from the beginning starts the count. Pause and resume from a
later timestamp do not start another count. **Loop** restarts the active clip
and takes priority over Autoplay.

The app analyzes each Dancing clip's audio in the background and shows the
result below the count-in BPM controls. A suitable unambiguous result can
initialize an untouched BPM. Minus, plus, and **Use Auto** record an explicit
choice, so later analysis does not overwrite it. **Analyze Again** clears only
the cached detection and keeps the current count-in BPM. Low-confidence,
ambiguous, missing-audio, and unavailable results are reported without being
applied automatically. Tempo detection can be wrong; use the displayed result
as a suggestion and adjust the saved BPM when required.

Automatic analysis also estimates the beat grid. **Set 1** stores the current
playhead as the four-beat downbeat. **Earlier** and **Later** move that grid in
10 ms steps, and **Reset Auto** restores the detected phase. Synchronized
clicks remain disabled when phase is unavailable until Set 1 calibrates it.
The Practice Monitor draws the grid as vertical lines over the audio waveform,
with a stronger line on each four-beat downbeat. BPM and grid changes reposition
the lines immediately. The waveform separates the decoded audio into LOW below
200 Hz, MID from 200 Hz to 2 kHz, and HIGH above 2 kHz. **All** overlays the
three color-coded bands; selecting a band hides the other two. The application
uses one shared amplitude scale and saves the selected view globally.

With the app focused, press **Command-V** after copying one or more supported
YouTube URL lines. The application preserves the active workflow, switches to
Sources, opens Add Source, and starts the metadata check. If Add Source is
already open, it appends new URL lines and skips exact duplicates. Other
clipboard text keeps its normal focused-field paste behavior.

Press **Add** in the Source Register to open the ingest dialog manually, then
select either **YouTube URL** or **Local Files**. URL mode accepts one YouTube
URL per line. Local Files mode accepts **Browse Files…** selections and file
drops. A drop preserves the active workflow, switches to Sources, opens Add
Source directly in Local Files mode, and stages only the dropped files. Local
titles default to filenames without their extensions and remain editable until
import.

The application calculates each local file's SHA-256 and reuses an existing
source when the same content already exists in the active workflow. It copies
new media into the managed library. Compatible HEVC MP4 files with an `hvc1`
sample entry copy directly. Compatible HEVC streams in other containers or
with an `hev1` sample entry are remuxed and retagged. Other video streams are
normalized to HEVC/AAC MP4 with an `hvc1` sample entry. The original file
remains unchanged. Local video without audio is accepted; the Source and Clip
players show **NO AUDIO TRACK** while that media is loaded.

YouTube URLs are normalized by
video ID, while timestamps supplied through `t`, `start`, or `youtu.be` URL
forms become initial playhead hints. The dialog checks each URL in the
background and shows its title, duration, and available video resolutions.
Select a resolution for each video before import. The default is the best
available resolution at or below 1080p, or the lowest available resolution
when all options are higher.
Import fetches the selected H.264 MP4 video and M4A audio streams, merges them,
and then encodes the managed video as HEVC in an MP4 `hvc1` sample entry. It
copies the AAC audio without another audio encode. Import prefers an English
caption track and otherwise accepts YouTube's original-language automatic
captions. Right-click a source to open the Source Details dialog. It shows the
duration, resolution, frame rate, codecs, container, format ID, and local file
size. The app loads missing file metadata in the background after startup.
If YouTube requires sign-in, select an installed browser in the ingest dialog.
The app uses that browser's existing YouTube session for the metadata check and
download. It does not store or export browser cookies.
Enable **Save choice for later** before selecting a browser to reuse that
browser when a future request requires sign-in. Every metadata check starts
anonymously. The app reads the saved browser session only after YouTube rejects
the anonymous request. It stores only the browser name in its local database.
If the saved session fails, the app removes the preference and shows the
browser selector again.
Select **Refetch / Select Quality** to replace its media, metadata, and
captions. Refetch checks the source again and opens the same per-video quality
selector before it downloads replacement media.
The refetch operation also rebuilds each saved clip from that source at the
new resolution.
During a download, the footer shows its completion, current stream size,
transfer speed, and remaining time. Select **Stop** to terminate yt-dlp and
leave the source library unchanged.
The app downloads into staging files. It verifies the downloaded H.264 video
and AAC audio, converts the video to HEVC, verifies the `hvc1` sample entry,
decodes one second of both final tracks, and then replaces the active source
files. New and rebuilt standalone clips use the same HEVC MP4 video contract.
Existing H.264 sources and clips remain playable and are converted when a
source is refetched or a clip is rebuilt.

The Source Register marks a source as **MISSING** when its merged MP4 file is
not available. Right-click a YouTube source and refetch it. For a local source,
open Source Details and select **Locate Original…**. The selected file must
match the stored SHA-256 before the app restores its managed copy and rebuilds
its clips. Open its failed task in
the notification history to find the private `yt-dlp-<operation-id>.log`.

Source Details also provides **Delete Source…**. After confirmation and the
normal verified metadata-backup preflight, deletion removes the source record,
captions, timestamp hints, drafts, generated clips, and managed media. It never
removes the user's original local file. Portable backups contain metadata, not
video bytes.

Select a source, load its captions, and click a timed transcript row to seek.
Use the transcript search field to rank fuzzy caption matches. Clear the field
to restore the transcript's time order.
Mark the start and end of a useful section, then commit the range as a
clip. Saved clips appear in the clip bank and play as standalone
clips when selected. The Source Monitor and Practice Monitor use the same
playback controls. The volume controls adjust playback in 10% steps and retain
that level when another source or clip is loaded during the session. The
transport can play, pause, stop at zero, change speed, change volume, and scrub
across the loaded media waveform. Scroll vertically over the waveform to zoom
around the pointer, scroll horizontally to pan, and double-click to restore the
full-duration view. Waveform peaks are generated from decoded audio and retained
only in a bounded runtime cache. Frequency selection changes only the display;
it does not filter playback audio. Source reset seeks to the imported URL timestamp.
Clip reset seeks to the start of the clip.
The transport wraps complete control groups when the monitor becomes narrow.
It keeps transport, speed, volume, status, and fullscreen controls together in
their defined groups. The waveform stays in a separate full-width lane above
the rows. Each added row reduces the video region and cannot enter an adjacent
panel.
The application stores each source's mark-in, mark-out, and optional clip name
as a separate local draft. It restores these drafts after source changes and
application relaunches.
Each Commit appends an independent export. A successful export
clears its submitted draft only when that source's draft has not changed.
Failed exports and newer drafts retain their marks and names.
FFmpeg resets each exported clip's audio and video timestamps to zero. This
lets the paused player render the first video frame without advancing playback.
The media queue runs up to two source operations and two exports at once.
Eligible actions stay available while other media work runs.
Refetch, preview, repair, and recovery enter the same queue as ordered barriers.
Each footer task has its own Stop action.
The Sources footer highlights each missing range endpoint. It enables and
highlights **Commit** only after the range is at least one second long. The
footer shows the calculated clip duration beside the range.
Right-click a clip to open its Metadata dialog. Select **Delete Clip…** there
to remove the clip record and its managed video file after confirmation; the
source remains unchanged. Select a clip, then select **Rename** to edit its saved name. The rename
dialog keeps the original name visible above the new name field.
Select **Metadata** to inspect the clip identifier, source, range, duration,
source URL, clip path, and clip availability. Select the source URL to open it
in the default browser. Select the clip filename to reveal it in Finder. Select
**View Source** in that dialog to switch to Sources and load the clip source.
If a source has multiple imported timestamps, the Reset control becomes a
timestamp selector. Selecting a value seeks there and saves it as the source's
active timestamp.
The speed controls adjust playback from `0.1x` to `2.0x` in `0.1x` steps.
Select the expand control in the playback transport to fill the current
display without entering a macOS full-screen Space. The video keeps its aspect
ratio and uses black bars for the remaining area. While playback runs, the
transport and pointer hide after two seconds. Move the pointer or press a
playback key to reveal them. Press **F**, press **Escape**, double-click the
video, or select the collapse control to restore the previous window frame.

When no text field has focus, press **Space** to toggle playback or enter an
action's two-digit code. The first digit selects an action-bar section for one
second. The second digit activates its action. Escape or an invalid sequence
clears the selected section. Play and Space restart a completed video from the
beginning.

The Sources actions are **11 Captions**, **12 Data**, **21 Play**,
**22 Pause**, **23 Preview**, **24 Fullscreen**, **31 Mark In**,
**32 Mark Out**, and **33 Commit**.

The Vocal Clips actions are **11 Play Next**, **12 Randomize**, **13 Rename**,
**14 Metadata**, **15 Data**, **21 Play**, **22 Pause**, **23 Shuffle**,
**24 Autoplay**, **25 Fullscreen**, and **31 Start Pitch** or
**31 Stop Pitch**.

The Dancing Clips actions replace Pitch with **31 Mirror**, **32 Loop**,
**33 Count-in**, **34 Count Each Loop**, and **35 Metronome**. Dance Tools
exposes BPM and beat-grid calibration through pointer, Accessibility, Flash,
and the shared control registry.
Press **Left Arrow** or **Right Arrow** to scrub by one second. Hold **Shift**
to scrub by 0.1 seconds, or hold **Command** to scrub by 10 seconds.

Press **Control-K** to open the command palette from any application state.
Type to search commands, sources, and clips in one list. Use the arrow
keys to move, Return to select, and Escape to close the palette. Commands that
do not apply to the current mode remain visible with their unavailable reason.
Selecting a source switches to Sources and loads it. Selecting a clip
switches to Clips and starts it. The command palette shows records from the
active workflow.

If a clip file is missing, select that clip to rebuild it from
the saved source file and time range. The app updates the existing clip
record and starts playback after the rebuild. If the source file is also
missing, refetch the source first.

Press the configured Flash leader when no text field has focus to show keyboard
labels on all visible discrete controls. The default leader is `/`. Each label
is a compact mnemonic with two or three characters. For example, Mark In uses
`mi` and Mark Out uses `mo`. A unique mnemonic activates its control
immediately. If controls share one mnemonic, use Tab or Shift-Tab to select a
control, then press Return. Press **Escape**, click, scroll, or resize the
window to cancel label mode. A leader character typed in a focused text field
remains normal text. Press **Escape** to leave a focused text field and make
Flash navigation available again.

Drag across text to select a range. Double-click to select a word, or
triple-click to select the complete field. The selection supports replacement,
deletion, clipboard commands, and Shift-arrow extension. Hold **Option** with
Left Arrow or Right Arrow to move by words, and add **Shift** to extend the
selection. Hold **Command** to move to a line boundary. Option-Backspace
deletes the previous word.

Each source task writes `yt-dlp-<operation-id>.log` and a private progress
file in the application-support directory. Each clip task writes
`ffmpeg-<clip-id>-<operation-id>.log`. Use the **Data** control to open the
library data dialog. Press **01** to export both workflows, **02** to export
the current workflow, **03** to import, **04** to open the directory in Finder,
or **05** to close. Import reads the file scope and replaces only that scope.
Its confirmation actions use **01 Replace and Recover** and **02 Cancel**.

Select the footer notification to open the notification history. The modal
shows the newest entries first and keeps the selected entry visible while new
events arrive. Its detail pane shows timestamps, operation context, diagnostic
paths, and an available source action. Long operations update one history
entry until they finish. The footer shows up to four concurrent active tasks
and removes each task when it finishes. An overflow control opens the history
when more tasks are active. The application keeps the newest 10,000 entries in
its local SQLite database. Library export and import do not transfer or replace
this local activity history.

Library exports use the versioned `.hwvideoclips.json` format. They contain
source URLs, saved quality metadata, transcripts, timestamp hints, and clip
definitions, including Dancing clip settings. They do not contain downloaded
videos, local source videos, or clips. Local source records include the original
filename and content hash so recovery can validate a manually selected file.
Import validates the complete file, then replaces the selected
scope in one database transaction. Existing media files remain in place. The
app recovers each source sequentially at its exact saved resolution and
rebuilds its clips. Legacy `.vocaltraining.json` files import into Vocal only.
If that resolution is no longer available, the source remains missing for
manual refetch.

### Command-line control

The debug build creates `build/hw_videoClips`. Each command writes one JSON
result to standard output. Failed media commands include the diagnostic path.

```sh
build/hw_videoClips source add --url 'https://youtu.be/VIDEO_ID?t=120'
build/hw_videoClips source add --file '/absolute/path/lesson.mov' --name 'Lesson'
build/hw_videoClips source list
build/hw_videoClips source add --workflow dancing --url 'https://youtu.be/VIDEO_ID'
build/hw_videoClips source list --workflow dancing
build/hw_videoClips transcript get --source VIDEO_ID
build/hw_videoClips clip create \
  --source VIDEO_ID \
  --from-segment VIDEO_ID-12 \
  --to-segment VIDEO_ID-18 \
  --name 'Descending scale'
build/hw_videoClips clip list --source VIDEO_ID
build/hw_videoClips playback fullscreen --state on
build/hw_videoClips playback fullscreen --state off
./scripts/dev-cli.sh clip normalize-timestamps
```

Source, transcript, and clip commands accept `--workflow vocal|dancing`.
Vocal is the default. The command resolves video IDs within that workflow and
writes the workflow name into source and clip JSON results.

`source add` requires exactly one of `--url` or `--file`. A relative file path
is resolved from the command's working directory. `--name` overrides the local
filename-derived title and is valid only with `--file`.

`source add` selects compatible media at or below 1080p. Use `--max-height N`
to set another limit. The command downloads one URL at a time. If backup
verification fails, the command stops. Add `--allow-without-backup` to
explicitly continue without a new restore point.

`clip create` starts at the first segment start. It ends at the last segment
start plus its duration. The command saves an HEVC MP4 with an `hvc1` sample
entry as a standalone clip.

Debug builds also provide `clip normalize-timestamps`. The command requires the
running development application. It rebuilds Vocal and Dancing clips through
validated staging files, then atomically replaces each current clip. Rerun the
command after a partial failure or cancellation.

The GUI owns the library while it runs. CLI media commands append work to its
media queue and wait for the result without blocking the interface. Other CLI
commands use its private local socket. When the GUI is closed, the CLI locks
and updates the library directly.

`playback fullscreen` requires the running GUI. It applies the exact requested
`on` or `off` state without activating or raising the application. Its JSON
result reports the resulting `fullscreen` state and whether it `changed`.

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
`gui_not_running` when the development application is closed. Each snapshot
records playback and full-screen state, audio engine state, pitch tracking
state, microphone permission, detected frequency, pitch confidence, trace
count, and the submitted frame count.

The debug build can simulate concurrent task notifications without running
FFmpeg or `yt-dlp`:

```sh
./scripts/dev-cli.sh ui simulate-tasks --scenario parallel
./scripts/dev-cli.sh ui simulate-tasks --scenario completed
./scripts/dev-cli.sh ui simulate-tasks --scenario overflow
./scripts/dev-cli.sh ui simulate-tasks --scenario clear
```

`parallel` shows an active import and export. `completed` finishes the import
while the export stays active. `overflow` shows seven active tasks. `clear`
removes all simulated entries. Simulated entries stay in memory and do not
write to the notification database. The simulator rejects a scenario while a
real task is active.

## Development guide

### Architecture

A thin AppKit shell creates a borderless window and forwards input. The window
opens on the complete visible screen and has a minimum size of 1100 by 720
points. Odin calculates every visible control, including the custom close,
minimize, and zoom controls. `src/ui_registry.odin` converts the frame-owned
application controls into one validated framework registry. Pointer,
Accessibility, Flash, and numbered input read that registry. The same records
export command-menu and CLI capability metadata. `src/accessibility.odin` owns
the AppKit bridge. Metal renders the interface through one `CAMetalLayer`.

The custom Metal view conforms to `NSTextInputClient` and routes typing through
`interpretKeyEvents`. Command shortcuts and input methods stay on the AppKit
path. The `text_input` package from `hw_odin_ui_components` owns editing state
and mutations. The application owns strings, shaped CoreText lines, AppKit
event routing, and application actions. `hw_odin_ui_framework` stores the
ordered interface draw stream, caches glyphs in an atlas, and encodes its Metal
commands through one pipeline. The stream contains base geometry, live video,
text, modal backdrops, modal content, and fullscreen progress in display order.
AVPlayer decodes muted video, and Core Video maps its frames into Metal
textures. AVAudioEngine routes audio through a time-pitch unit, so speed changes
preserve vocal pitch. Audio configuration notifications restart and reschedule
this graph when the default output device changes.

The interface uses AppKit's system monospaced font and a measured immediate-mode layout.
Typography defines reusable body, label, and heading styles. The styles use
1x normal text with -0.45 tracking, 0.7x labels with neutral tracking, and 2x
bold headings with -0.7 tracking. The base size is 10.5 points. Container text
is shaped as a complete CoreText line, then positioned from its measured
advance and ascent/descent metrics. Measurement, alignment, truncation, and
drawing reuse that same shaped line, preserving kerning, ligatures, fallback
fonts, combining marks, bidirectional ordering, and complex-script shaping.
The application does not hard-code or bundle the concrete font family.

Bundled interface icon provenance:

- Assets: Iconoir xmark, minus, maximize, settings, expand, and collapse from version 7.11.1
- Source: [Iconoir commit `3497016dcb93122b5a64a2df1221598a14ecf4f3`](https://github.com/iconoir-icons/iconoir/tree/3497016dcb93122b5a64a2df1221598a14ecf4f3/icons/regular)
- Xmark SHA-256: `61aa0a4913a440aaafcc45064a87e24fe8eb22ba4abc4c5ef020530928ed8daf`
- Minus SHA-256: `babb05bca016bffdd38cbd1dcaeef6ccdf42fc8654124dee169a412eeed6d425`
- Maximize SHA-256: `3a3048cdc0e8e4aef5d68353b5434f0c0e074dc672b6c0abf25a5a64bc5cc8f4`
- Settings SHA-256: `437c253a1c11ff214c490c766f2a3cdcf8547399fd0be48a7d222bf0703aefb5`
- Expand SHA-256: `ca71adae412a313c2235ea1c22f7b4ea40abef1563995de827665bf89779a97d`
- Collapse SHA-256: `750107f450834d90a0f41e01d7c220d3c96f066af5c87d631006d1f1e19cc5fe`
- License: [MIT License](resources/icons/iconoir/LICENSE)

The application builds each visible interactive control once per frame. Each
control record contains a stable functional name, rectangle, typed action,
state, and capability flags. The framework borrows these records from the frame
arena and validates identifiers, rectangles, action references, labels, and
numbered codes. Each included direct interaction adapter resolves a control
identifier through the same registry. The application then executes its typed
action. Dynamic controls include a durable source, segment, or clip identifier
in their functional name. Static panels and labels stay outside the control
registry.

When a modal is open, the frame build produces two control projections from the
current application state and viewport. The base projection supplies rectangles
for background geometry and text. The active projection contains only the
topmost modal and permitted window controls. Pointer, keyboard, Accessibility,
Flash, command-menu, and live CLI input use only the active projection. This
keeps the complete interface visible below the backdrop without making a
background action available.

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
executes the selected opaque identifier. One session arena owns each open
entry snapshot. Query, result, and ranked-index buffers retain their capacity
between edits and sessions.

SQLite stores sources, transcript segments, hints, clips, source metadata,
source-specific clip drafts, library revisions, and entity changes. It also
stores the newest 10,000 structured notifications. Drafts remain local and do
not enter portable library exports. The main thread commits records, revisions,
and change rows in one transaction. `src/library_recovery.odin` owns verified
backups, tolerant row salvage, recovery candidates, and crash-safe activation.
A startup worker fills missing metadata from existing yt-dlp files. Startup
marks an unfinished notification as interrupted when the previous process did
not finalize its operation.

The sibling `hw_odin_concurrency_taskQueue` package owns worker threads,
priority ordering, cancellation, barriers, and resource limits. The
application assigns four workers, with limits of two source tasks and two
exports. It keeps queue state in memory. Each worker writes private staging and
diagnostic files, then asks the main thread to commit application state before
the queue releases its slot.

The portable library format is a separate JSON data-transfer schema. It omits
runtime file paths. Import derives each source and clip path from the selected
application-support directory, which permits transfers between development and
installed builds.

The repository contains the canonical development library in
`testdata/library.sqlite3`. Development launches use `build/dev-support`, and
tests use temporary copies. Installed builds continue to use the standard
macOS Application Support directory. Database file paths are relative to the
selected support directory.

### Memory ownership

The application renderer owns one virtual-memory frame arena. It holds the
control registry and temporary solid quads. The application converts each quad
to an ordered framework instance before the next frame resets the arena.
Accessibility bindings retain stable control identifiers instead of pointers
into the frame arena. The shared renderer creates one GPU instance buffer for
the ordered batches and retains frame textures until submission completes. Its
glyph atlas uploads only dirty regions and does not allocate a full-window CPU
text bitmap. Debug builds print the frame arena's high-water mark, reset count,
and allocation-failure count at shutdown.

Each import or export task owns a private growing arena and never reads the
mutable UI or application arrays after submission. The task queue passes each
completed job through a mutex-protected completion queue. The main thread
commits its result. The queue finalizer then destroys the task arena before it
releases the worker slot.
Transcript segments and every string reachable from them share one generation
arena. The generation also stores one contiguous segment span for each source.
Search and transcript retrieval pass the active source slice directly to their
consumers. Replacement installs the new generation before destroying the old
one.

Sources, import hints, clips, and mutable UI strings remain individually
heap-owned because they change independently. Core Foundation, Objective-C,
AVFoundation, and Metal objects retain explicit release calls; an arena reset
never substitutes for framework reference counting.

The command palette resets one growing arena when it closes. Its search context
and the transcript search context each reserve 64 MiB of virtual address space
and initially commit 64 KiB.

### Build

Install Odin and ensure `odin` is on `PATH`. Clone the sibling repositories
listed in [`dependencies.lock`](dependencies.lock) next to this repository.
The build imports the match sorter, Flash, command palette, UI components,
ordered UI framework, and task queue as named Odin collections.

[`dependencies.lock`](dependencies.lock) records each sibling repository URL
and tested commit. Every build rejects a checkout with another origin, commit,
or uncommitted change. After updating and validating the sibling libraries,
record their current commits:

```sh
./scripts/dependencies.sh update
./scripts/dependencies.sh check
```

Update dependencies to their latest compatible revisions promptly. Run all
library tests and the application tests before updating the lock.

The default build is unoptimized, includes debug information and assertions,
and emits a matching dSYM:

```sh
./build.sh
open build/hw_videoClips.app
```

Other build modes use separate output directories:

```sh
./build.sh trace    # debug build with Core Foundation lifetime logging
./build.sh asan     # AddressSanitizer
./build.sh release  # optimized production build
```

Debug and ASan builds compile Metal source at runtime when the optional shader
compiler is unavailable. Release builds require a bundled `ui.metallib`; use
`xcodebuild -downloadComponent MetalToolchain` to install its compiler.

The legacy scripted import form remains available and returns JSON:

```sh
build/hw_videoClips.app/Contents/MacOS/hw_videoClips --import 'https://youtu.be/VIDEO_ID?t=SECONDS'
```

### Release details

The current release task is tracked in [TODO.md](TODO.md). The current release
build is suitable for local development, but it is not yet a self-contained
build for non-technical users. Complete these items before external
distribution:

- Package pinned standalone `yt-dlp` and relocatable Apple Silicon `ffmpeg`
  and `ffprobe` executables under `Contents/Resources/helpers/`. Ship helper updates through
  new app releases; do not install Homebrew, mutate the user's global `PATH`, or
  download executables on first launch.
- Build the bundled FFmpeg configuration without the current GPL `libx264`
  dependency, retain managed-media encoding through `hevc_videotoolbox`, and
  include the required FFmpeg license notice, build configuration, and
  corresponding source location with the release.
- Add a packaging pipeline that signs each helper and then the app with a
  Developer ID Application certificate and hardened runtime, submits the
  archive for notarization, and staples the accepted ticket. No valid signing
  identity is currently installed on the development machine.
- Verify the quarantined artifact on a clean Apple Silicon Mac: Gatekeeper
  accepts a normal double-click launch, startup helper validation passes,
  import and clip export complete without Homebrew, and the final app size and
  embedded helper versions are recorded.

### Development loop

Run the dependency-free watcher during development:

```sh
./dev.sh
```

For debug, trace, and ASan modes, a source or resource change rebuilds the
complete application. The watcher replaces the running process only after a
successful build. A failed build leaves the current process active.

The first `./dev.sh` launch orders the window behind active applications. A
successful rebuild restores a frontmost app as frontmost. It leaves a
background replacement hidden until you activate it through the Dock or
application switcher. Direct launches activate normally. Metal validation is
enabled. Press `Ctrl-C` to stop the watcher and app.

The frame timer continues to poll jobs while the app is idle. It does not
submit Metal work until playback or a UI change requires it.
Pausing playback stops the audio node and engine. Resuming playback schedules
audio from the position stored by `AVPlayer`.

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

### Automated interface tests

The interface harness keeps one isolated application instance inactive,
hidden, and absent from the Dock. It exposes its temporary support directory
through `build/ui-test-support/app-support`. This avoids detached-process
access stalls under the repository's Documents path. Each checkout receives a
separate launch job and support directory. The harness leaves its instance
running between commands. A failed instance launch removes its launch job
before the harness exits. The harness also stops the process when Launch
Services classifies it as a foreground application.

The harness currently requires `jq`. Install it with `brew install jq` when the
command is unavailable.

Run a batched scenario, an individual integration gate, or the complete
interface suite:

```sh
./scripts/ui-test.sh run tests/ui/fast.json
./scripts/ui-test.sh persistence \
  tests/ui/persistent-mirror.json \
  tests/ui/persistent-mirror-verify.json
./scripts/ui-test.sh bridge
./scripts/ui-test.sh benchmark
./scripts/ui-test.sh visual
./scripts/ui-test.sh suite
```

Use `./scripts/ui-test.sh reset` for a fresh database. Use
`./scripts/ui-test.sh stop` to stop only the harness-owned instance.

A scenario sends one JSON request to the running app. Its steps can activate an
exact functional control, set an editable value, assert state, wait for state,
or capture a frame. The result separates startup, immediate, media, wait, and
capture time.

Mark a scenario as `transient` unless it must test a database write. A transient
scenario rejects persistent and external actions. It also fails when the
SQLite total-change count moves. The `persistence` command runs a persistent
mutation, restarts the application against the same database, and runs a
transient verification. It resets the isolated database when the pair ends.

The bridge suite routes the full-screen action through pointer input, keyboard,
the numbered action bar, Flash, the command menu, and the public CLI. AppKit
events enter the real view handlers without activating or showing the window.
The suite skips the system Accessibility path because macOS removes an
unordered window from the Accessibility tree. Run a separate visible-window
Accessibility check only when foreground interruption is acceptable.

The benchmark runs the ten-step warm scenario 20 times. It fails when the 95th
percentile reaches 100 milliseconds. Its steps open and close Settings twice,
so the gate measures typed action dispatch and control reconstruction. The
visual check applies and verifies a fixed 1280 by 800 point viewport.

Normal successful scenarios return compact JSON only. A failure writes the
scenario, result, UI snapshot, Metal frame PNG, overlay PNG, ordered render
trace, and best-effort GPU capture under
`build/ui-test-support/app-support/ui-runs/`. The app keeps the newest 20
bundles. The render trace records encoder creation, command-buffer completion,
and Metal failure text. The visual command writes the same bundle
intentionally. The compatibility-named `overlay.png` contains the complete
ordered framework stream because the renderer no longer has a separate overlay
pass.

`testdata/ui/playback-fixture.mp4` is a generated one-second test asset. It
contains 320 by 180 H.264 video and AAC audio. FFmpeg 8.0.1 generated it from
synthetic filters, so it contains no third-party media.

- SHA-256: `a107283834111060004105d689f61913a4faee9d55fd017fb09ebd588d82913b`
- Size: 16,151 bytes

#### UI test harness details

The current UI test task is tracked in [TODO.md](TODO.md).

Replace the shell harness JSON operations with an Odin helper. Remove the
`jq` runtime dependency after the helper validates scenarios, adds result
timings, aggregates persistence results, and calculates benchmark percentiles.

If the app exits abnormally, the watcher copies the exact executable, its
dSYM, the newest macOS crash report, the binary UUID, and the Git revision into
`build/crashes/<timestamp>-<mode>/` before another build can replace them.

The watcher samples resident memory every ten seconds. Two consecutive samples
above 1 GB create a live diagnostic bundle in `build/memory-diagnostics/`.
The bundle contains process, VM, footprint, heap, and stack data. It also
contains the binary UUID and Git revision. The watcher keeps the app running
and retains the newest 20 bundles. Set `HW_VIDEO_CLIPS_MEMORY_WARN_KB` to a lower positive
value when testing this guard.

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
