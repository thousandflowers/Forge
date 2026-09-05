<div align="center">

<img src="docs/icon.png" alt="Forge" width="168">

# Forge

**Batch file conversion for macOS. Photos, video, audio and PDFs, converted by the frameworks already on your Mac.**

<!-- TODO: demo GIF goes here. Drop the file at docs/screens/demo.gif and uncomment the line below.
<img src="docs/screens/demo.gif" alt="Dropping a folder of photos into Forge and converting it" width="820">
-->

Drop in a folder of photos, a video, a stack of PDFs. Forge asks what they should become, in the terms of what they are, and converts them in parallel without loading them all into memory. It is one binary that is both a Mac app and a command line tool, it works with Core Image, AVFoundation, PDFKit and Vision, and it asks macOS what this particular machine can read and write — so it never offers a conversion it cannot finish.

[![Build and Test](https://github.com/thousandflowers/Forge/actions/workflows/build.yml/badge.svg)](https://github.com/thousandflowers/Forge/actions/workflows/build.yml)
[![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange.svg)](https://swift.org)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue.svg)](https://developer.apple.com/macos)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

> Alpha. It works, it is tested, and it is still changing week to week.

</div>

## Drop the files, then answer one question

The Convert screen is a drop zone. The moment files land, Forge opens a sheet that asks what they should become, and it asks the right question for the files in hand:

- a **photo** gets format, size, quality, a look, and reading the text out of it
- a **video** gets format, resolution, codec, frame export and a transcript
- an **audio file** gets format, codec and a transcript
- a **PDF** gets format, page size, quality, a filter, and a voice to read it aloud
- a **CSV or JSON** gets one thing only, another data format, because that is all its processor accepts

A control that would be ignored is not shown. If it is on screen, something honours it.

<img src="docs/screens/capabilities.png" alt="The Capabilities screen" width="820">

## Presets are a starting point, not a mode

<img src="docs/screens/presets.png" alt="The Presets screen, one card per preset" width="820">

Pick a preset in the sheet and its settings fill in the fields below. Change any field and the preset lets go, because from that point the fields are the truth. Leave it alone and the preset runs exactly as saved, which matters when it holds something the sheet has no control for.

A preset can also **ask a question instead of deciding one**. Give it a parameter, say a maximum size, and Forge asks for the number when you convert rather than baking it in. The answer can go into the filename: name your files `{name}_{maxsize}` and a holiday photo comes out as `holiday_10MB.jpg`.

Choosing **more than one output format** does not replace the first with the second. It makes both, one copy per format, each with the rest of the chain applied.

## The magic conversions

Some conversions are not settings, they are things Forge works out from what you asked:

| You do this | Forge does this |
| --- | --- |
| Rename a file `holiday_10MB.jpg` | Compresses it under ten megabytes, keeping the best quality that fits |
| Convert a video to JPEG or PNG | Exports every frame, into a folder named after the clip |
| Convert a video to GIF | Turns the clip into an animated GIF, and a GIF back into video |
| Convert a recording to `.txt`, `.rtf`, `.docx` or `.pdf` | Transcribes it on device, into that format |
| Convert a scan or a photo to text | Reads it with Vision, on device |
| Convert a document to `.m4a` or `.wav` | Reads it aloud with a system voice |
| Convert a PDF to an image | Rasterises every page, not just the first |

The size ceiling is a promise about the result, not a setting handed to an encoder. Forge writes the file, measures it, and writes it again lower until it fits, spending quality first and pixels only after that runs out. If it truly cannot reach your number it says so, instead of handing back something unrecognisable that happens to be small.

## Capabilities, and what to do about the gaps

The Capabilities screen is computed at run time, so it describes your Mac rather than a claim written months ago. Search it, filter it by status, and ask it to **look at the files you actually have**: it counts the kinds of file in your own folders and puts the capabilities that would help you at the top. Only filenames are read, never contents, and only when you press the button.

Every conversion above is Apple's frameworks and nothing else: no ImageMagick, no FFmpeg, no LibreOffice, and nothing to install before Forge is useful. For the handful of jobs macOS cannot do alone, Forge names the tool that can and offers to install it with Homebrew from inside the app — the exact command shown once before it runs, its output live on the card. That tool is your Mac's, not Forge's: nothing is bundled in the app and nothing is downloaded by it, which keeps other people's licences off this project.

WebP is the one wired all the way through today. Install `cwebp` and images really do convert to WebP, with the format appearing only where an image processor will do the writing.

## How it compares

Forge is not trying to out-encode a specialist. HandBrake has spent twenty years on video and will beat Forge at video; ImageOptim squeezes PNGs harder than ImageIO does. What Forge has is breadth, nothing to install first, and presets that travel.

| | Forge | Permute | HandBrake | ImageOptim |
| --- | --- | --- | --- | --- |
| What it converts | images, video, audio, PDF, data, 3D, subtitles | images, video, audio | video, and the audio inside it | images |
| Where the converters come from | macOS itself | bundled with the app | bundled with the app | bundled with the app |
| What it offers is read from your Mac at run time | yes | no | no | no |
| Presets you can export, import and browse in a gallery | yes | presets, kept local | presets, importable files | no |
| Command line | the same binary | no | separate `HandBrakeCLI` | no official one |
| Licence | MIT | paid, closed | GPL-2.0 | GPL-2.0 |

Roadmap, not shipping today: metadata stripping on conversion, and downloading optional converters rather than asking Homebrew for them.

## A gallery you can search

<img src="docs/screens/gallery.png" alt="The Gallery screen" width="820">

Presets other people published, searchable by name, by author, by topic, and by what they actually do, so typing `jpeg` finds the ones that write JPEG rather than only the ones that say so. Filter by type, by output size, or by topic. Every card hands you that one preset as its own file, and your own presets do the same.

A preset is data, not code. It is a name and a list of actions Forge already knows how to run, so installing one cannot make the app do anything it could not already do.

## General preferences, and overriding them

Settings holds what resizing means (fit inside, fill and crop, stretch, pad out), the quality to use when a preset names none, and how new files are named. Each one is what happens when nothing else says otherwise. A preset overrides the general preference, a batch overrides the preset, and a size written into a filename overrides all of it.

## Careful with your files

- Conversions are written to a scratch file and moved into place, so nothing is ever read and written at the same path.
- Output names never collide silently. Two files heading for one name both arrive.
- Converting in place keeps a copy of the original in Backups, unless you turn that off.
- Replacing or moving originals asks first, and says how many files and whether anything can be got back.
- A watched folder ignores the files Forge itself writes, so pointing the output back at the input does not start a loop.

## Install

### Download

Grab the latest `.dmg` from the [Releases page](https://github.com/thousandflowers/Forge/releases), open it, drag Forge to Applications. Universal build, Apple silicon and Intel, macOS 13 Ventura or later.

The build is unsigned, so on first launch right click the app and choose Open.

### Homebrew

```bash
brew install --cask thousandflowers/tap/forge
```

### From source

```bash
git clone https://github.com/thousandflowers/Forge.git
cd Forge
./Scripts/build_app.sh      # produces build/Forge.app
open build/Forge.app
```

`swift build` on its own produces a bare executable with no bundle, and macOS treats that as a background agent: it runs, but no window ever appears. Use the script, which assembles the real app bundle.

## Command line

The same binary is also `forge`:

```bash
ln -s /Applications/Forge.app/Contents/MacOS/Forge /usr/local/bin/forge
```

```bash
forge convert *.png --to jpeg --quality 80 --out ./web
forge convert photo.heic --preset "Web JPEG" --out ~/Desktop
forge convert *.png --to jpeg --overwrite          # keeps a backup
forge watch ~/Desktop/incoming --preset "Web JPEG" --out ~/Desktop/web

forge presets              # the same presets the app shows
forge formats              # what this Mac can read and write
```

It reads the presets you save in the app, writes to the same history, and exits non zero if any file failed, so it drops straight into a script. Converted paths go to stdout, problems to stderr:

```bash
forge convert *.heic --to jpeg --out ./web --quiet > converted.txt
```

Completions come from the tool itself: `forge --generate-completion-script zsh` (or `bash`, or `fish`).

## Watched folders

Open the Folders tab, add a folder, give it a preset. Anything dropped in is converted on arrival, through FSEvents, with the same care about backups and names as everything else.

## How it fits together

```
SwiftUI  ──▶  ProcessingCoordinator  ──▶  Image / Media / Document / Data / Model processors
                     │                     (Core Image · AVFoundation · PDFKit · Vision · ModelIO)
              output planning              MonitoredFolderWatcher (FSEvents)
              scratch file, atomic move    PersistenceManager (JSON in Application Support)
```

- **FormatCatalog** asks ImageIO and AVFoundation what this machine can read and write. Nothing is offered that cannot be delivered.
- **ConvertKind** decides which controls a dropped file is worth being shown, taken from what its processor honours rather than from what sounds plausible.
- **ProcessingCoordinator** picks the processor, fills in the general preferences the preset left unsaid, runs the chain once per requested format, names the output from its template, and keeps every write off files you already have.
- **ExternalTools** notices the converters your Mac already has, and installs one when you ask.
- **PersistenceManager** stores presets, history and folders as plain JSON.

## Development

```bash
swift test                         # the whole suite
./Scripts/build_app.sh             # build build/Forge.app
./Scripts/make_dmg.sh              # package it as a DMG
```

Tests build their fixtures at run time and keep everything in a scratch directory, so running them never touches the data the app keeps for you.

## What is not here yet

- Translating subtitles into another language. macOS 13 has no offline translation API, and sending your files to somebody's server is not something this app is going to start doing quietly.
- FFmpeg, pandoc and tesseract are detected and installable, but only WebP is wired through to a real conversion so far. The cards say exactly that rather than pretending otherwise.
- Signing and notarization.

See [docs/ROADMAP.md](docs/ROADMAP.md) for the longer list, including what Forge will not do and why.

## Contributing

Fork, branch, keep `swift test` green, open a PR. Follow the Swift API Design Guidelines, keep memory bounded by streaming rather than loading, use async/await and actors.

## License

MIT. See [LICENSE](LICENSE).

Built with Core Image, AVFoundation, PDFKit, Vision and SwiftUI. Inspired by the original Shift, rebuilt from scratch as a native app.
