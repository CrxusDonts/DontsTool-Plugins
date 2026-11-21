#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="1.0.0"
REPO="CrxusDonts/DontsTool-Plugins"
UNIVERSAL_MODE="auto" # auto | force | native

usage() {
    cat <<'EOF'
Usage: scripts/build-release.sh [--version <semver>] [--repo <owner/repo>] [--universal | --native]

Builds all DontsTool official Swift plugins and example script plugins, signs Mach-O
binaries with ad-hoc codesign, packages dist/<plugin-id>-<version>-macos.dontsplugin.zip,
computes SHA-256 digests, and generates dist/catalog.json + root catalog.json.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            VERSION="${2:-}"
            shift 2
            ;;
        --repo)
            REPO="${2:-}"
            shift 2
            ;;
        --universal)
            UNIVERSAL_MODE="force"
            shift
            ;;
        --native)
            UNIVERSAL_MODE="native"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    echo "Error: --version cannot be empty" >&2
    exit 1
fi

cd "$ROOT_DIR"

SWIFT_PLUGINS=(
    "com.donts.kill-process:KillProcessPlugin:true"
    "com.donts.idea-projects:IDEProjectsPlugin:true"
    "com.donts.file-search:FileSearchPlugin:true"
    "com.donts.chrome:ChromePlugin:true"
    "com.donts.terminal-finder:TerminalFinderPlugin:true"
    "com.donts.quick-ai:QuickAIPlugin:true"
)

SCRIPT_PLUGINS=(
    "com.example.hello-sidecar:bin/run:false"
)

BIN_DIR=""
BUILD_ARCH_LABEL=""

build_universal() {
    echo "==> Building release binaries (Universal arm64 + x86_64)..."
    swift build -c release --arch arm64 --arch x86_64
    BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
    BUILD_ARCH_LABEL="universal (arm64 + x86_64)"
}

build_native() {
    local host_arch
    host_arch="$(uname -m)"
    echo "==> Building release binaries (native ${host_arch})..."
    swift build -c release
    BIN_DIR="$(swift build -c release --show-bin-path)"
    BUILD_ARCH_LABEL="native (${host_arch})"
}

if [[ "$UNIVERSAL_MODE" == "force" ]]; then
    build_universal
elif [[ "$UNIVERSAL_MODE" == "native" ]]; then
    build_native
else
    if ! build_universal; then
        echo "Warning: Universal build failed on this host; falling back to native architecture." >&2
        build_native
    fi
fi

echo "==> Build output directory: ${BIN_DIR} [${BUILD_ARCH_LABEL}]"

DIST_DIR="${ROOT_DIR}/dist"
STAGE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dontstool-plugins-stage.XXXXXX")"
trap 'rm -rf "$STAGE_ROOT"' EXIT

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

CATALOG_ENTRIES_FILE="${STAGE_ROOT}/entries.jsonl"
: > "$CATALOG_ENTRIES_FILE"

package_plugin() {
    local plugin_id="$1"
    local is_official="$2"
    local stage_dir="$3"

    local zip_name="${plugin_id}-${VERSION}-macos.dontsplugin.zip"
    local zip_path="${DIST_DIR}/${zip_name}"

    # Ensure manifest version matches release version inside packaged archive.
    python3 - "${stage_dir}/manifest.json" "$VERSION" <<'PY'
import json, sys
path, version = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    manifest = json.load(f)
manifest["version"] = version
with open(path, "w", encoding="utf-8") as f:
    json.dump(manifest, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY

    (
        cd "$stage_dir"
        rm -f "$zip_path"
        COPYFILE_DISABLE=1 zip -q -r -X "$zip_path" . -x "*.DS_Store" "__MACOSX/*"
    )

    local sha256
    sha256="$(shasum -a 256 "$zip_path" | awk '{print $1}')"
    local download_url="https://github.com/${REPO}/releases/download/v${VERSION}/${zip_name}"

    python3 - "${stage_dir}/manifest.json" "$plugin_id" "$VERSION" "$download_url" "$sha256" "$is_official" >> "$CATALOG_ENTRIES_FILE" <<'PY'
import json, sys
manifest_path, plugin_id, version, download_url, sha256, official_str = sys.argv[1:7]
with open(manifest_path, "r", encoding="utf-8") as f:
    m = json.load(f)
entry = {
    "id": plugin_id,
    "name": m["name"],
    "summary": m.get("description") or "",
    "version": version,
    "minHostVersion": m.get("minHostVersion"),
    "downloadURL": download_url,
    "sha256": sha256,
    "official": official_str.lower() == "true",
}
if entry["minHostVersion"] is None:
    del entry["minHostVersion"]
print(json.dumps(entry, ensure_ascii=False))
PY

    echo "    Packaged ${zip_name} (sha256: ${sha256})"
}

echo "==> Packaging Swift plugins..."
for spec in "${SWIFT_PLUGINS[@]}"; do
    IFS=":" read -r plugin_id exec_name is_official <<< "$spec"
    src_dir="${ROOT_DIR}/plugins/${plugin_id}"
    bin_src="${BIN_DIR}/${exec_name}"
    if [[ ! -f "$bin_src" ]]; then
        echo "Error: Missing built binary: ${bin_src}" >&2
        exit 1
    fi

    stage_dir="${STAGE_ROOT}/${plugin_id}"
    mkdir -p "${stage_dir}/bin"
    cp "${src_dir}/manifest.json" "${stage_dir}/manifest.json"
    cp "$bin_src" "${stage_dir}/bin/${exec_name}"
    chmod +x "${stage_dir}/bin/${exec_name}"
    codesign --force --sign - "${stage_dir}/bin/${exec_name}"

    package_plugin "$plugin_id" "$is_official" "$stage_dir"
done

echo "==> Packaging script plugins..."
for spec in "${SCRIPT_PLUGINS[@]}"; do
    IFS=":" read -r plugin_id entry_rel is_official <<< "$spec"
    src_dir="${ROOT_DIR}/plugins/${plugin_id}"
    stage_dir="${STAGE_ROOT}/${plugin_id}"
    mkdir -p "$stage_dir"
    cp -R "${src_dir}/." "$stage_dir/"
    chmod +x "${stage_dir}/${entry_rel}"

    package_plugin "$plugin_id" "$is_official" "$stage_dir"
done

echo "==> Generating catalog.json..."
python3 - "$CATALOG_ENTRIES_FILE" "${DIST_DIR}/catalog.json" "${ROOT_DIR}/catalog.json" <<'PY'
import json, sys
entries_path, dist_catalog_path, root_catalog_path = sys.argv[1:4]
plugins = []
with open(entries_path, "r", encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if line:
            plugins.append(json.loads(line))

catalog = {
    "schemaVersion": 1,
    "sourceName": "DontsTool 官方插件仓库",
    "plugins": plugins,
}

rendered = json.dumps(catalog, ensure_ascii=False, indent=2) + "\n"
for out_path in (dist_catalog_path, root_catalog_path):
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(rendered)
PY

echo "==> Done! Release artifacts in ${DIST_DIR} (${BUILD_ARCH_LABEL}):"
ls -lh "$DIST_DIR"
