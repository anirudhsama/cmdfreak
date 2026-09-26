#!/usr/bin/env bash
# Builds rust/wa-bridge and packages it as Packages/WACoreFFI (xcframework + Swift bindings).
# Idempotent. Pass --if-stale to skip when no Rust source is newer than the xcframework.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUST="$ROOT/rust"
PKG="$ROOT/Packages/WACoreFFI"
XCF="$PKG/WACoreFFI.xcframework"
TARGET=aarch64-apple-darwin
PROFILE="${BRIDGE_PROFILE:-release}"

export PATH="$HOME/.cargo/bin:$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin:$PATH"

if [[ "${1:-}" == "--if-stale" && -f "$XCF/Info.plist" ]]; then
  if [[ -z "$(find "$RUST" -path "$RUST/target" -prune -o \( -name '*.rs' -o -name 'Cargo.toml' -o -name 'Cargo.lock' \) -newer "$XCF/Info.plist" -print -quit)" ]]; then
    echo "wa-bridge up to date"
    exit 0
  fi
fi

# Xcode's build environment leaks SDK/arch settings that confuse cargo's host builds.
unset SDKROOT MACOSX_DEPLOYMENT_TARGET ARCHS CC CXX LD
# C dependencies (sqlite, ring) must target the app's minimum OS, not the build host's.
export MACOSX_DEPLOYMENT_TARGET=26.0

cd "$RUST"
PROFILE_FLAG=$([[ "$PROFILE" == release ]] && echo --release || echo "")
cargo build $PROFILE_FLAG --target "$TARGET" -p wa-bridge
LIB_DIR="$RUST/target/$TARGET/$PROFILE"

GEN="$RUST/target/uniffi-swift"
rm -rf "$GEN"
cargo run -q -p uniffi-bindgen -- generate --library "$LIB_DIR/libwa_bridge.dylib" --language swift --out-dir "$GEN"

STAGE="$RUST/target/xcf-stage"
rm -rf "$STAGE" && mkdir -p "$STAGE/Headers"
cp "$GEN/wa_bridgeFFI.h" "$STAGE/Headers/"
cat > "$STAGE/Headers/module.modulemap" <<'MAP'
module wa_bridgeFFI {
    header "wa_bridgeFFI.h"
    export *
}
MAP
cp "$LIB_DIR/libwa_bridge.a" "$STAGE/libwa_bridge.a"

rm -rf "$XCF"
xcodebuild -create-xcframework -library "$STAGE/libwa_bridge.a" -headers "$STAGE/Headers" -output "$XCF" >/dev/null

mkdir -p "$PKG/Sources/WACoreFFI"
cp "$GEN/wa_bridge.swift" "$PKG/Sources/WACoreFFI/wa_bridge.swift"
echo "wa-bridge → $XCF"
