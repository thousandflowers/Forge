# Roadmap

Forge converts files using Apple frameworks only. Nothing has to be installed
for it to work, and that constraint decides most of what follows: a format
macOS cannot read or write is a format Forge cannot offer without becoming a
wrapper around FFmpeg, pandoc or LibreOffice.

Everything below was measured on macOS 26 by asking the frameworks, not
recalled. `forge formats` prints the same answer for your machine.

## Already works

These need no code. Forge asks ImageIO and AVFoundation what the machine
supports, so they are live now and simply were not advertised.

| | |
|---|---|
| **AVIF** | read and write |
| **JPEG XL** | read |
| **Camera RAW** | CR2, CR3, NEF, ARW, DNG, RAF, ORF, RW2, PEF, SRW, IIQ and the rest ImageIO decodes |
| **PSD** | read and write |
| **ICO / ICNS** | read and write |
| **WebP** | read |
| **SVG / SVGZ** | read, drawn by QuickLook rather than ImageIO - on a machine whose QuickLook draws them, which Forge checks by drawing one |
| **PDF** | write, as an image destination |
| **ProRes, HEVC** | export presets exist; not yet reachable from the UI |
| **AC3, VOB** | read |
| **DOCX, RTF, ODT** | read, through AppKit's document readers |
| **FLAC, CAF, AIFF, WAV, M4A** | read and write |
| **Command line** | `forge`, sharing the engine and the presets with the app |
| **3D models** | OBJ, STL, PLY, ABC and USD read and written, USDZ read, through ModelIO |
| **Hot folders** | watched folders, with a guard against converting their own output |

## Planned

Native, no new dependencies, in rough order of value.

- [x] **OCR** - Vision reads text from images and scanned PDFs on device, in 30
      languages, selectable with `--ocr-language`. A PDF hands back its embedded
      text and reads only the pages that carry none.
- [x] **Video ↔ GIF** - both directions, plus multi-frame reading throughout, so
      an animation stays an animation and a still format gets one file per frame.
- [x] **Documents** - HTML, RTF, DOCX, ODT, Markdown and plain text convert to
      each other and to PDF, paginated with CoreText. Markdown is an input only:
      Foundation parses it and nothing on the system writes it back.
- [x] **Image ↔ PDF** - both directions, and an animation becomes a multi-page
      document rather than a pile of files.
- [x] **Codec choice** - ProRes, HEVC and H.264 for video; AAC, Apple Lossless,
      FLAC, Opus and uncompressed for audio. This is what made Apple Lossless
      and Opus reachable: they share containers with other codecs, so the
      container alone could never say which was meant.
- [x] **Multi-size ICO** - an icon carries 16 through 256, and a small source
      is not enlarged to fill the ladder.
- [x] **M4B** - the audiobook container. macOS types the extension as
      `com.apple.protected-mpeg-4-audio-b`, which is a quirk of the type
      database rather than a statement about the file: what Forge writes is
      plain AAC in an MP4 container, which is what a DRM-free audiobook is.
- [x] **Data files** - CSV, TSV, JSON and Property List between each other,
      with the awkward parts of separated values handled: quoted fields,
      separators and newlines inside them.
- [x] **Audio → video** - a recording asked for a movie container gets one.
- [x] **SVG and SVGZ** - QuickLook has a generator for SVG, so drawing one is a
      framework call after all, not the web view this was written off as
      needing. An `.svgz` is unpacked first, through the Compression framework,
      and checked against the size its own trailer claims. The drawing is made
      at the size asked for rather than at a default and scaled, and everything
      after it - format, quality, filters - is the ordinary image path, so an
      SVG can become a PDF as easily as a PNG.

      Not every Mac has that generator, and the ones that do not fail in the
      worst way: on macOS 14 the request succeeds and hands back a square that
      is not the artwork. Asking the type database is no help, so Forge draws a
      flat block of one colour at startup and reads the middle pixel back. If
      it is not the colour that went in, SVG is not offered at all - which is
      why `forge formats` lists `svg` on one machine and not on another.
- [x] **Metadata preservation** - images already carried EXIF and GPS across;
      audio did not carry anything, because the audio path writes with
      `AVAudioFile`, which has no notion of metadata. The tags are now put back
      on the finished file by a passthrough copy, so nothing is re-encoded.
- [x] **Subtitle files** - SubRip, WebVTT, SBV, SubViewer and MicroDVD are
      read; SubRip, WebVTT, SBV and plain text are written. macOS parses none
      of these and has a type for almost none of them, so this is one of the
      few places Forge reads a format itself - which is worth it because a cue
      is a start, an end and some words, and the formats differ in punctuation
      rather than in shape. MicroDVD counts frames and states its own rate, so
      it is read and deliberately not written: writing one means inventing a
      frame rate.

      Two things had to give way. `.srt` has no type at all, and the file
      model refuses an invented one - so an extension Forge genuinely parses
      is given a dynamic type that conforms to plain text, and everything
      else is still refused. And AVFoundation lists WebVTT among the types it
      opens, then finds no tracks in one, so the subtitle path is asked before
      the media path.
