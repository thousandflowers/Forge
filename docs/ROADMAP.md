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
| **Hot folders** | watched folders, with a guard against converting their own output |

## Planned

Native, no new dependencies, in rough order of value.

- [ ] **OCR** - Vision reads text from images and scanned PDFs on device, in 30
      languages, with the language selectable. Nothing else here comes close on
      value per line of code.
- [ ] **Video ↔ GIF** - frames out with `AVAssetImageGenerator`, animated GIF in
      with a multi-frame `CGImageDestination`. Animated GIF decoding comes with it.
- [ ] **Documents** - DOCX/RTF/ODT/HTML → PDF, and Markdown in both directions,
      through `NSAttributedString` and PDFKit.
- [ ] **Image ↔ PDF** - both directions; the write half already exists.
- [ ] **Codec choice** - ProRes and HEVC for video, and the container/codec split
      described below for audio.
- [ ] **Multi-size ICO** - encoding several resolutions into one file.
- [ ] **M4B** - the audiobook variant of the M4A container.
- [ ] **Config files** - CSV ↔ JSON and JSON ↔ Property List, both Foundation.
- [ ] **Fonts** - TTF and OTF through CoreText.
- [ ] **Audio → video** - wrapping an audio file in an MP4 container.
- [ ] **Embedded subtitle extraction** - subtitle tracks inside a movie are
      reachable through AVFoundation.
- [ ] **Signing and notarization** - needs a Developer ID. Until then the DMG is
      ad-hoc signed and Gatekeeper warns on first launch.
- [ ] **Homebrew cask** - a cask, not a formula: Forge ships an app bundle.
- [ ] **Text to speech** - `AVSpeechSynthesizer` writes to a file, with 180
      voices across 49 languages already installed.
- [ ] **Audio transcription** - the Speech framework covers 63 locales and runs
      on device for the common ones, so a recording becomes text or subtitles
      without anything leaving the Mac.
- [ ] **Shortcuts integration**, **completion notifications**, **preset import/export**.

### Interface

- [ ] **In-app format overview** - the app knows exactly what it can read and
      write, and only the command line says so today (`forge formats`).
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
- **WOFF, WOFF2** - no system type; CoreText handles TTF and OTF only.

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
- **EML, EMLX, MSG** - no reader.
- **SubRip, SubViewer, MicroDVD** - no system parser for standalone subtitle
  files. Hand-writing one is possible but it is a parser to maintain, not a
  framework call.
- **glTF, GLB, FBX** - ModelIO imports OBJ, STL, PLY, ABC and USDZ, and exports
  the first four. These are not among them.

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

## Where the line is

If a conversion needs a binary the user has to install, Forge says it cannot do
it rather than doing it badly or silently. `forge formats` and the format list
in the app are generated from the running system for the same reason: the app
should never offer something it cannot deliver.
