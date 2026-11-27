#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="release"
if [[ "${1:-}" == "--debug" ]]; then
  CONFIG="debug"
fi

APP_VERSION="${APP_VERSION:-1.0.0}"
APP_BUILD="${APP_BUILD:-1}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
UNIVERSAL="${UNIVERSAL:-0}"
ENTITLEMENTS_PATH="${ROOT_DIR}/Resources/GoClean.entitlements"

# Prefer full Xcode developer directory when available to avoid CLT SDK mismatches
if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

cd "$ROOT_DIR"

APP_DIR="${ROOT_DIR}/build/GoClean.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

if [[ "$UNIVERSAL" == "1" && "$CONFIG" == "release" ]]; then
  echo "==> Building Universal GoClean (arm64 + x86_64, release)..."
  swift build -c release --arch arm64 --arch x86_64 --disable-sandbox
  BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --disable-sandbox --show-bin-path)/GoClean"
else
  echo "==> Building GoClean (${CONFIG})..."
  swift build -c "$CONFIG" --disable-sandbox
  BIN_PATH="$(swift build -c "$CONFIG" --disable-sandbox --show-bin-path)/GoClean"
fi

cp "$BIN_PATH" "${MACOS_DIR}/GoClean"
chmod +x "${MACOS_DIR}/GoClean"

# Generate bespoke Luminous Orbital Map .icns app icon directly via CoreGraphics + ImageIO
ICON_TMP_BASE="$(mktemp -d /tmp/goclean-icon.XXXXXX)"

cat > "${ICON_TMP_BASE}/gen_icon.swift" <<'SWIFT'
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outICNSPath = CommandLine.arguments[1]
// Standard Apple ICNS PNG chunk types (16px through 1024px Retina)
let specs: [(fourCC: String, px: Int)] = [
    ("icp4", 16),
    ("icp5", 32),
    ("icp6", 64),
    ("ic07", 128),
    ("ic08", 256),
    ("ic09", 512),
    ("ic10", 1024),
    ("ic11", 32),
    ("ic12", 64),
    ("ic13", 256),
    ("ic14", 512)
]

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
var pngCache: [Int: Data] = [:]

