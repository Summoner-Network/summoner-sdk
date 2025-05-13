#!/usr/bin/env bash
set -e  # only -e, no -u so sourcing doesn’t abort on unset vars

# ─────────────────────────────────────────────────────
# Detect if script is being sourced or executed
# ─────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  SCRIPT_SOURCED=1
else
  SCRIPT_SOURCED=0
fi

die() {
  echo "❌ $*" >&2
  if [[ $SCRIPT_SOURCED -eq 1 ]]; then
    return 1
  else
    exit 1
  fi
}

usage() {
  die "Usage: $0 {setup|delete|reset|deps|test_server|clean} [build|test_build]"
}

# ─────────────────────────────────────────────────────
# Paths & Config
# ─────────────────────────────────────────────────────
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_REPO="https://github.com/Summoner-Network/summoner-core.git"
CORE_BRANCH="main"
SRC="$ROOT/summoner-sdk"
BUILD_FILE_BUILD="$ROOT/build.txt"
BUILD_FILE_TEST="$ROOT/test_build.txt"
BUILD_LIST="$BUILD_FILE_BUILD"
VENVDIR="$ROOT/venv"
DATA="$SRC/desktop_data"
PYTHON="python3"

# ─────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────


# GNU sed:        sed --version succeeds → use “-i”
# BSD/macOS sed:  sed --version fails     → use “-i ''”
if sed --version >/dev/null 2>&1; then
  SED_INPLACE=(-i)
else
  SED_INPLACE=(-i '')
fi

rewrite_imports() {
  local _unused_pkg=$1 dir=$2
  echo "    🔎 Rewriting imports in $dir"

  find "$dir" -type f -name '*.py' -print0 | while IFS= read -r -d '' file; do
    echo "    📄 Processing: $file"

    echo "      ↪ Before:"
    grep -E '^[[:space:]]*#?[[:space:]]*from[[:space:]]+(tooling|summoner)\.' "$file" \
      || echo "        (no matches)"

    local tmp_before
    tmp_before=$(mktemp -t rewrite_imports.XXXXXX) || { echo "      ❌ Failed to create temp file"; continue; }
    cp "$file" "$tmp_before"

    # ─────────────────────────────────────────────────────
    # Do the replacement in-place with sed (POSIX-safe regex)
    # ─────────────────────────────────────────────────────
    sed -E "${SED_INPLACE[@]}" \
      -e 's/^([[:space:]]*#?[[:space:]]*)from[[:space:]]+tooling\.([[:alnum:]_]+)/\1from \2/' \
      -e 's/^([[:space:]]*#?[[:space:]]*)from[[:space:]]+summoner\.([[:alnum:]_]+)/\1from \2/' \
      "$file"

    echo "      ↪ After:"
    # use awk instead of tail -n +4 for full POSIX compatibility
    diff_output=$(diff -u "$tmp_before" "$file" \
                  | awk 'NR>=4' \
                  | grep '^+[^+]' \
                  || true)
    if [[ -z "$diff_output" ]]; then
      echo "        (no visible changes)"
    else
      echo "$diff_output" | sed 's/^/        /'
    fi

    rm -f "$tmp_before"
  done
}



clone_native() {
  local url=$1 name
  name=$(basename "$url" .git)
  echo "📥 Cloning native repo: $name"
  git clone --depth 1 "$url" native_build/"$name"
}

