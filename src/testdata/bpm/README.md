# Dancing BPM evaluation corpus

This directory defines the ten-song real-music seed corpus used to evaluate Dancing BPM estimation. The audio is local test data only: it is not part of the application, does not run in a normal build, and is intentionally not committed.

## Reproduce and verify

From the repository root, run:

```sh
scripts/fetch-bpm-test-corpus.sh
```

The script reads only the page and download URLs pinned in `manifest.json`. It supplies a normal browser user agent and each track page as the HTTP referrer because ccMixter rejects `HEAD`-style acquisition. Each new file is downloaded to a temporary file, checked for an accepted HTTP media type, inspected as MP3 audio with `ffprobe`, hashed with SHA-256, and atomically renamed. Existing files are re-inspected and must match both their checksum and recorded media properties.

`--record-checksums` is an explicit acquisition-maintainer mode. Use it only after reviewing an approved initial download whose manifest checksum is empty. It records the downloaded bytes' SHA-256 and exact `ffprobe` properties by atomically replacing the manifest. Normal verification refuses empty checksums and never changes the manifest.

Requirements: `python3`, `curl`, and `ffprobe` (Homebrew's `ffmpeg` formula supplies `ffprobe`).

## Labels and confirmation

The expected BPM values are publisher labels. ccMixter values come from its API `upload_extra.bpm` metadata. The Free Music Archive values are published in the track titles. Every label remains `published-unconfirmed`; neither the estimator under test nor another algorithm has confirmed it. A later independent musical evaluation can change the status to `confirmed`, `ambiguous-half-double`, or `rejected`.

The corpus spans 75–140 BPM and several rhythmic characters. `accepted_alternatives` remains empty until independent evaluation identifies a musically meaningful half- or double-time interpretation.

## License and attribution

All ten tracks are licensed under [Creative Commons Attribution 4.0 International](https://creativecommons.org/licenses/by/4.0/). The stored legal code comes from the exact URL <https://creativecommons.org/licenses/by/4.0/legalcode.txt> and has SHA-256 `9ba9550ad48438d0836ddab3da480b3b69ffa0aac7b7878b5a0039e7ab429411`. It is stored at [`licenses/CC-BY-4.0.txt`](licenses/CC-BY-4.0.txt). The license permits redistribution and adaptation under its terms. The repository nevertheless keeps the audio untracked (`redistributable: true`, `committed: false`).

No excerpts, format conversions, or other modifications were made. Each local file is the complete original MP3 from the pinned direct URL. Tests must generate temporary excerpts rather than changing these originals. The manifest is the authoritative record of title, artist, attribution source, direct source, BPM evidence, character, license, checksum, media properties, and modification status.

| BPM | Title — artist | Character | Attribution and source | BPM evidence | SHA-256 |
|---:|---|---|---|---|---|
| 75 | A Vida e Danca — Reiswerk | Latin/Brazilian | [track page](https://ccmixter.org/files/Reiswerk/70036) · [original MP3](https://ccmixter.org/content/Reiswerk/Reiswerk_-_A_Vida_e_Danca.mp3) · [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) | ccMixter `upload_extra.bpm` | `65c933431ac18b8c1bb6c61c3e312069c27a4981135b6e8b499b5357c2f389b7` |
| 80 | Happy Alchemy Beat — Coruscate | Downtempo hip-hop | [track page](https://ccmixter.org/files/Coruscate/70264) · [original MP3](https://ccmixter.org/content/Coruscate/Coruscate_-_Happy_Alchemy_Beat_1.mp3) · [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) | ccMixter `upload_extra.bpm` | `1edcf33b4eb27d5afffb6f7473eae79ed9589e63e9d5ec15254c5c3a512250a1` |
| 85 | Hocus Pocus — Coruscate | Funky trip-hop | [track page](https://ccmixter.org/files/Coruscate/70097) · [original MP3](https://ccmixter.org/content/Coruscate/Coruscate_-_Hocus_Pocus_2.mp3) · [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) | ccMixter `upload_extra.bpm` | `29238d19a98767522c0eb9567c571f0ea4a88bf27064abe846db49cc82cc2d3b` |
| 95 | TinTin — Lundstroem | Kid-friendly instrumental | [track page](https://freemusicarchive.org/music/lundstroem/happy-kid-friendly-songs/tintin-95-bpm/) · [original MP3](https://files.freemusicarchive.org/storage-freemusicarchive-org/tracks/2F1ejhQaKGPJSdEKBfAfZgQ5YDqTg9aNOpmvcKB3.mp3) · [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) | FMA title “TinTin - 95 bpm” | `ff65ac671d5f643a256431af3dd8f490a9319e415afb829e754de6cdcf7da95d` |
| 100 | Queen of Karma — sparky | Blues with live-style drums | [track page](https://ccmixter.org/files/sparky/70465) · [original MP3](https://ccmixter.org/content/sparky/sparky_-_Queen_of_Karma.mp3) · [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) | ccMixter `upload_extra.bpm` | `7eb3873ad5a12e51fcea3d7b59eb95f5fff1c805f9d049375298bee7a19ce3e7` |
| 105 | First Day — admiralbob77 | Electronic rock | [track page](https://ccmixter.org/files/admiralbob77/70456) · [original MP3](https://ccmixter.org/content/admiralbob77/admiralbob77_-_First_Day.mp3) · [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) | ccMixter `upload_extra.bpm` | `73679dcc7f794354016e5c76064b7324cf0a64eed27302f2c34fcfaa9fd4a156` |
| 115 | I Gotto To Be Me — rewob | Downtempo vocal | [track page](https://ccmixter.org/files/rewob/70105) · [original MP3](https://ccmixter.org/content/rewob/rewob_-_I_Gotto_To_Be_Me.mp3) · [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) | ccMixter `upload_extra.bpm` | `9e0fbdc07fdc0dd95743cba8706d05ea84cb459775f279e378b4ee600aa7a79b` |
| 128 | Cumberland Ferry — admiralbob77 | Electronic instrumental | [track page](https://ccmixter.org/files/admiralbob77/70143) · [original MP3](https://ccmixter.org/content/admiralbob77/admiralbob77_-_Cumberland_Ferry.mp3) · [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) | ccMixter `upload_extra.bpm` | `6fa7c56c6540c3a7912986297a076cab7ddf5717e5e8611a5dbdb7a2b9a3baad` |
| 130 | Fun time in 130 bpm — Lundstroem | Kid-friendly instrumental | [track page](https://freemusicarchive.org/music/lundstroem/happy-kid-friendly-songs/fun-time-in-130-bpm/) · [original MP3](https://files.freemusicarchive.org/storage-freemusicarchive-org/tracks/vPCYPUnKi558oRqh45bGV5Emm3dRa1fiYLtCVFSL.mp3) · [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) | FMA published track title | `ee65b96e3e711f8162724554421b74c06b493d6a48ccdcb455cbd962557fc862` |
| 140 | The Captain Is Mad (live remix) — Mr_Pepino | Live/generative techno | [track page](https://ccmixter.org/files/Mr_Pepino/70972) · [original MP3](https://ccmixter.org/content/Mr_Pepino/Mr_Pepino_-_The_Captain_Is_Mad_(live_remix).mp3) · [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) | ccMixter `upload_extra.bpm` | `1cc5c43ff957ea153b51c85f79941c623ecd75586ab98d7563c6d875a8dea689` |
