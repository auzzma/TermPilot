#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
python3 scripts/mobile/generate-design.py --check
export ANDROID_HOME=${ANDROID_HOME:-"$ROOT/.tools/mobile/android-sdk"}
# Hosted runners may export an NDK path for a different preinstalled version.
# Use the version installed by this project's CI unless explicitly overridden.
export ANDROID_NDK_HOME=${TERMPILOT_ANDROID_NDK_HOME:-"$ANDROID_HOME/ndk/28.2.13676358"}
export ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"
TARGET=${1:-aarch64-linux-android}
case "$TARGET" in
 aarch64-linux-android) ABI=arm64-v8a; CC_NAME=aarch64-linux-android30-clang; ARCH_INCLUDE=aarch64-linux-android ;;
 x86_64-linux-android) ABI=x86_64; CC_NAME=x86_64-linux-android30-clang; ARCH_INCLUDE=x86_64-linux-android ;;
 *) echo 'Unsupported mobile target' >&2; exit 2 ;;
esac
case "$(uname -s)" in Darwin) HOST=darwin-x86_64 ;; Linux) HOST=linux-x86_64 ;; *) echo 'Use macOS or Linux with Android NDK' >&2; exit 2 ;; esac
TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$HOST"
export "CC_${TARGET//-/_}=$TOOLCHAIN/bin/$CC_NAME"
export "CXX_${TARGET//-/_}=$TOOLCHAIN/bin/$CC_NAME++"
export "AR_${TARGET//-/_}=$TOOLCHAIN/bin/llvm-ar"
UPPER=$(echo "$TARGET" | tr '[:lower:]-' '[:upper:]_')
export "CARGO_TARGET_${UPPER}_LINKER=$TOOLCHAIN/bin/$CC_NAME"
export BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$TOOLCHAIN/sysroot -I$TOOLCHAIN/sysroot/usr/include/$ARCH_INCLUDE -D__ANDROID_API__=30"
export CARGO_PROFILE_RELEASE_LTO=thin
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=8
MEDIA="$ROOT/.tools/mobile/media-$ABI"
cmake -S engines/media-codec/mobile -B "$MEDIA" -DCMAKE_BUILD_TYPE=Release   -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake"   -DANDROID_ABI="$ABI" -DANDROID_PLATFORM=android-30 -DANDROID_STL=c++_shared
cmake --build "$MEDIA" --parallel 6
export TERMPILOT_MOBILE_MEDIA_LIB_DIR="$MEDIA/runtime"
cargo fetch --locked --target "$TARGET"
python3 scripts/build-privacy.py cargo build -p termpilot-mobile --lib --release --locked --target "$TARGET"
mkdir -p "apps/android/app/src/main/jniLibs/$ABI"
cp "target/$TARGET/release/libtermpilot_mobile.so" "apps/android/app/src/main/jniLibs/$ABI/"
"$TOOLCHAIN/bin/llvm-strip" --strip-debug "apps/android/app/src/main/jniLibs/$ABI/libtermpilot_mobile.so"
cp -L "$MEDIA"/runtime/*.so "apps/android/app/src/main/jniLibs/$ABI/"
cp "$TOOLCHAIN/sysroot/usr/lib/$ARCH_INCLUDE/libc++_shared.so" "apps/android/app/src/main/jniLibs/$ABI/"
cd apps/android
bash ./gradlew --no-daemon assembleDebug
