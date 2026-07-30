#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

timestamp="$(date +%Y%m%d-%H%M%S)"
base_dir="${OPEN_ISLAND_HARNESS_ARTIFACT_DIR:-$repo_root/output/harness/smoke-all-$timestamp}"
scenarios=(closed sessionList approvalCard questionCard completionCard longCompletionCard)

mkdir -p "$base_dir"

for scenario in "${scenarios[@]}"; do
    scenario_dir="$base_dir/$scenario"
    echo "Running smoke scenario '$scenario'"
    OPEN_ISLAND_HARNESS_SCENARIO="$scenario" \
    OPEN_ISLAND_HARNESS_ARTIFACT_DIR="$scenario_dir" \
    zsh "$repo_root/scripts/smoke-dev-app.sh"
done

hidden_scenario_dir="$base_dir/notificationOnlyHidden"
echo "Running smoke scenario 'notificationOnlyHidden'"
OPEN_ISLAND_HARNESS_SCENARIO="closed" \
OPEN_ISLAND_HARNESS_SHOW_ONLY_FOR_NOTIFICATIONS="1" \
OPEN_ISLAND_HARNESS_ARTIFACT_DIR="$hidden_scenario_dir" \
zsh "$repo_root/scripts/smoke-dev-app.sh"

hover_scenario_dir="$base_dir/notificationOnlyHover"
echo "Running smoke scenario 'notificationOnlyHover'"
OPEN_ISLAND_HARNESS_SCENARIO="closed" \
OPEN_ISLAND_HARNESS_SHOW_ONLY_FOR_NOTIFICATIONS="1" \
OPEN_ISLAND_HARNESS_EXERCISE_HIDDEN_HOVER="1" \
OPEN_ISLAND_HARNESS_CAPTURE_DELAY_SECONDS="2.75" \
OPEN_ISLAND_HARNESS_AUTO_EXIT_SECONDS="3.5" \
OPEN_ISLAND_HARNESS_ARTIFACT_DIR="$hover_scenario_dir" \
zsh "$repo_root/scripts/smoke-dev-app.sh"

for scenario in approvalCard completionCard; do
    notification_scenario_dir="$base_dir/notificationOnly${scenario[1,1]:u}${scenario[2,-1]}"
    echo "Running smoke scenario 'notificationOnly${scenario[1,1]:u}${scenario[2,-1]}'"
    OPEN_ISLAND_HARNESS_SCENARIO="$scenario" \
    OPEN_ISLAND_HARNESS_SHOW_ONLY_FOR_NOTIFICATIONS="1" \
    OPEN_ISLAND_HARNESS_ARTIFACT_DIR="$notification_scenario_dir" \
    zsh "$repo_root/scripts/smoke-dev-app.sh"
done

echo "All smoke scenarios passed"
echo "Artifacts written to $base_dir"
