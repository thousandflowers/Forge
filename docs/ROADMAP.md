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
- [ ] **Multi-size ICO** - encoding several resolutions into one file.
- [ ] **M4B** - the audiobook variant of the M4A container.
- [x] **Data files** - CSV, TSV, JSON and Property List between each other,
      with the awkward parts of separated values handled: quoted fields,
      separators and newlines inside them.
- [ ] **Audio → video** - wrapping an audio file in an MP4 container.
- [ ] **Embedded subtitle extraction** - subtitle tracks inside a movie are
      reachable through AVFoundation.
- [ ] **Signing and notarization** - needs a Developer ID. Until then the DMG is
      ad-hoc signed and Gatekeeper warns on first launch.
- [ ] **Homebrew cask** - a cask, not a formula: Forge ships an app bundle.
- [x] **Text to speech** - any document becomes spoken audio, with the voices
      already installed.
- [ ] **Audio transcription** - the Speech framework covers 63 locales and runs
      on device for the common ones, so a recording becomes text or subtitles
      without anything leaving the Mac.
- [ ] **Shortcuts integration**, **completion notifications**, **preset import/export**.

### Interface

- [x] **In-app format overview** - the Capabilities screen, computed from the
      frameworks at run time, so it describes the machine it runs on.
- [ ] **Quality and format controls in the convert screen** - currently they
      live only inside a preset.
- [ ] **Estimated output size and a summary before converting** - worth having
      precisely because the destination modes can replace files.
- [ ] **Filename suffix when resizing** - `photo-1280.jpg` rather than
      overwriting the name.
- [ ] **Reordering presets** - drag, or move up and down.
- [ ] **A lower default image quality** - the default is 85; smaller files by
      default is a reasonable argument, and it is one constant.
- [ ] **Localization** - the app is English-only.
- [ ] **Finder action** - convert from the context menu, through a Finder
      extension. Needs a signed app extension, so it waits on notarization.
- [ ] **Menu bar item** - Forge is a window app today. A menu bar presence is
      additive, not a replacement.

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
- **EPS** - neither read nor write.
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

- **SVG rasterization** - WebKit can render SVG offscreen, so this is doable,
  but it means running a web view to convert a file.
- **SVG vectorization** (image → SVG) - needs a tracer. macOS has none.
- **SVGZ** - only useful once SVG itself is supported.

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

- **Only the first frame of a multi-frame image is read.** An animated GIF, a
  HEICS sequence or a multi-page TIFF converts to a single still. This is the
  same code path the video ↔ GIF work will replace.
- **No retry.** A conversion that fails because a file was still being written,
  or a device was briefly busy, is reported as failed. Everything else about
  transient failure is handled - nothing is half-written, nothing is destroyed -
  but the attempt is not repeated.
- **Cancel and per-file progress have no automated test.** Both are wired and
  work in the window, but they live in the SwiftUI view model, and testing them
  would need scaffolding out of proportion to the risk. The engine underneath
  them is tested.
- **Preset categories are decoration.** They pick an icon and a label, and
  filter nothing. Removing them would delete data already saved in everyone's
  presets, so they stay until there is a reason to touch them.
- **Not measured:** memory on a batch of thousands of files, and behaviour on
  Intel hardware. The binary is universal and the tests pass on Apple silicon;
  no one has run it on an Intel Mac.

## Where the line is

If a conversion needs a binary the user has to install, Forge says it cannot do
it rather than doing it badly or silently. `forge formats` and the format list
in the app are generated from the running system for the same reason: the app
should never offer something it cannot deliver.
