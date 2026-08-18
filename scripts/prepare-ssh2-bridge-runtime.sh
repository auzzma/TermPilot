#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="${TERMPILOT_SSH2_BRIDGE_RUNTIME_DIR:-$ROOT/Vendor/ssh2-bridge-runtime}"
CACHE_DIR="${TERMPILOT_SSH2_BRIDGE_CACHE_DIR:-$ROOT/.runtime-cache/ssh2-bridge}"
NODE_VERSION="${TERMPILOT_NODE_VERSION:-v22.13.1}"
SSH2_PATCH="${TERMPILOT_SSH2_PATCH:-$ROOT/patches/ssh2+1.17.0.patch}"

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required tool: $1" >&2
    exit 1
  fi
}

download() {
  local url="$1"
  local output="$2"
  if [[ -f "$output" ]]; then
    return
  fi
  mkdir -p "$(dirname "$output")"
  curl -fL --retry 3 --connect-timeout 20 "$url" -o "$output"
}

verify_sri_sha512() {
  local file="$1"
  local integrity="$2"
  local expected="${integrity#sha512-}"
  local actual
  actual="$(openssl dgst -sha512 -binary "$file" | openssl base64 -A)"
  if [[ "$actual" != "$expected" ]]; then
    echo "Integrity mismatch for $file" >&2
    exit 1
  fi
}

prepare_node_arch() {
  local arch="$1"
  local archive="node-${NODE_VERSION}-darwin-${arch}.tar.gz"
  local url="https://nodejs.org/dist/${NODE_VERSION}/${archive}"
  local checksum_file="$CACHE_DIR/node/${NODE_VERSION}/SHASUMS256.txt"
  local archive_path="$CACHE_DIR/node/${NODE_VERSION}/${archive}"

  download "https://nodejs.org/dist/${NODE_VERSION}/SHASUMS256.txt" "$checksum_file"
  download "$url" "$archive_path"

  local checksum_line
  checksum_line="$(grep "  ${archive}$" "$checksum_file" || true)"
  if [[ -z "$checksum_line" ]]; then
    echo "No checksum found for $archive" >&2
    exit 1
  fi
  printf '%s\n' "$checksum_line" > "$archive_path.sha256"
  (cd "$(dirname "$archive_path")" && shasum -a 256 -c "$(basename "$archive_path").sha256")

  rm -rf "$CACHE_DIR/node/${NODE_VERSION}/node-${NODE_VERSION}-darwin-${arch}"
  tar -xzf "$archive_path" -C "$CACHE_DIR/node/${NODE_VERSION}"
}

unpack_npm_package() {
  local target="$1"
  local version="$2"
  local url="$3"
  local integrity="$4"
  local modules_dir="$5"
  local archive="$CACHE_DIR/npm/${target}-${version}.tgz"
  local extract_dir="$CACHE_DIR/npm/${target}-${version}"

  download "$url" "$archive"
  verify_sri_sha512 "$archive" "$integrity"

  rm -rf "$extract_dir"
  mkdir -p "$extract_dir" "$modules_dir/$target"
  tar -xzf "$archive" -C "$extract_dir"
  local package_dir
  package_dir="$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  if [[ -z "$package_dir" ]]; then
    echo "Unable to find package directory inside $archive" >&2
    exit 1
  fi
  cp -R "$package_dir/." "$modules_dir/$target/"
}

prune_npm_development_files() {
  local modules_dir="$1"

  rm -rf \
    "$modules_dir/ssh2/test" \
    "$modules_dir/ssh2/examples" \
    "$modules_dir/ssh2/util" \
    "$modules_dir/ssh2/.github" \
    "$modules_dir/iconv-lite/.github" \
    "$modules_dir/iconv-lite/.idea"

  rm -f \
    "$modules_dir/ssh2/.eslintignore" \
    "$modules_dir/ssh2/.eslintrc.js" \
    "$modules_dir/ssh2/install.js" \
    "$modules_dir/ssh2/README.md" \
    "$modules_dir/ssh2/SFTP.md" \
    "$modules_dir/asn1/Jenkinsfile" \
    "$modules_dir/asn1/README.md" \
    "$modules_dir/bcrypt-pbkdf/CONTRIBUTING.md" \
    "$modules_dir/bcrypt-pbkdf/README.md" \
    "$modules_dir/safer-buffer/Porting-Buffer.md" \
    "$modules_dir/safer-buffer/Readme.md" \
    "$modules_dir/safer-buffer/tests.js" \
    "$modules_dir/tweetnacl/.npmignore" \
    "$modules_dir/tweetnacl/AUTHORS.md" \
    "$modules_dir/tweetnacl/CHANGELOG.md" \
    "$modules_dir/tweetnacl/PULL_REQUEST_TEMPLATE.md" \
    "$modules_dir/tweetnacl/README.md" \
    "$modules_dir/iconv-lite/Changelog.md" \
    "$modules_dir/iconv-lite/README.md"
}