- [ ] **Embedded subtitle extraction** - the tracks are reachable, but the text
      is not: AVFoundation exposes no high-level reader for subtitle samples, so
      this means parsing sample buffers per format. Possible, and more work than
      it looks.
- [ ] **Signing and notarization** - needs a Developer ID. Until then the DMG is
      ad-hoc signed and Gatekeeper warns on first launch.
- [x] **Homebrew cask** - `Casks/forge.rb`, ready to copy into a tap. A cask
      rather than a formula because Forge ships an app bundle, and the tool is
      linked from inside it rather than installed twice.
- [x] **Text to speech** - any document becomes spoken audio, with the voices
      already installed.
- [x] **Audio transcription** - a recording, or a video's soundtrack, becomes
      text on device. Permission is asked once; nothing is uploaded.
- [x] **Completion notifications** - permission asked when the first batch
      finishes rather than at launch.
- [x] **Preset import/export** - one file or a set, with new identities on the
      way in so an import adds rather than replaces.
- [x] **Shortcuts integration** - a Convert Files action taking files, a preset
      name and a destination, running the same engine and the same presets.

### Interface

- [x] **In-app format overview** - the Capabilities screen, computed from the
      frameworks at run time, so it describes the machine it runs on.
- [x] **Quality and format controls in the convert screen** - an Adjust button
      overrides the preset's format, width and quality for one batch, without
      editing the preset.
- [x] **A summary before converting, and the real number after** - Overwrite
      and Move ask first, saying what changes and whether a copy is kept. There
      is deliberately no size *estimate*: it would be a guess. What is reported
      afterwards is measured - "1.4 MB written, 62% smaller".
- [x] **Filename suffix when resizing** - `photo-1280.jpg`. Converting one
      picture to three sizes used to give `photo.jpg`, `photo 2.jpg` and
      `photo 3.jpg`. Not applied when converting in place, where the file keeps
      the name it has.
- [x] **Reordering presets** - Move Up and Move Down. Presets were sorted by
      name, which is tidy and not the order anyone works in.
- [x] **A lower default image quality** - 80 rather than 85, measured: the step
      from 85 to 80 takes about a third off the file, and below 80 the curve
      flattens out.
- [x] **A sheet that asks the right question** - dropping files opens the
      Convert sheet, which offers only what the files in hand can honour: a PDF
      is offered pages, filters and a voice, a CSV is offered another data
      format and nothing else.
- [x] **Capabilities you can search, filter, and act on** - plus a pass over
      your own folders that puts the capabilities your files argue for first.
- [x] **Presets that ask instead of deciding** - a parameter is filled in at
      conversion time and can be spent in the filename.
- [ ] **Rank the format lists** - the image row is nineteen chips including
      ASTC, DDS, KTX and PVR, which nobody is looking for when converting a
      PDF. Order them by what your own presets target and what went in, and put
      the rest behind a More. Not a hardcoded shortlist: the ranking has to come
      from the data, or it goes stale the moment macOS adds an encoder.
- [ ] **History that leads somewhere** - a failed row says nothing about why it
      failed, does not carry the path it wrote, and offers neither Reveal in
      Finder nor a retry. The status is also shown twice per row, and the
      duration reads 0.0s on anything quick.
- [ ] **Every output in history** - a preset with two formats writes two files
      and history records the first. The files are all on disk; the record is
      not complete.
- [ ] **Aspect ratios in the crop block** - 16:9, 1:1, 4:5 rather than typing
      two numbers and knowing which is which.
- [ ] **Remember what a preset was last answered** - a preset that asks for a
      size asks again from its default every time.
- [ ] **Localization** - the app is English-only.
- [ ] **Finder action** - convert from the context menu, through a Finder
      extension. Needs a signed app extension, so it waits on notarization.
- [x] **Menu bar item** - pick a preset, pick files, pick a folder. A
      conversion is usually a small errand and going to the window for it is
      more ceremony than the errand deserves.

### Tools this Mac has, that Forge does not call yet

Forge finds `ffmpeg`, `pandoc`, `tesseract` and `fonttools` when they are
installed, and installs any of them with Homebrew from inside the app. The
cards say "installed, Forge does not call it yet" for the ones that are still
only found, rather than turning green on a promise.

