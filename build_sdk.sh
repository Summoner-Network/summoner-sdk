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
  find "$dir" -type f -name '*.py' -print0 \
    | while IFS= read -r -d '' file; do
      echo "    📄 $file"
      local tmp_before
      tmp_before=$(mktemp) && cp "$file" "$tmp_before"
      sed -E "${SED_INPLACE[@]}" \
        -e 's/^([[:space:]]*#?[[:space:]]*)from[[:space:]]+tooling\.([[:alnum:]_]+)/\1from \2/' \
        -e 's/^([[:space:]]*#?[[:space:]]*)from[[:space:]]+summoner\.([[:alnum:]_]+)/\1from \2/' \
        "$file"
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

  # 2) Validate build list
  echo "  🔄 Using build list: $BUILD_LIST"
  [ -f "$BUILD_LIST" ] || die "Missing build list: $BUILD_LIST"

  # show sanitized list
  echo
  echo "  🔄 Sanitized build list:"
  sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$BUILD_LIST" \
    | sed 's/^/    /'
  echo

  # 3) Parse build list into repos[] and features_list[]
  echo "  📋 Parsing $BUILD_LIST"
  rm -rf native_build
  mkdir -p native_build

  repos=()
  features_list=()
  current_url=""
  current_features=""

  while IFS= read -r raw || [[ -n "$raw" ]]; do
    # strip Windows CR + trim
    line="${raw//$'\r'/}"
    line="$(echo "$line" | xargs)"   # trim
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue

    if [[ "$line" =~ ^(.+\.git):$ ]]; then
      # url with a trailing colon → begin filtered block
      # save previous
      if [[ -n "$current_url" ]]; then
        repos+=("$current_url")
        features_list+=("$current_features")
      fi
      current_url="${BASH_REMATCH[1]}"
      current_features=""
    elif [[ "$line" =~ ^.+\.git$ ]]; then
      # plain url → include all tooling
      if [[ -n "$current_url" ]]; then
        repos+=("$current_url")
        features_list+=("$current_features")
      fi
      current_url="$line"
      current_features=""
    else
      # a feature name
      if [[ -z "$current_features" ]]; then
        current_features="$line"
      else
        current_features="$current_features $line"
      fi
    fi
  done < "$BUILD_LIST"
  # push last
  if [[ -n "$current_url" ]]; then
    repos+=("$current_url")
    features_list+=("$current_features")
  fi

  echo "    → Found ${#repos[@]} repos in build list"
  for url in "${repos[@]}"; do
    clone_native "$url"
  done

  # 4) Merge tooling/ → summoner-sdk/summoner/
  mkdir -p "$SRC/summoner"
  for idx in "${!repos[@]}"; do
    repo="${repos[$idx]}"
    features="${features_list[$idx]}"
    name=$(basename "$repo" .git)
    srcdir="native_build/$name/tooling"
    if [ ! -d "$srcdir" ]; then
      echo "⚠️  No tooling/ in $name, skipping"
      continue
    fi

    echo "  🔀 Processing tooling in $name"
    if [[ -z "$features" ]]; then
      # no filter → copy all
      pkg_dirs=( "$srcdir"/* )
    else
      # filtered → only these names
      pkg_dirs=()
      for pkg in $features; do
        if [ -d "$srcdir/$pkg" ]; then
          pkg_dirs+=( "$srcdir/$pkg" )
        else
          echo "    ⚠️  $name/tooling/$pkg not found, skipping"
        fi
      done
    fi

    for pkg_dir in "${pkg_dirs[@]}"; do
      pkg=$(basename "$pkg_dir")
      dest="$SRC/summoner/$pkg"
      echo "    🚚 Adding package: $pkg"
      cp -R "$pkg_dir" "$dest"
      rewrite_imports "$pkg" "$dest"
    done
  done

  # 5) Create & activate venv
  if [ ! -d "$VENVDIR" ]; then
    echo "  🐍 Creating virtualenv → $VENVDIR"
    $PYTHON -m venv "$VENVDIR"
  fi
  # shellcheck source=/dev/null
  source "$VENVDIR/bin/activate"

  # ─────────────────────────────────────────────────────
  # Install native‐repo requirements if present
  # ─────────────────────────────────────────────────────
  echo "  📦 Checking for native‐repo requirements..."
  for url in "${repos[@]}"; do
    name=$(basename "$url" .git)
    req="native_build/$name/requirements.txt"
    if [ -f "$req" ]; then
      echo "    ▶ Installing requirements for $name"
      python3 -m pip install -r "$req"
    else
      echo "    ⚠️  $name has no requirements.txt, skipping"
    fi
  done

  # 6) Install build tools
  echo "  📦 Installing build requirements"
  pip install --upgrade pip setuptools wheel maturin

  # 7) Write .env
  echo "  📝 Writing .env"
  cat > "$SRC/.env" <<EOF
DATABASE_URL=postgres://user:pass@localhost:5432/mydb
SECRET_KEY=supersecret
EOF

  # 8) Reinstall extras
  echo "  🔁 Running reinstall_python_sdk.sh"
  bash "$SRC/reinstall_python_sdk.sh" rust_server_sdk

  echo "✅ Setup complete! You are now in the venv."
}

delete() {
  echo "🔄 Deleting environment…"
  rm -rf "$SRC" "$VENVDIR" native_build "$ROOT"/logs
  rm -f test_*.{py,json}
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
  rm -rf native_build "$ROOT"/logs/*
  rm -f test_*.{py,json}
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
