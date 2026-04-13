#!/usr/bin/env bash
set -euo pipefail

remote_name="${1:-}"
remote_url="${2:-}"
branch="${3:-}"
initial_sha="${4:-}"

if [[ -z "$remote_name" || -z "$remote_url" || -z "$branch" || -z "$initial_sha" ]]; then
  echo "usage: $0 <remote-name> <remote-url> <branch> <sha>" >&2
  exit 1
fi

repo_root="$(git rev-parse --show-toplevel)"
state_dir="$repo_root/.git/codex-post-push"
mkdir -p "$state_dir"

safe_branch="${branch//\//__}"
lock_file="$state_dir/${safe_branch}.lock"
summary_file="$state_dir/${safe_branch}.summary.log"
prompt_file="$state_dir/${safe_branch}.prompt.txt"
failed_log_file="$state_dir/${safe_branch}.failed.log"
codex_output_file="$state_dir/${safe_branch}.codex.out"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$summary_file"
}

cleanup() {
  rm -f "$lock_file"
}

if [[ -f "$lock_file" ]]; then
  existing_pid="$(cat "$lock_file" 2>/dev/null || true)"
  if [[ "$existing_pid" =~ ^[0-9]+$ ]] && kill -0 "$existing_pid" 2>/dev/null; then
    log "Watcher already running for branch '$branch' (pid=$existing_pid), skip."
    exit 0
  fi
fi

echo "$$" >"$lock_file"
trap cleanup EXIT

extract_repo_full_name() {
  python3 - "$1" <<'PY'
import re
import sys

url = sys.argv[1]
patterns = [
    r"^git@github\.com:(?P<repo>[^/]+/[^/]+?)(?:\.git)?$",
    r"^https://github\.com/(?P<repo>[^/]+/[^/]+?)(?:\.git)?/?$",
    r"^ssh://git@github\.com/(?P<repo>[^/]+/[^/]+?)(?:\.git)?/?$",
]
for pattern in patterns:
    match = re.match(pattern, url)
    if match:
        print(match.group("repo"))
        raise SystemExit(0)
raise SystemExit(1)
PY
}

repo_full_name="$(extract_repo_full_name "$remote_url" || true)"
if [[ -z "$repo_full_name" ]]; then
  log "Remote '$remote_name' is not a supported GitHub remote: $remote_url"
  exit 0
fi

fetch_runs_json() {
  local sha="$1"
  gh run list \
    --repo "$repo_full_name" \
    --branch "$branch" \
    --commit "$sha" \
    --event push \
    --limit 20 \
    --json databaseId,displayTitle,status,conclusion,headSha,url,workflowName,createdAt,updatedAt
}

count_runs() {
  python3 - <<'PY'
import json
import sys
data = json.load(sys.stdin)
print(len(data))
PY
}

count_incomplete_runs() {
  python3 - <<'PY'
import json
import sys
data = json.load(sys.stdin)
print(sum(1 for item in data if item.get("status") != "completed"))
PY
}

list_failed_run_ids() {
  python3 - <<'PY'
import json
import sys

bad = {"failure", "cancelled", "timed_out", "action_required", "startup_failure", "stale"}
for item in json.load(sys.stdin):
    if item.get("status") == "completed" and item.get("conclusion") in bad:
        print(item["databaseId"])
PY
}

summarize_runs() {
  python3 - <<'PY'
import json
import sys

for item in json.load(sys.stdin):
    print(
        f"- {item.get('workflowName') or item.get('displayTitle')}: "
        f"status={item.get('status')} conclusion={item.get('conclusion')} "
        f"url={item.get('url')}"
    )
PY
}

wait_for_runs_to_appear() {
  local sha="$1"
  local attempts="${2:-30}"
  local sleep_seconds="${3:-10}"
  local json="[]"

  for ((i = 1; i <= attempts; i += 1)); do
    json="$(fetch_runs_json "$sha" || echo '[]')"
    if [[ "$(printf '%s' "$json" | count_runs)" -gt 0 ]]; then
      printf '%s' "$json"
      return 0
    fi
    sleep "$sleep_seconds"
  done

  printf '%s' "$json"
  return 1
}

