#!/bin/zsh

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Open Island smoke runs only on macOS." >&2
    exit 1
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

timestamp="$(date +%Y%m%d-%H%M%S)"
artifact_dir="${OPEN_ISLAND_HARNESS_ARTIFACT_DIR:-$repo_root/output/harness/smoke-$timestamp}"

export OPEN_ISLAND_HARNESS_SCENARIO="${OPEN_ISLAND_HARNESS_SCENARIO:-approvalCard}"
export OPEN_ISLAND_HARNESS_PRESENT_OVERLAY="${OPEN_ISLAND_HARNESS_PRESENT_OVERLAY:-1}"
export OPEN_ISLAND_HARNESS_START_BRIDGE="${OPEN_ISLAND_HARNESS_START_BRIDGE:-0}"
export OPEN_ISLAND_HARNESS_BOOT_ANIMATION="${OPEN_ISLAND_HARNESS_BOOT_ANIMATION:-0}"
export OPEN_ISLAND_HARNESS_SHOW_ONLY_FOR_NOTIFICATIONS="${OPEN_ISLAND_HARNESS_SHOW_ONLY_FOR_NOTIFICATIONS:-0}"
export OPEN_ISLAND_HARNESS_EXERCISE_HIDDEN_HOVER="${OPEN_ISLAND_HARNESS_EXERCISE_HIDDEN_HOVER:-0}"
export OPEN_ISLAND_HARNESS_CAPTURE_DELAY_SECONDS="${OPEN_ISLAND_HARNESS_CAPTURE_DELAY_SECONDS:-1}"
export OPEN_ISLAND_HARNESS_AUTO_EXIT_SECONDS="${OPEN_ISLAND_HARNESS_AUTO_EXIT_SECONDS:-2}"
export OPEN_ISLAND_HARNESS_ARTIFACT_DIR="$artifact_dir"

mkdir -p "$artifact_dir"

case "${OPEN_ISLAND_HARNESS_START_BRIDGE:l}" in
    1|true|yes|on)
        export OPEN_ISLAND_SOCKET_PATH="${OPEN_ISLAND_SOCKET_PATH:-$artifact_dir/bridge.sock}"
        ;;
esac

echo "Launching OpenIslandApp smoke scenario '${OPEN_ISLAND_HARNESS_SCENARIO}' for ${OPEN_ISLAND_HARNESS_AUTO_EXIT_SECONDS}s"
swift run OpenIslandApp

report_path="$artifact_dir/report.json"
if [[ ! -f "$report_path" ]]; then
    echo "Smoke failed: missing harness report at $report_path" >&2
    exit 1
fi

png_count="$(find "$artifact_dir" -maxdepth 1 -name '*.png' | wc -l | tr -d ' ')"
expects_hidden_overlay=0
exercises_hidden_hover=0
case "${OPEN_ISLAND_HARNESS_EXERCISE_HIDDEN_HOVER:l}" in
    1|true|yes|on)
        exercises_hidden_hover=1
        ;;
esac
case "${OPEN_ISLAND_HARNESS_SHOW_ONLY_FOR_NOTIFICATIONS:l}" in
    1|true|yes|on)
        if [[ "$OPEN_ISLAND_HARNESS_SCENARIO" == "closed" && "$exercises_hidden_hover" -eq 0 ]]; then
            expects_hidden_overlay=1
        fi
        ;;
esac

if [[ "$expects_hidden_overlay" -eq 0 && "$png_count" -eq 0 ]]; then
    echo "Smoke failed: no PNG artifacts captured in $artifact_dir" >&2
    exit 1
fi
if [[ "$expects_hidden_overlay" -eq 1 && "$png_count" -ne 0 ]]; then
    echo "Smoke failed: hidden overlay unexpectedly produced PNG artifacts in $artifact_dir" >&2
    exit 1
fi

ax_count="$(find "$artifact_dir" -maxdepth 1 -name '*.ax.json' | wc -l | tr -d ' ')"
if [[ "$expects_hidden_overlay" -eq 0 && "$ax_count" -eq 0 ]]; then
    echo "Smoke failed: no accessibility artifacts captured in $artifact_dir" >&2
    exit 1
fi
if [[ "$expects_hidden_overlay" -eq 1 && "$ax_count" -ne 0 ]]; then
    echo "Smoke failed: hidden overlay unexpectedly produced accessibility artifacts in $artifact_dir" >&2
    exit 1
fi

python3 - "$report_path" <<'PY'
import subprocess
import sys

subprocess.run(
    [sys.executable, "scripts/validate-harness-artifacts.py", sys.argv[1]],
    check=True,
)
PY

echo "Artifacts written to $artifact_dir"
echo "OpenIslandApp smoke passed"