materialize_runtime_allowlist() {
  local source_dir="$1"
  local destination_dir="$2"

  rm -rf "$destination_dir"
  mkdir -p \
    "$destination_dir/ssh2" \
    "$destination_dir/asn1" \
    "$destination_dir/bcrypt-pbkdf" \
    "$destination_dir/iconv-lite/lib" \
    "$destination_dir/safer-buffer" \
    "$destination_dir/tweetnacl" \
    "$destination_dir/cpu-features"

  cp -R "$source_dir/ssh2/lib" "$destination_dir/ssh2/lib"
  rm -rf \
    "$destination_dir/ssh2/lib/protocol/crypto/build" \
    "$destination_dir/ssh2/lib/protocol/crypto/src"
  rm -f "$destination_dir/ssh2/lib/protocol/crypto/binding.gyp"
  cp "$source_dir/ssh2/LICENSE" "$destination_dir/ssh2/"
  cp "$source_dir/ssh2/package.json" "$destination_dir/ssh2/"

  cp -R "$source_dir/asn1/lib" "$destination_dir/asn1/lib"
  cp "$source_dir/asn1/LICENSE" "$destination_dir/asn1/"
  cp "$source_dir/asn1/package.json" "$destination_dir/asn1/"

  cp "$source_dir/bcrypt-pbkdf/index.js" "$destination_dir/bcrypt-pbkdf/"
  cp "$source_dir/bcrypt-pbkdf/LICENSE" "$destination_dir/bcrypt-pbkdf/"
  cp "$source_dir/bcrypt-pbkdf/package.json" "$destination_dir/bcrypt-pbkdf/"

  cp -R "$source_dir/iconv-lite/encodings" "$destination_dir/iconv-lite/encodings"
  cp "$source_dir/iconv-lite/lib/bom-handling.js" "$destination_dir/iconv-lite/lib/"
  cp "$source_dir/iconv-lite/lib/index.js" "$destination_dir/iconv-lite/lib/"
  cp "$source_dir/iconv-lite/lib/streams.js" "$destination_dir/iconv-lite/lib/"
  cp "$source_dir/iconv-lite/LICENSE" "$destination_dir/iconv-lite/"
  cp "$source_dir/iconv-lite/package.json" "$destination_dir/iconv-lite/"

  cp "$source_dir/safer-buffer/dangerous.js" "$destination_dir/safer-buffer/"
  cp "$source_dir/safer-buffer/safer.js" "$destination_dir/safer-buffer/"
  cp "$source_dir/safer-buffer/LICENSE" "$destination_dir/safer-buffer/"
  cp "$source_dir/safer-buffer/package.json" "$destination_dir/safer-buffer/"

  cp "$source_dir/tweetnacl/nacl-fast.js" "$destination_dir/tweetnacl/"
  cp "$source_dir/tweetnacl/LICENSE" "$destination_dir/tweetnacl/"
  cp "$source_dir/tweetnacl/package.json" "$destination_dir/tweetnacl/"

  cp "$source_dir/cpu-features/index.js" "$destination_dir/cpu-features/"
  cp "$source_dir/cpu-features/package.json" "$destination_dir/cpu-features/"
}

for tool in curl tar shasum lipo patch openssl; do
  require_tool "$tool"
done

if [[ ! -f "$SSH2_PATCH" ]]; then
  echo "Missing bundled ssh2 patch: $SSH2_PATCH" >&2
  exit 1
fi

mkdir -p "$CACHE_DIR"
prepare_node_arch arm64
prepare_node_arch x64

TMP_DIR="$RUNTIME_DIR.tmp"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR/node/bin" "$TMP_DIR/node_modules"

lipo -create \
  "$CACHE_DIR/node/${NODE_VERSION}/node-${NODE_VERSION}-darwin-arm64/bin/node" \
  "$CACHE_DIR/node/${NODE_VERSION}/node-${NODE_VERSION}-darwin-x64/bin/node" \
  -output "$TMP_DIR/node/bin/node"
