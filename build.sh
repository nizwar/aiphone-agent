#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="AIPhone"
SCHEME="AIPhone"
PROJECT="AIPhone.xcodeproj"
BUILD_DIR="/tmp/${APP_NAME}-dmg-build"
DMG_OUTPUT="${SCRIPT_DIR}/${APP_NAME}.dmg"
DMG_BG="/tmp/dmg_background@2x.png"
DMG_VOLNAME="AI-Phone"
DMG_W=660
DMG_H=450

# ── Step 1: Clean build directory ────────────────────────────────────────────
echo "🧹 Cleaning build directory..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ── Step 2: Build ────────────────────────────────────────────────────────────
echo "🔨 Building ${APP_NAME} (Release)..."
xcodebuild -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  build \
  CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
  2>&1 | tail -5

if [ ! -d "${BUILD_DIR}/${APP_NAME}.app" ]; then
  echo "❌ Build failed — ${APP_NAME}.app not found in ${BUILD_DIR}"
  exit 1
fi
echo "✅ Build succeeded"

# ── Step 3: Generate DMG background ─────────────────────────────────────────
echo "🎨 Generating DMG background..."
python3 - <<'PYEOF'
from PIL import Image, ImageDraw, ImageFilter, ImageChops, ImageFont
import random

W, H = 660, 400
img = Image.new("RGB", (W, H))
draw = ImageDraw.Draw(img)

# Dark gradient base
for y in range(H):
    t = y / H
    draw.line([(0, y), (W, y)], fill=(int(8 + 10*t), int(12 + 18*t), int(28 + 22*t)))

# Cyan glow center-top
glow = Image.new("RGB", (W, H), (0, 0, 0))
gd = ImageDraw.Draw(glow)
cx, cy, mr = W // 2, int(H * 0.3), int(W * 0.7)
for i in range(mr, 0, -1):
    t = (1.0 - i / mr) ** 2.5
    gd.ellipse([cx-i, cy-i, cx+i, cy+i], fill=(0, int(180*t*0.25), int(255*t*0.35)))
img = ImageChops.add(img, glow.filter(ImageFilter.GaussianBlur(60)))

# Purple glow bottom-right
glow2 = Image.new("RGB", (W, H), (0, 0, 0))
gd2 = ImageDraw.Draw(glow2)
cx2, cy2, mr2 = int(W*0.75), int(H*0.8), int(W*0.4)
for i in range(mr2, 0, -1):
    t = (1.0 - i / mr2) ** 3
    gd2.ellipse([cx2-i, cy2-i, cx2+i, cy2+i], fill=(int(120*t*0.2), int(40*t*0.15), int(200*t*0.25)))
img = ImageChops.add(img, glow2.filter(ImageFilter.GaussianBlur(50)))

# Frosted glass band
img = img.convert("RGBA")
glass = Image.new("RGBA", (W, H), (0, 0, 0, 0))
gld = ImageDraw.Draw(glass)
bt, bb = int(H*0.30), int(H*0.72)
for y in range(bt, bb):
    a = 28
    if y < bt + 30: a = int(((y - bt) / 30) * 28)
    elif y > bb - 30: a = int(((bb - y) / 30) * 28)
    gld.line([(40, y), (W-40, y)], fill=(200, 220, 255, a))
img = Image.alpha_composite(img, glass.filter(ImageFilter.GaussianBlur(8)))

# Noise
random.seed(42)
noise = Image.new("RGBA", (W, H), (0, 0, 0, 0))
noise.putdata([(v:=random.randint(0,12), v, v, 8) for _ in range(W*H)])
img = Image.alpha_composite(img, noise)

# Separator line
ll = Image.new("RGBA", (W, H), (0, 0, 0, 0))
lld = ImageDraw.Draw(ll)
ly = int(H * 0.88)
for x in range(80, W-80):
    d = abs(x - W//2) / (W//2 - 80)
    lld.point((x, ly), fill=(150, 200, 255, int((1 - d**2) * 40)))
img = Image.alpha_composite(img, ll.filter(ImageFilter.GaussianBlur(1)))

# Hint text
tl = Image.new("RGBA", (W, H), (0, 0, 0, 0))
td = ImageDraw.Draw(tl)
try: font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 13)
except: font = ImageFont.load_default()
hint = "Drag AI-Phone to Applications"
tw = td.textbbox((0,0), hint, font=font)[2]
td.text(((W-tw)//2, H-48), hint, fill=(180, 200, 230, 120), font=font)
img = Image.alpha_composite(img, tl)

# Arrow
al = Image.new("RGBA", (W, H), (0, 0, 0, 0))
ad = ImageDraw.Draw(al)
ay, ax1, ax2 = int(H*0.52), int(W*0.38), int(W*0.62)
for x in range(ax1, ax2):
    d = abs(x-(ax1+ax2)//2)/((ax2-ax1)//2)
    a = int((1-d**2)*50)
    ad.point((x, ay), fill=(130,200,255,a))
    ad.point((x, ay+1), fill=(130,200,255,a//2))
for i in range(12):
    a = int((1-i/12)*50)
    ad.point((ax2-i, ay-i), fill=(130,200,255,a))
    ad.point((ax2-i, ay+i), fill=(130,200,255,a))
img = Image.alpha_composite(img, al.filter(ImageFilter.GaussianBlur(1.5)))

img.convert("RGB").resize((W*2, H*2), Image.LANCZOS).save("/tmp/dmg_background@2x.png", "PNG")
print("  Background generated (1320x800 @2x)")
PYEOF

# ── Step 4: Create DMG ──────────────────────────────────────────────────────
ICON_FILE="${BUILD_DIR}/${APP_NAME}.app/Contents/Resources/AppIcon.icns"

echo "📦 Packaging DMG..."
rm -f "$DMG_OUTPUT"

create-dmg \
  --volname "$DMG_VOLNAME" \
  --volicon "$ICON_FILE" \
  --background "$DMG_BG" \
  --window-pos 200 120 \
  --window-size "$DMG_W" "$DMG_H" \
  --icon-size 80 \
  --icon "${APP_NAME}.app" 175 190 \
  --app-drop-link 485 190 \
  --text-size 14 \
  --hide-extension "${APP_NAME}.app" \
  "$DMG_OUTPUT" \
  "${BUILD_DIR}/${APP_NAME}.app" 2>&1

echo ""
echo "✅ Done! DMG created at: ${DMG_OUTPUT}"
ls -lh "$DMG_OUTPUT"
