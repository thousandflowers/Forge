# Shift v2

> A powerful, memory-efficient native macOS app for batch file conversion with smart automation.

[![Swift](https://img.shields.io/badge/Swift-5.9-orange)](https://swift.org)
[![macOS](https://img.shields.io/badge/macOS-12%2B-blue)](https://developer.apple.com/macos)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

## ✨ Features

### 🚀 Core Functionality
- **Universal Conversion**: Convert between any image, video, audio, and common document formats
- **Batch Processing**: Drop hundreds of files and process them all at once
- **Smart Automation**: Create "watched folders" that automatically transform incoming files
- **Memory Conscious**: Streaming processing keeps RAM usage low even with large files
- **Two-Tier Architecture**:
  - **Native** (default): Fast, low-memory Core Image & AVFoundation
  - **External** (opt-in): Support for niche formats via CLI tools (LibreOffice, ImageMagick, etc.)

### 🎯 Built-in Presets
- Social media: Instagram, Twitter, YouTube, TikTok, LinkedIn
- Email & web optimization
- Document conversions: PDF ↔ Images, text formats
- Custom: Create your own rules

### 🛠️ User Control
- Choose destination: Overwrite, copy, or move
- Adjust concurrency (1-8 parallel files)
- Enable/disable specific processors
- Backup protection before overwrite
- Full processing history with retry

## 📸 Screenshots

*Coming soon - Phase 1 in development*

## 🏗️ Architecture

Shift v2 is built from scratch with a focus on reliability and performance:

```
┌─────────────────────────────────────────────┐
│            SwiftUI Interface                │
├─────────────────────────────────────────────┤
│         ProcessingCoordinator               │
│   • Routes to appropriate processor        │
│   • Enforces concurrency limits            │
├─────────────┬──────────────┬───────────────┤
│   Native    │   External   │   (Phase 3)   │
│   Queue     │   Queue      │   Plugins     │
├─────────────┼──────────────┼───────────────┤
│ ImageProc   │ LibreOffice  │ UserDefined   │
│ VideoProc   │ ImageMagick  │ Blender       │
│ AudioProc   │ FFmpeg       │ ...           │
└─────────────┴──────────────┴───────────────┘
```

### Key Components
- **ProcessorRegistry**: Selects best processor for file type
- **AsyncQueue**: Controlled concurrency with actor isolation
- **RulePreset**: Serializable transformation pipelines
- **MonitoredFolder**: FSEvents-based folder watching
- **PersistenceManager**: JSON-based file storage (no CoreData)

## 🚀 Getting Started

### Prerequisites
- macOS 12.0 (Monterey) or later
- Xcode 15.0 or later
- Swift 5.9+

### Building from Source

```bash
# Clone the repository
git clone https://github.com/yourusername/Shift.git
cd Shift

# Build the project
swift build -c release

# Or open in Xcode
open Shift.xcodeproj
```

The built app will be at:
```
.build/release/Shift.app
```

### Running Tests

```bash
# Run all tests
swift test

# Run specific test target
swift test --filter ShiftTests
```

### Development Setup

1. Generate sample test files:
```bash
bash Scripts/generate_samples.sh
```

2. Ensure sample resources exist in `Tests/ShiftTests/Resources/`

## 📦 Installation

### From Releases
Download the latest `.dmg` from the [Releases page](https://github.com/yourusername/Shift/releases).

### From Source
```bash
swift build -c release
cp -R .build/release/Shift.app /Applications/
```

## 🎮 Usage

### Basic Batch Processing
1. Launch Shift
2. Drag & drop files into the window
3. Select a preset (e.g., "Instagram Post")
4. Choose destination (Overwrite, Copy To, Move To)
5. Click "Start Processing"

### Automatic Folders
1. Go to the "Folders" tab
2. Click "+" to add a folder
3. Assign a preset to that folder
4. Any file dropped in that folder will be automatically processed

**Example:**
- Create folder "Instagram Queue"
- Assign "Instagram Story" preset (1080×1920, JPEG, quality 85)
- Set destination to "Move To ~/Instagram/Ready"
- Drop photos in → they appear in Ready folder, already optimized!

### Creating Custom Presets
1. Go to "Presets" tab
2. Click "+"
3. Configure:
   - Target format (JPEG, PNG, MP4, etc.)
   - Resize dimensions
   - Quality (1-100)
   - Filter (grayscale, sepia, blur, etc.)
4. Save and use in batch/auto mode

## 🔧 Supported Formats (Phase 1)

### Images
- **Read/Write**: JPEG, PNG, TIFF, HEIC, WebP, BMP, GIF, TGA, ICO
- **Operations**: Convert, Resize (4 modes), Quality, Filters

### Video
- **Read**: MP4, MOV, M4V, AVI, MKV, WebM
- **Write**: MP4, MOV, M4V (H.264)
- **Operations**: Convert, Resolution, Bitrate/Quality

### Audio
- **Read**: MP3, WAV, M4A, AAC, FLAC, ALAC, AIFF
- **Write**: MP3, M4A, WAV, AAC, FLAC
- **Operations**: Convert, Bitrate, Sample Rate, Channels

### Documents
- **PDF**: Extract pages as images (JPEG/PNG/TIFF)
- **Text**: TXT, CSV, HTML, RTF (basic conversions)

## 🧩 Extensibility (Phase 3)

The plugin system allows you to add support for ANY file format:

- **LibreOffice**: DOCX, XLSX, PPTX ↔ PDF/ODT/ODS/ODP
- **ImageMagick**: PSD, AI, INDD → images
- **FFmpeg**: All video/audio codecs
- **Blender**: 3D formats (OBJ, FBX, STL, GLTF)
- **Pandoc**: Markup conversions (DOCX→EPUB, HTML→PDF)
- **Custom CLI**: User-defined command templates

Enable in Settings → check "External Tools".

## 🧪 Testing

The project includes comprehensive unit tests for all processors and models.

```bash
# Run tests with verbose output
swift test --verbose
```

### Test Coverage
- ✅ ProcessableFile model (file metadata extraction)
- ✅ Operation types (Codable, Hashable)
- ✅ RulePreset → operations conversion
- ✅ ImageProcessor (format conversion, resize, filters)
- ✅ VideoProcessor (reading/writing)
- ✅ AudioProcessor (codec conversion)
- ✅ SimpleDocProcessor (PDF → images)
- ✅ AsyncQueue concurrency control
- ✅ PersistenceManager (JSON serialization)

## 📁 Project Structure

```
Shift/
├── Sources/Shift/
│   ├── Models/
│   │   ├── ProcessableFile.swift
│   │   ├── Operation.swift
│   │   ├── RulePreset.swift
│   │   ├── MonitoredFolder.swift
│   │   ├── ProcessingHistory.swift
│   │   ├── AppSettings.swift
│   │   └── ProcessingError.swift
│   ├── Processors/
│   │   ├── FileProcessor.swift
│   │   ├── ImageProcessor.swift
│   │   ├── VideoProcessor.swift
│   │   ├── AudioProcessor.swift
│   │   └── SimpleDocProcessor.swift
│   ├── Services/
│   │   ├── AsyncQueue.swift
│   │   ├── PersistenceManager.swift
│   │   ├── ProcessorRegistry.swift
│   │   ├── ProcessingCoordinator.swift
│   │   └── MonitoredFolderWatcher.swift
│   ├── Views/
│   │   ├── ContentView.swift
│   │   ├── BatchProcessingView.swift
│   │   ├── MonitoredFoldersView.swift
│   │   ├── PresetsView.swift
│   │   ├── HistoryView.swift
│   │   ├── SettingsView.swift
│   │   └── PresetEditorView.swift
│   ├── ViewModels/
│   │   └── BatchProcessingViewModel.swift
│   ├── ShiftApp.swift
│   └── Shift.entitlements
├── Tests/ShiftTests/
│   ├── Models/
│   ├── Processors/
│   ├── Services/
│   └── Resources/
├── Scripts/
│   └── generate_samples.sh
├── docs/plans/
│   └── 2026-03-24-fileforge-redesign.md
├── Package.swift
├── README.md
└── LICENSE
```

## 🔮 Roadmap

### Phase 1 (Current) - MVP Core ✅ In Progress
- [x] Native image processing (convert, resize, filters)
- [x] Native video processing (convert, resolution)
- [x] Native audio processing (convert, bitrate)
- [x] Basic document processing (PDF → images)
- [x] Manual batch processing UI
- [x] Concurrency control
- [x] File-based persistence (presets, history)

### Phase 2 - Polish & Automation
- [ ] Automatic folder watching (FSEvents)
- [ ] Complete preset editor UI
- [ ] History view with retry
- [ ] Settings window (processor toggles, concurrency sliders)
- [ ] Error handling & user-friendly messages
- [ ] Notifications on completion
- [ ] Backup system for overwrites
- [ ] Performance optimization

### Phase 3 - Extensibility
- [ ] External tool detection (ImageMagick, FFmpeg, LibreOffice)
- [ ] ExternalProcessor base class
- [ ] User-defined converter UI (command templates)
- [ ] Preset import/export (JSON)
- [ ] Advanced rule engine (conditional operations)
- [ ] Support for PSD, INDD, 3D formats via plugins

### Phase 4 - Advanced Features
- [ ] Video filters (watermark, subtitles)
- [ ] Audio normalization (LUFS)
- [ ] Batch rename with patterns
- [ ] iCloud sync of presets
- [ ] CLI version (`fileforge` command)
- [ ] Share extension (Quick Actions)
- [ ] AppleScript/Shortcuts integration

## 🐛 Known Issues

- **Phase 1**: Only image/video/audio processing with native frameworks. No external tool support yet.
- **Video**: Advanced filters and complex operations not implemented.
- **Documents**: Only PDF → images and basic text conversions. No DOCX/XLSX yet.
- **Performance**: Large video files (>1GB) may take time, but memory usage should remain bounded.

## 🤝 Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

### Development Guidelines
- Follow Swift API Design Guidelines
- Write unit tests for new features
- Keep memory usage in check (streaming, no full loads)
- Use async/await and actors for concurrency
- Document public APIs with SwiftDoc comments

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- Built with ❤️ for macOS
- Uses Apple's Core Image, AVFoundation, SwiftUI
- Inspired by the original Shift (which needed a rebuild)

## 📧 Contact

For questions, feature requests, or bug reports:
- Open an issue on GitHub
- Email: your.email@example.com

---

**Note**: This is an alpha release. Use with caution on important files. Always keep backups.