chmod 755 "$TMP_DIR/node/bin/node"

cp "$CACHE_DIR/node/${NODE_VERSION}/node-${NODE_VERSION}-darwin-arm64/LICENSE" \
  "$TMP_DIR/node/LICENSE"

unpack_npm_package \
  ssh2 \
  1.17.0 \
  https://registry.npmjs.org/ssh2/-/ssh2-1.17.0.tgz \
  sha512-wPldCk3asibAjQ/kziWQQt1Wh3PgDFpC0XpwclzKcdT1vql6KeYxf5LIt4nlFkUeR8WuphYMKqUA56X4rjbfgQ== \
  "$TMP_DIR/node_modules"
unpack_npm_package \
  asn1 \
  0.2.6 \
  https://registry.npmjs.org/asn1/-/asn1-0.2.6.tgz \
  sha512-ix/FxPn0MDjeyJ7i/yoHGFt/EX6LyNbxSEhPPXODPL+KB0VPk86UYfL0lMdy+KCnv+fmvIzySwaK5COwqVbWTQ== \
  "$TMP_DIR/node_modules"
unpack_npm_package \
  safer-buffer \
  2.1.2 \
  https://registry.npmjs.org/safer-buffer/-/safer-buffer-2.1.2.tgz \
  sha512-YZo3K82SD7Riyi0E1EQPojLz7kpepnSQI9IyPbHHg1XXXevb5dJI7tpyN2ADxGcQbHG7vcyRHk0cbwqcQriUtg== \
  "$TMP_DIR/node_modules"
unpack_npm_package \
  bcrypt-pbkdf \
  1.0.2 \
  https://registry.npmjs.org/bcrypt-pbkdf/-/bcrypt-pbkdf-1.0.2.tgz \
  sha512-qeFIXtP4MSoi6NLqO12WfqARWWuCKi2Rn/9hJLEmtB5yTNr9DqFWkJRCf2qShWzPeAMRnOgCrq0sg/KLv5ES9w== \
  "$TMP_DIR/node_modules"
unpack_npm_package \
  tweetnacl \
  0.14.5 \
  https://registry.npmjs.org/tweetnacl/-/tweetnacl-0.14.5.tgz \
  sha512-KXXFFdAbFXY4geFIwoyNK+f5Z1b7swfXABfL7HXCmoIWMKU3dmS26672A4EeQtDzLKy7SXmfBu51JolvEKwtGA== \
  "$TMP_DIR/node_modules"
unpack_npm_package \
  iconv-lite \
  0.6.3 \
  https://registry.npmjs.org/iconv-lite/-/iconv-lite-0.6.3.tgz \
  sha512-4fCk79wshMdzMp2rH06qWrJE4iolqLhCUH+OiuIgU++RB0+94NlDL81atO7GX55uUKueo0txHNtvEyI6D7WdMw== \
  "$TMP_DIR/node_modules"
unpack_npm_package \
  cpu-features \
  1.0.0 \
  https://registry.npmjs.org/empty-npm-package/-/empty-npm-package-1.0.0.tgz \
  sha512-q4Mq/+XO7UNDdMiPpR/LIBIW1Zl4V0Z6UT9aKGqIAnBCtCb3lvZJM1KbDbdzdC8fKflwflModfjR29Nt0EpcwA== \
  "$TMP_DIR/node_modules"

patch -p1 -d "$TMP_DIR" < "$SSH2_PATCH"
prune_npm_development_files "$TMP_DIR/node_modules"
materialize_runtime_allowlist \
  "$TMP_DIR/node_modules" \
  "$TMP_DIR/node_modules.allowlisted"
rm -rf "$TMP_DIR/node_modules"
mv "$TMP_DIR/node_modules.allowlisted" "$TMP_DIR/node_modules"

"$TMP_DIR/node/bin/node" -e \
  'const ssh2 = require(process.argv[1]);
   const iconv = require(process.argv[2]);
   if (!ssh2.Client || !iconv.encodingExists("utf8")) process.exit(1);' \
  "$TMP_DIR/node_modules/ssh2" \
  "$TMP_DIR/node_modules/iconv-lite"

rm -rf "$RUNTIME_DIR"
mkdir -p "$(dirname "$RUNTIME_DIR")"
mv "$TMP_DIR" "$RUNTIME_DIR"

echo "Prepared ssh2 bridge runtime at $RUNTIME_DIR"