# ─────────────────────────────────────────────────────
# Core Workflows
# ─────────────────────────────────────────────────────
bootstrap() {
  echo "🔧 Bootstrapping environment…"

  # 1) Clone core
  if [ ! -d "$SRC" ]; then
    echo "  📥 Cloning Summoner core → $SRC"
    git clone --depth 1 --branch "$CORE_BRANCH" "$CORE_REPO" "$SRC"
  fi

  # 2) Select build list
  echo "  🔄 Using build list: $BUILD_LIST"
  [ -f "$BUILD_LIST" ] || die "Missing build list: $BUILD_LIST"
  sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$BUILD_LIST" \
    | sed 's/^/    /'  # indent for readability

  # 3) Clone native repos
  echo "  🔄 Cloning native repos…"
  rm -rf native_build
  mkdir -p native_build
  repos=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line//$'\r'/}"
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
    repos+=("$line")
  done < "$BUILD_LIST"
  echo "  📋 Found ${#repos[@]} repos"
  for repo in "${repos[@]}"; do
    clone_native "$repo"
  done

  # 4) Merge tooling/ → summoner-sdk/summoner/
  mkdir -p "$SRC/summoner"
  for r in native_build/*/; do
    if [ -d "$r/tooling" ]; then
      for pkg_dir in "$r"/tooling/*; do
        [ -d "$pkg_dir" ] || continue
        pkg=$(basename "$pkg_dir")
        dest="$SRC/summoner/$pkg"
        echo "  🚚 Adding package: $pkg"
        cp -R "$pkg_dir" "$dest"
        rewrite_imports "$pkg" "$dest"
      done
    else
      echo "⚠️  No tooling/ in $r, skipping"
    fi
  done

  # 5) Create & activate venv
  if [ ! -d "$VENVDIR" ]; then
    echo "  🐍 Creating virtualenv → $VENVDIR"
    $PYTHON -m venv "$VENVDIR"
  fi
  # shellcheck source=/dev/null
  source "$VENVDIR/bin/activate"
  
  # 6) Install build tools
  echo "  📦 Installing build requirements"
  pip install --upgrade pip setuptools wheel maturin

  # 7) Write .env
  echo "  📝 Writing .env in core"
  cat > "$SRC/.env" <<EOF
LOG_LEVEL=INFO
ENABLE_CONSOLE_LOG=true
DATABASE_URL=postgres://user:pass@localhost:5432/mydb
SECRET_KEY=supersecret
EOF

  # 8) Reinstall Python & Rust extras
  echo "  🔁 Running reinstall_python_sdk.sh"
  bash "$SRC/reinstall_python_sdk.sh" rust_server_sdk

  echo "✅ Setup complete! You are now in the venv."
}

delete() {
  echo "🔄 Deleting environment…"
  rm -rf "$SRC" "$VENVDIR" native_build test_server*
  echo "✅ Deletion complete"
}

reset() {
  echo "🔄 Resetting environment…"
  delete
  bootstrap
  echo "✅ Reset complete!"
}

deps() {
  echo "🔧 Reinstalling dependencies…"
  [ -d "$VENVDIR" ] || die "Run setup first"
  source "$VENVDIR/bin/activate"
  bash "$SRC/reinstall_python_sdk.sh" rust_server_sdk
  echo "✅ Dependencies reinstalled!"
}

test_server() {
  echo "🔧 Running test_server…"
  [ -d "$VENVDIR" ] || die "Run setup first"
  source "$VENVDIR/bin/activate"

  cp "$SRC/desktop_data/default_config.json" test_server_config.json
  cat > test_server.py <<'EOF'
from summoner.server import SummonerServer
from summoner.your_package import hello_summoner

if __name__ == "__main__":
    hello_summoner()
    SummonerServer(name="test_Server").run(config_path="test_server_config.json")
EOF

  python test_server.py
}

clean() {
  echo "🧹 Cleaning generated files…"
  rm -rf native_build test_*.{py,json,log}
  echo "✅ Clean complete"
}

# ─────────────────────────────────────────────────────
# Dispatch
# ─────────────────────────────────────────────────────
case "${1:-}" in
  setup)
    variant="${2:-build}"
    case "$variant" in
      build)      BUILD_LIST="$BUILD_FILE_BUILD" ;;
      test_build) BUILD_LIST="$BUILD_FILE_TEST"  ;;
      *)          die "Unknown setup variant: $variant (use 'build' or 'test_build')" ;;
    esac
    bootstrap
    ;;
  delete)       delete       ;;
  reset)        reset        ;;
  deps)         deps         ;;
  test_server)  test_server  ;;
  clean)        clean       ;;
  *)            usage       ;;
esac
