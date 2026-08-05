# TODO — hw_videoClips

## Active

- [ ] Validate confirmed source deletion across YouTube and local sources, including backup failure, active playback, generated clip cleanup, and residual-file reporting.
- [ ] Complete and validate local video source ingestion as required version-1 scope: separate URL and Local Files interfaces, file drop, managed copies, conditional normalization, content deduplication, exact-hash recovery, silent-video playback, and `source add --file`.
- [ ] Package pinned media helpers and produce a self-contained Developer ID-signed and notarized build for non-technical users. See [release details](README.md#release-details).
- [ ] Replace the UI test harness `jq` dependency with an Odin helper that validates scenarios, records timings, aggregates persistence results, and calculates benchmark percentiles. See [UI test harness details](README.md#ui-test-harness-details).

## Deferred

Cross-project Apple-platform interaction work is tracked in the [workspace
TODO](../TODO.md).
