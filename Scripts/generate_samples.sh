#!/bin/bash
set -e

# Generate sample test files for Forge development
RESOURCES="Tests/ForgeTests/Resources"
mkdir -p "$RESOURCES"

echo "Generating sample test files..."

# Generate test images using macOS built-in sips
# Small JPEG (100x100)
if [ -f "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/RedSquare.icns" ]; then
  sips --setProperty format jpeg --setProperty formatOptions 90 -z 100 100 \
    /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/RedSquare.icns \
    --out "$RESOURCES/test_small.jpg"
  echo "✓ Created test_small.jpg"
fi

# Medium PNG (1920x1080)
if [ -f "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/BlueSquare.icns" ]; then
  sips --setProperty format png -z 1920 1080 \
    /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/BlueSquare.icns \
    --out "$RESOURCES/test_large.png"
  echo "✓ Created test_large.png"
fi

# HEIC image (640x480)
if [ -f "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GreenSquare.icns" ]; then
  sips --setProperty format heif -z 640 480 \
    /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GreenSquare.icns \
    --out "$RESOURCES/test_medium.heic"
  echo "✓ Created test_medium.heic"
fi

# Generate test video (10 seconds, blue background) if ffmpeg available
if command -v ffmpeg &> /dev/null; then
  ffmpeg -y -f lavfi -i color=size=1280x720:duration=10:rate=30:color=blue \
    -c:v libx264 -pix_fmt yuv420p "$RESOURCES/test_video.mp4" 2>/dev/null
  echo "✓ Created test_video.mp4"
else
  echo "⚠ ffmpeg not found, skipping video test file"
fi

# Generate test audio (silence) if ffmpeg available
if command -v ffmpeg &> /dev/null; then
  ffmpeg -y -f lavfi -i anullsrc=duration=10:sample_rate=44100 \
    -c:a aac -b:a 128k "$RESOURCES/test_audio.m4a" 2>/dev/null
  echo "✓ Created test_audio.m4a"
fi

# Create a test text file
echo "Forge test file content" > "$RESOURCES/test.txt"
echo "✓ Created test.txt"

# Create a simple CSV test file
echo "Name,Age,City
Alice,30,New York
Bob,25,London
Charlie,35,Paris" > "$RESOURCES/test.csv"
echo "✓ Created test.csv"

echo ""
echo "Sample test resources generated in $RESOURCES"
echo "You can now run: swift test"