Where a tool is wired, Forge keeps no list of what it can do: pandoc is asked
for its own input and output formats, and ffmpeg is asked by being run, since
working out which muxer a filename means is the whole of its job. A list here
would be wrong the day either of them gains a format.

Anything macOS can do itself is still done by macOS. A tool is only offered
the pair the frameworks turned down - which is what makes an MP4 to WMV
possible without changing what an MP4 to MOV does.

- [x] **Broadcast and legacy video through ffmpeg** - WMV, MXF, FLV, MKV, AVI,
      and AV1 or VP9 encoding. Measured: a 320x240 MP4 converts to ASF/WMV,
      Matroska and AVI, and `--resize` crosses as a scale filter.
- [x] **Office and ebooks through pandoc** - EPUB, DOCX and the rest of what
      pandoc lists. Measured: a Markdown file becomes a valid EPUB, `mimetype`
      and container included.
- [ ] **The OCR languages Vision does not have, through tesseract.**
- [ ] **Font conversion through fonttools** - and a way to find it: it installs
      into a Python user directory that a GUI app's PATH does not include, so
      Forge currently reports it missing on a Mac that has it.
- [ ] **A size ceiling on video and audio** - today only images are written,
      measured and written again lower until they fit. A video asked to come in
      under a size is not refused; the ceiling is simply not offered for it.

## Not planned, and why

Nothing here is a judgement about whether the format is worth having. Each line
is a reason it cannot be done the way Forge is built.

### macOS can read it but not write it

ImageIO and AVFoundation ship no encoder. Adding one means shipping a library.

- **WebP**, **JPEG XL** - both decode; neither encodes.
- **MP3** - AVFoundation has no MP3 encoder. This is why the old "Audio → MP3"
  preset produced AAC in a file named `.mp3`.
- **AC3 / EAC3** - decode only.

### macOS cannot read it at all

- **WMV**, **MXF** (XDCAM, DNxHD), **FLV**, **MPEG-TS / M2TS** - not among the
  types AVFoundation opens. MPEG-TS and VOB partly are; the container family as
  a whole is not.
- **EPS** - neither read nor write. Measured rather than assumed: `CGPSConverter`
  is still in the SDK, reports success, and writes a zero-byte file - PostScript
  conversion is gone on Apple silicon - and the QuickLook generator refuses an
  EPS with `QLThumbnailErrorDomain error 0`.
- **WMA**, **Sun Audio (AU)**, **True Audio (TTA)**, **WavPack**.
- **Fonts, in any direction** - CoreText reads a font's tables but has no
  public API to write one, so TTF to OTF is not a framework call. WOFF and
  WOFF2 do not even have a system type.

### No encoder for the codec

- **AV1**, **VP9**, **FFV1** - decoding depends on the Mac; encoding is not
  offered by VideoToolbox as an export preset.

### The format table needs a container/codec split first

Both of these encode on macOS today. They are blocked on design, not on the
platform, and are listed under Planned as "codec choice".

- **Apple Lossless (ALAC)** - shares the `.m4a` container with AAC, and the
  format table maps one container to one codec.
- **Opus** - written into a CAF container, which is already spoken for by PCM.

### It is another tool's job

Converting these means bundling and driving pandoc, LibreOffice or Calibre.
That is a different product, and it breaks the promise that Forge needs nothing
installed.

- **EPUB, MOBI, AZW, AZW3** - ebook formats.
- **XLSX / XLS, PPTX** - spreadsheets and presentations. Reading DOCX works only
  because AppKit happens to ship a reader; there is no equivalent for these.
- **Org-mode, Jupyter Notebook, OPML, MediaWiki, AsciiDoc, Typst, man, LaTeX,
  RST** - this is precisely pandoc's remit.
- **DOCX → PDF via LibreOffice** - the native route is planned; the LibreOffice
  one is not.

### No public API

- **ZIP, TAR, TGZ** - Foundation exposes no archive API. AppleArchive handles
  `.aar` only, and shelling out to `ditto` or `tar` is the external-tool
  problem wearing a hat.
- **YAML, TOML** - no parser in the standard library or in any Apple framework.
  CSV, JSON and Property List are supported precisely because Foundation has
  readers for them.
- **EML, EMLX, MSG** - no reader.
- **SubRip, SubViewer, MicroDVD** - no system parser for standalone subtitle
  files. Hand-writing one is possible but it is a parser to maintain, not a
  framework call.
- **glTF, GLB, FBX** - ModelIO reads and writes OBJ, STL, PLY, ABC and USD, and
  reads USDZ. These are not among them, and the Capabilities screen says so.

### Vision does not have the language

- **Greek OCR** - Vision recognises 30 languages, and Greek is not among them.
  Russian, Ukrainian, Arabic, Thai, Vietnamese and the Nordic languages are.
  Covering the rest means bundling Tesseract, which is an external tool with a
  language-data directory attached. `forge` will say which languages it has
  rather than pretending.

