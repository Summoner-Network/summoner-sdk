#!/usr/bin/env bash
# get_agent — download a single agents/agent_<Name> folder from summoner-agents
# Usage:
#   bash get_agent SendAgent_0
# Options:
#   -f, --force     overwrite if target exists
#   -b, --branch    branch or ref (default: main)
#   -r, --repo      owner/repo (default: Summoner-Network/summoner-agents)
#   -l, --list      list available agents on the branch, then exit

# set -euo pipefail

REPO="${REPO:-Summoner-Network/summoner-agents}"
BRANCH="${BRANCH:-main}"
OUT_ROOT="${OUT_ROOT:-agents}"
FORCE=0
LIST_ONLY=0

usage() {
  echo "Usage: bash get_agent <NameLike SendAgent_0> [--force] [--branch <ref>] [--repo <owner/repo>] [--list]"
}

if [[ $# -eq 0 ]]; then usage; exit 1; fi

# Parse flags / args
AGENT_IN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--force) FORCE=1; shift ;;
    -b|--branch) BRANCH="$2"; shift 2 ;;
    -r|--repo) REPO="$2"; shift 2 ;;
    -l|--list) LIST_ONLY=1; shift ;;
    -* ) echo "Unknown option: $1"; usage; exit 1 ;;
    * ) AGENT_IN="${AGENT_IN:-$1}"; shift ;;
  esac
done

# Normalize the agent dir name
if [[ -n "${AGENT_IN}" ]]; then
  if [[ "$AGENT_IN" == agent_* ]]; then
    AGENT_DIR="$AGENT_IN"
  else
    AGENT_DIR="agent_${AGENT_IN}"
  fi
else
  AGENT_DIR=""
fi

# Tools check
command -v tar >/dev/null 2>&1 || { echo "Error: tar is required."; exit 1; }
# Use curl if present, else wget
DL_TOOL=""
if command -v curl >/dev/null 2>&1; then
  DL_TOOL="curl -fsSL"
elif command -v wget >/dev/null 2>&1; then
  DL_TOOL="wget -qO-"
else
  echo "Error: need curl or wget."
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ARCHIVE="$TMP_DIR/repo.tgz"
URL="https://codeload.github.com/${REPO}/tar.gz/refs/heads/${BRANCH}"

echo "Fetching ${REPO}@${BRANCH} tarball…"
if [[ "$DL_TOOL" == curl* ]]; then
  $DL_TOOL "$URL" -o "$ARCHIVE"
else
  $DL_TOOL "$URL" > "$ARCHIVE"
fi

TOPDIR="$(tar -tzf "$ARCHIVE" | head -1 | cut -d/ -f1)"

# Optional: list available agents and exit
if [[ "$LIST_ONLY" -eq 1 ]]; then
  echo "Agents available in ${REPO}@${BRANCH}:"
  tar -tzf "$ARCHIVE" | grep "^${TOPDIR}/agents/agent_" | cut -d/ -f3 | sort -u
  exit 0
fi

if [[ -z "$AGENT_DIR" ]]; then
  echo "Missing agent name."
  usage
  echo
  echo "Tip: use --list to see available agents."
  exit 1
fi

PREFIX="${TOPDIR}/agents/${AGENT_DIR}"

if ! tar -tzf "$ARCHIVE" | grep -q "^${PREFIX}/"; then
  echo "Agent '${AGENT_DIR}' not found under agents/ in ${REPO}@${BRANCH}."
  echo "Available agents:"
  tar -tzf "$ARCHIVE" | grep "^${TOPDIR}/agents/agent_" | cut -d/ -f3 | sort -u
  exit 1
fi

mkdir -p "$OUT_ROOT"
TARGET="${OUT_ROOT}/${AGENT_DIR}"

if [[ -d "$TARGET" ]]; then
  if [[ "$FORCE" -eq 1 ]]; then
    rm -rf "$TARGET"
  else
    echo "Target '${TARGET}' already exists. Use --force to overwrite."
    exit 2
  fi
fi

echo "Extracting ${AGENT_DIR} -> ${TARGET}"
# Extract only that directory, strip top two components: <top>/agents/
tar -xzf "$ARCHIVE" -C "$OUT_ROOT" --strip-components=2 "${PREFIX}"

echo "Done. Created '${TARGET}'."