func renderPNG(px: Int) -> Data {
    if let cached = pngCache[px] { return cached }
    guard let ctx = CGContext(
        data: nil,
        width: px,
        height: px,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("Failed to create CGContext") }

    let s = CGFloat(px)
    let inset = s * 0.06
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let bgPath = CGPath(roundedRect: rect, cornerWidth: s * 0.22, cornerHeight: s * 0.22, transform: nil)
    ctx.addPath(bgPath)
    ctx.clip()

    // Deep midnight-sapphire to twilight-teal backdrop (note: CGContext y=0 is bottom-left)
    let bgGrad = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(colorSpace: colorSpace, components: [0.07, 0.14, 0.28, 1.0])!,
            CGColor(colorSpace: colorSpace, components: [0.03, 0.07, 0.15, 1.0])!
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(bgGrad, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])

    // Subtle ambient emerald-cyan radial glow behind the prism
    let glowGrad = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(colorSpace: colorSpace, components: [0.09, 0.82, 0.74, 0.30])!,
            CGColor(colorSpace: colorSpace, components: [0.09, 0.82, 0.74, 0.0])!
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawRadialGradient(
        glowGrad,
        startCenter: CGPoint(x: s * 0.50, y: s * 0.44),
        startRadius: 0,
        endCenter: CGPoint(x: s * 0.50, y: s * 0.44),
        endRadius: s * 0.44,
        options: [.drawsBeforeStartLocation]
    )

    // Helper to flip top-left normalized coordinates to CoreGraphics bottom-left coordinates
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: s * x, y: s * (1.0 - y))
    }

    // 1. Upper frosted crystalline diamond prism facet
    let upperFacet = CGMutablePath()
    upperFacet.move(to: pt(0.48, 0.19))
    upperFacet.addLine(to: pt(0.73, 0.43))
    upperFacet.addLine(to: pt(0.46, 0.56))
    upperFacet.addLine(to: pt(0.21, 0.45))
    upperFacet.closeSubpath()

    ctx.saveGState()
    ctx.addPath(upperFacet)
    ctx.clip()
    let facetGrad = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(colorSpace: colorSpace, components: [1.0, 1.0, 1.0, 0.96])!,
            CGColor(colorSpace: colorSpace, components: [0.74, 0.90, 1.0, 0.78])!
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(facetGrad, start: pt(0.24, 0.19), end: pt(0.72, 0.56), options: [])
    ctx.restoreGState()

    // 2. Lower sweeping emerald-cyan ribbon blade
    let sweepBlade = CGMutablePath()
    sweepBlade.move(to: pt(0.21, 0.50))
    sweepBlade.addQuadCurve(to: pt(0.77, 0.52), control: pt(0.48, 0.69))
    sweepBlade.addLine(to: pt(0.50, 0.82))
    sweepBlade.addQuadCurve(to: pt(0.21, 0.50), control: pt(0.29, 0.71))
    sweepBlade.closeSubpath()

    ctx.saveGState()
    ctx.addPath(sweepBlade)
    ctx.clip()
    let bladeGrad = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(colorSpace: colorSpace, components: [0.08, 0.88, 0.72, 1.0])!,
            CGColor(colorSpace: colorSpace, components: [0.14, 0.58, 0.98, 1.0])!
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(bladeGrad, start: pt(0.22, 0.51), end: pt(0.75, 0.81), options: [])
    ctx.restoreGState()

    // 3. Crisp 4-point starlight sparkles (top-right)
    func drawSparkle(cx: CGFloat, cy: CGFloat, r: CGFloat, rgba: [CGFloat]) {
        let p = CGMutablePath()
        let inner = r * 0.26
        p.move(to: pt(cx, cy - r))
        p.addQuadCurve(to: pt(cx + r, cy), control: pt(cx + inner, cy - inner))
        p.addQuadCurve(to: pt(cx, cy + r), control: pt(cx + inner, cy + inner))
        p.addQuadCurve(to: pt(cx - r, cy), control: pt(cx - inner, cy + inner))
        p.addQuadCurve(to: pt(cx, cy - r), control: pt(cx - inner, cy - inner))
        p.closeSubpath()
        ctx.setFillColor(CGColor(colorSpace: colorSpace, components: rgba)!)
        ctx.addPath(p)
        ctx.fillPath()
    }

    drawSparkle(cx: 0.75, cy: 0.25, r: 0.11, rgba: [1.0, 1.0, 1.0, 0.98])
    drawSparkle(cx: 0.83, cy: 0.37, r: 0.052, rgba: [0.42, 0.96, 0.88, 0.96])

    // Crisp frosted inner rim highlight
    ctx.resetClip()
    ctx.setStrokeColor(CGColor(colorSpace: colorSpace, components: [1.0, 1.0, 1.0, 0.22])!)
    ctx.setLineWidth(max(1.0, s * 0.012))
    ctx.addPath(bgPath)
    ctx.strokePath()

    guard let cgImage = ctx.makeImage() else { fatalError("Failed to make CGImage") }
    let mutableData = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(mutableData, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Failed to create PNG destination")
    }
    CGImageDestinationAddImage(dest, cgImage, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("Failed to finalize PNG") }
    let data = mutableData as Data
    pngCache[px] = data
    return data
}

var body = Data()
for spec in specs {
    let png = renderPNG(px: spec.px)
    let chunkLen = UInt32(8 + png.count).bigEndian
    body.append(contentsOf: spec.fourCC.utf8)
    withUnsafeBytes(of: chunkLen) { body.append(contentsOf: $0) }
    body.append(png)
}

var icns = Data()
let totalLen = UInt32(8 + body.count).bigEndian
icns.append(contentsOf: "icns".utf8)
withUnsafeBytes(of: totalLen) { icns.append(contentsOf: $0) }
icns.append(body)

try icns.write(to: URL(fileURLWithPath: outICNSPath))
SWIFT

swiftc -module-cache-path "${CLANG_MODULE_CACHE_PATH:-/tmp/goclean-module-cache}" "${ICON_TMP_BASE}/gen_icon.swift" -o "${ICON_TMP_BASE}/gen_icon"
"${ICON_TMP_BASE}/gen_icon" "${RESOURCES_DIR}/AppIcon.icns"
rm -rf "$ICON_TMP_BASE"

cat > "${CONTENTS_DIR}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>GoClean</string>
    <key>CFBundleExecutable</key>
    <string>GoClean</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.goclean.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>GoClean</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${APP_BUILD}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>GoClean uses Finder and System Settings integration to reveal files and guide Full Disk Access setup.</string>
</dict>
</plist>
PLIST

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  echo "==> Ad-hoc signing ${APP_DIR}..."
  codesign --force --deep --sign - "$APP_DIR"
else
  echo "==> Signing ${APP_DIR} with Developer ID + Hardened Runtime..."
  CODESIGN_ARGS=(--force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY")
  if [[ -f "$ENTITLEMENTS_PATH" ]]; then
    CODESIGN_ARGS+=(--entitlements "$ENTITLEMENTS_PATH")
  fi
  codesign "${CODESIGN_ARGS[@]}" "$APP_DIR"
fi

codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "==> Successfully packaged ${APP_DIR}"
echo "Launch with: open \"${APP_DIR}\""