wait_for_runs_to_finish() {
  local sha="$1"
  local attempts="${2:-120}"
  local sleep_seconds="${3:-15}"
  local json="[]"

  for ((i = 1; i <= attempts; i += 1)); do
    json="$(fetch_runs_json "$sha" || echo '[]')"
    if [[ "$(printf '%s' "$json" | count_incomplete_runs)" -eq 0 ]]; then
      printf '%s' "$json"
      return 0
    fi
    sleep "$sleep_seconds"
  done

  printf '%s' "$json"
  return 1
}

collect_failed_logs() {
  local run_ids=("$@")
  : >"$failed_log_file"

  for run_id in "${run_ids[@]}"; do
    {
      echo "===== Failed run: $run_id ====="
      gh run view "$run_id" --repo "$repo_full_name" --log-failed || \
        gh run view "$run_id" --repo "$repo_full_name"
      echo
    } >>"$failed_log_file" 2>&1
  done
}

run_codex_autofix() {
  local sha="$1"
  local attempt="$2"
  local run_summary="$3"

  cat >"$prompt_file" <<EOF
You are running from a local git post-push CI autofix hook.

Repository path: $repo_root
GitHub repo: $repo_full_name
Remote name: $remote_name
Branch: $branch
Target commit SHA: $sha
Autofix attempt: $attempt

Your task:
1. Inspect the GitHub Actions failures for this exact branch and commit.
2. Fix only actionable issues in this repository that caused the failing runs.
3. Re-run the most relevant local checks when feasible.
4. If you make changes, commit them with a clear message and push back to:
   git push $remote_name HEAD:$branch
5. If there is nothing actionable to fix, explain why and stop without unrelated edits.

Important constraints:
- Stay on branch $branch.
- Keep changes minimal and targeted to the CI failure.
- Do not rewrite history.
- If you push a fix, assume another CI cycle will start for the new HEAD.

Failed workflow summary:
$run_summary

Detailed failed logs are attached below in a <failed_logs> block.

<failed_logs>
$(cat "$failed_log_file")
</failed_logs>
EOF

  log "Launching Codex autofix attempt $attempt for $sha"
  codex exec \
    --dangerously-bypass-approvals-and-sandbox \
    -C "$repo_root" \
    -o "$codex_output_file" \
    - <"$prompt_file"
}

max_attempts="${CODEX_POST_PUSH_MAX_ATTEMPTS:-3}"
current_sha="$initial_sha"
attempt=1

log "Watching GitHub Actions for $repo_full_name branch '$branch' at $current_sha"

while (( attempt <= max_attempts )); do
  runs_json="$(wait_for_runs_to_appear "$current_sha")" || {
    log "No GitHub Actions runs appeared for $current_sha; stop."
    exit 0
  }

  log "Detected workflow runs for $current_sha"
  final_runs_json="$(wait_for_runs_to_finish "$current_sha")"
  log "Completed workflow summary for $current_sha:"
  printf '%s' "$final_runs_json" | summarize_runs | tee -a "$summary_file"

  mapfile -t failed_run_ids < <(printf '%s' "$final_runs_json" | list_failed_run_ids)

  if [[ "${#failed_run_ids[@]}" -eq 0 ]]; then
    log "All Actions passed for $current_sha"
    exit 0
  fi

  if (( attempt == max_attempts )); then
    log "Reached max autofix attempts ($max_attempts). Failing runs remain: ${failed_run_ids[*]}"
    exit 1
  fi

  collect_failed_logs "${failed_run_ids[@]}"
  run_summary="$(printf '%s' "$final_runs_json" | summarize_runs)"
  before_head="$(git rev-parse HEAD)"
  run_codex_autofix "$current_sha" "$attempt" "$run_summary" || {
    log "Codex autofix attempt $attempt failed to execute."
    exit 1
  }

  after_head="$(git rev-parse HEAD)"
  if [[ "$after_head" == "$before_head" ]]; then
    log "Codex did not create a new commit on attempt $attempt; stop."
    exit 1
  fi

  current_sha="$after_head"
  attempt=$((attempt + 1))
  log "Codex pushed a new commit $current_sha; watching the next CI cycle."
done

log "Autofix loop exited unexpectedly."
exit 1
