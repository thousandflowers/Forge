<div align="center">

# 🔨 Forge

> ⚠️ Alpha - in active development. Not ready for daily use yet.

**A fast, native macOS app for batch file conversion - no dependencies, no bloat.**

Drag in hundreds of images, videos, audio files, or PDFs. Pick a preset. Convert them all, in parallel, with RAM kept low by streaming. 100% Apple frameworks (Core Image, AVFoundation, PDFKit), zero external tools.

[![Build and Test](https://github.com/thousandflowers/Forge/actions/workflows/build.yml/badge.svg)](https://github.com/thousandflowers/Forge/actions/workflows/build.yml)
[![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange.svg)](https://swift.org)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue.svg)](https://developer.apple.com/macos)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

<img src="docs/screenshot.png" alt="Forge - batch file conversion on macOS" width="720">

</div>

## Why Forge

- **Native & dependency-free** - Core Image, AVFoundation and PDFKit do the work. No ImageMagick, FFmpeg or LibreOffice to install.
- **Batch-first** - drop hundreds of files; a new one starts the moment a slot frees up, so one long video does not hold up the queue.
- **Careful with your files** - conversions are written to a scratch file and moved into place, output names never collide silently, and converting in place can keep a backup of the original.
- **Watched folders** - assign a preset to a folder and anything dropped in is converted automatically (FSEvents).
- **Presets & history** - reusable transformation pipelines, full processing history, JSON-backed (no Core Data).

## Supported formats

Forge asks macOS what it can handle rather than shipping a list of its own, so
what you see in the app is what your machine can really do. On macOS 13+ that
comes to:

**Images** - reads everything ImageIO reads, which includes JPEG, PNG, TIFF,
HEIC, WebP, GIF, BMP, PSD, and camera RAW (CR2, CR3, NEF, ARW, DNG, RAF and
friends). Writes JPEG, PNG, TIFF, HEIC, GIF, BMP, AVIF, JP2, PSD, ICO, ICNS and
TGA. *WebP is read-only: macOS ships no WebP encoder.*
Operations: convert, resize (fit, fill+crop, stretch, pad), quality, filters.
EXIF, GPS and orientation are carried across.

**Video** - reads what AVFoundation reads (MP4, MOV, M4V, and more depending on
what is installed). Writes MP4, MOV and M4V, H.264 or HEVC, **keeping the audio
track**. Operations: convert, resolution, quality.

**Audio** - reads MP3, WAV, AIFF, M4A, AAC, FLAC and the rest of the
AVFoundation set. Writes M4A (AAC), WAV, AIFF, CAF and FLAC, at the source's own
sample rate and channel count. *There is no MP3 output: AVFoundation has no MP3
encoder.* Operations: convert, bitrate.

**Documents** - PDF to images, **every page**, one file per page. Plain text,
HTML and RTF to plain text.

## Install

### Download (recommended)
Grab the latest `.dmg` from the [**Releases page**](https://github.com/thousandflowers/Forge/releases), open it, and drag **Forge** to Applications. The build is universal (Apple silicon and Intel) and needs macOS 13 Ventura or later.

> Unsigned build: on first launch, right-click the app → **Open** to bypass Gatekeeper.

### Build from source
```bash
git clone https://github.com/thousandflowers/Forge.git
cd Forge
./Scripts/build_app.sh      # produces build/Forge.app
open build/Forge.app
```

`swift build` on its own produces a bare executable with no bundle, and macOS
treats that as a background agent: it runs, but no window ever appears. Use
`Scripts/build_app.sh`, which assembles the real app bundle.

Requires macOS 13+ (Ventura) and Swift 5.9+.

## Usage

**Batch convert**
1. Launch Forge, drag & drop files into the window.
2. Pick a preset (e.g. *Instagram Square*), choose a destination (Overwrite / Copy to / Move to).
3. Click **Convert**.

**Watched folder**
1. Open the **Folders** tab, add a folder, assign it a preset.
2. Anything dropped in that folder is converted automatically. Forge ignores the files it writes itself, so pointing the output back at the watched folder does not start a loop.

**Custom preset**
1. **Presets** tab → **+**.
2. Set target format, resize, quality (1-100), optional filter. Save - it is now usable in batch and watched-folder modes.

## Architecture

```
SwiftUI  ──▶  ProcessingCoordinator  ──▶  ProcessorRegistry  ──▶  Image / Media / Document processors
                     │                                              (Core Image · AVFoundation · PDFKit)
              output planning                         MonitoredFolderWatcher (FSEvents)
              scratch file + atomic move              PersistenceManager (JSON in App Support)
```

- **FormatCatalog** - asks ImageIO and AVFoundation what this machine can read and write. Nothing is offered that cannot be delivered.
- **ProcessorRegistry** - picks the processor for each file.
- **ProcessingCoordinator** - runs conversions, decides where output lands, keeps every write off files you already have, tracks tasks for cancellation.
- **MediaProcessor** - audio and video, split by the tracks a file actually contains rather than its extension.
- **PersistenceManager** - JSON storage for presets, history and monitored folders.

## Development

```bash
swift test                         # the unit suite
./Scripts/build_app.sh             # build build/Forge.app
./Scripts/make_dmg.sh              # package it as a DMG
bash Scripts/generate_samples.sh   # sample files for manual testing
```

Tests build their fixtures at runtime and store everything under a scratch
directory, so running them never touches the data the app keeps for you.

## Roadmap

- [x] Native image / video / audio / PDF conversion
- [x] Bounded-concurrency batch processing with live per-file progress
- [x] Presets, processing history, JSON persistence
- [x] Watched folders with loop protection
- [ ] Completion notifications
- [ ] Preset import/export
- [ ] Signing and notarization
- [ ] CLI (`forge`) + Shortcuts integration

## Contributing

PRs welcome. Fork → feature branch → tests green (`swift test`) → PR. Follow the Swift API Design Guidelines, keep memory bounded (stream, don't fully load), use async/await + actors.

## License

MIT - see [LICENSE](LICENSE).

## Acknowledgments

Built with Core Image, AVFoundation, PDFKit and SwiftUI. Inspired by the original Shift - this is a native, from-scratch rebuild.