### Possible, but not with a framework call

- **SVG vectorization** (image → SVG) - needs a tracer. macOS has none.

### Nothing on this system translates

- **Subtitles or text in another language.** Renaming a subtitle track `_it` to
  get Italian is a good shape for the feature and there is nothing behind it:
  macOS 13 ships no offline translation API. Translation arrived in macOS 15 and
  is not reachable here, and the alternative is sending somebody's files to a
  server, which this app is not going to start doing quietly. If the deployment
  target ever moves to 15, this becomes possible on device and worth doing.

### Packs hosted by Forge

- **Downloading conversion packs from us.** A pack is code Forge did not build.
  Shipping one means pinning a source, publishing a checksum, signing it, and
  keeping all three current; in FFmpeg's case it also pulls that licence onto
  this project. Forge notices what your Mac already has and installs it with
  your own package manager instead. Same result, none of the supply chain.

### Not a Forge problem

- **"Error when downloading large PDFs"** - if this is happening in another
  converter, it is that tool's bug. Forge writes to a scratch file and moves it
  into place, so a partial write is never presented as a finished file.

## Decisions already taken

Recorded so they are not reopened by accident. Each was a real fork in the road.

- **libvips: no.** It would bring WebP encoding, which is the one real hole in
  ImageIO, and faster resizing on very large JPEGs. It would also mean shipping
  a C library inside the bundle, rewriting the claim that Forge needs nothing
  installed, and making sandboxing and notarization considerably harder. ImageIO
  already reads 55 image formats and writes 20.
- **A fixed 6×6 format matrix: no.** Deriving the list from the system is both
  less code and strictly more capable. A hand-written matrix would be a
  downgrade that also goes stale with every OS release.
- **YAML for configuration: no.** Presets, folders and history are JSON written
  by the app, never edited by hand, and Foundation has no YAML parser.
- **A separate engine library for the CLI: no.** Both front ends ship in the
  same binary, so a module split would mean marking about a hundred
  declarations public and gaining nothing.
- **A Homebrew formula: no, a cask.** Forge is an app bundle, not a bare
  executable, whatever the other repositories here do.
- **App Store: not for now.** Sandboxing is the blocker, not the paperwork:
  watched folders are stored as plain file URLs, and under the sandbox they
  would stop working after a relaunch unless every folder is kept as a
  security-scoped bookmark. That is a real piece of work whose only payoff is
  the store listing. Direct download with a notarized DMG comes first.

## Known limitations

True of the code as it stands. None of these is hidden by the app; they are
here so nobody has to rediscover them.

- **Tags cross only where the container holds them.** A converted recording
  keeps its title, artist and cover art in the MP4 family, which is where they
  were asked for; FLAC, WAV, AIFF and CAF come out untagged, because
  AVFoundation writes no metadata into them and Forge does not hand-roll a
  metadata chunk. Which containers can is asked of an export session rather
  than listed, so this follows the system rather than a table here.
- **No retry.** A conversion that fails because a file was still being written,
  or a device was briefly busy, is reported as failed. Everything else about
  transient failure is handled - nothing is half-written, nothing is destroyed -
  but the attempt is not repeated.
- **Cancel and per-file progress have no automated test.** Both are wired and
  work in the window, but they live in the SwiftUI view model, and testing them
  would need scaffolding out of proportion to the risk. The engine underneath
  them is tested.
- **Preset categories now decide what a preset is offered.** They pick the
  icon, and they also filter which steps the editor offers and which presets the
  Convert sheet shows for a given file. A preset filed under the wrong category
  will be offered the wrong steps; nothing checks that the category matches what
  the actions actually do.
- **The size ceiling is images only.** `ImageProcessor` writes, measures and
  rewrites. Video and audio have no such loop, so the ceiling is not offered for
  them rather than being offered and ignored.
- **A multi-format conversion records one output in history.** Both files are
  written and both are on disk; history keeps the first.
- **The app is unsigned and not notarized.** First launch needs right click,
  Open. The Finder extension waits on the same thing.
- **Not measured:** memory on a batch of thousands of files, and behaviour on
  Intel hardware. The binary is universal and the tests pass on Apple silicon;
  no one has run it on an Intel Mac.

## Where the line is

If a conversion needs a binary the user has to install, Forge says so, names the
tool, and offers to install it with the user's own package manager. What it does
not do is host that binary, bundle it, or download it behind the user's back. It
also never reports a capability as working because the tool is present: having
the tool and calling it are two different facts, and the screen keeps them
apart. `forge formats` and the format list
in the app are generated from the running system for the same reason: the app
should never offer something it cannot deliver.
