#!/usr/bin/env bash
# Backend-neutral review instruction generation.

delegate_review_diff_exec() {
  local runner="$1"
  shift
  local worktree="${1:-}"
  local inputs_dir="/tmp/delegate-inputs"

  if [ -z "$worktree" ]; then
    return 2
  fi
  shift

  if [ "$#" -ge 2 ] && [ "${!#}" != "--inputs-dir" ]; then
    local prev_index=$(($# - 1))
    if [ "${!prev_index}" = "--inputs-dir" ]; then
      inputs_dir="${!#}"
      set -- "${@:1:$(($# - 2))}"
    fi
  fi
  if [ "$#" -eq 3 ] && [ ! -f "$3" ]; then
    inputs_dir="$3"
    set -- "$1" "$2"
  fi
  if [ "$#" -eq 1 ]; then
    set -- "$1" HEAD
  elif [ "$#" -eq 0 ] || [ $(($# % 2)) -ne 0 ]; then
    printf 'error: goal and diff range must be specified in pairs\n' >&2
    return 1
  fi
  if [ ! -d "$worktree" ]; then
    printf 'error: worktree is not a directory: %s\n' "$worktree" >&2
    return 1
  fi
  local index
  for ((index = 1; index <= $#; index += 2)); do
    if [ ! -f "${!index}" ]; then
      printf 'error: goal file is not readable: %s\n' "${!index}" >&2
      return 1
    fi
  done

  mkdir -p "$inputs_dir"
  local task_file task_name diff_index
  task_file="$(mktemp "$inputs_dir/review-XXXXXX.md")"
  task_name="$(basename "$task_file")"
  printf '# Review指示ファイル\n\n## reviews\n' > "$task_file"
  for ((index = 1; index <= $#; index += 2)); do
    diff_index=$((index + 1))
    printf 'goal: %s\ntarget: %s %s\n' "${!index}" "$worktree" "${!diff_index}" >> "$task_file"
  done
  printf '\n## note\nレビュー対象は各 target の diff 範囲に限ります。\n差分を解釈するために必要ならファイル全文を読んで構いませんが、差分に含まれない既存コードへの指摘はしないでください。\n' >> "$task_file"
  exec bash "$runner" "$worktree" "$task_name" "$inputs_dir"
}

delegate_review_files_exec() {
  local runner="$1"
  shift
  local diff_range=""
  local positional=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --range)
        if [ -z "${2:-}" ]; then
          printf 'error: --range requires a diff range\n' >&2
          return 1
        fi
        diff_range="$2"
        shift 2
        ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  set -- ${positional+"${positional[@]}"}
  local worktree="${1:-}" goal_file="${2:-}" files="${3:-}" inputs_dir="${4:-/tmp/delegate-inputs}"
  if [ -z "$worktree" ] || [ -z "$goal_file" ] || [ -z "$files" ]; then
    return 2
  fi
  if [ ! -d "$worktree" ]; then
    printf 'error: worktree is not a directory: %s\n' "$worktree" >&2
    return 1
  fi
  if [ ! -f "$goal_file" ]; then
    printf 'error: goal file is not readable: %s\n' "$goal_file" >&2
    return 1
  fi
  local file file_path file_lines=""
  for file in $files; do
    if [[ "$file" = /* ]]; then file_path="$file"; else file_path="$worktree/$file"; fi
    if [ ! -f "$file_path" ]; then
      printf 'error: file not found: %s\n' "$file" >&2
      return 1
    fi
    file_lines+="${file_path}"$'\n'
  done

  mkdir -p "$inputs_dir"
  local task_file task_name
  task_file="$(mktemp "$inputs_dir/review-XXXXXX.md")"
  task_name="$(basename "$task_file")"
  printf '# Review指示ファイル\n\n## goal\ngoal: %s\n\n## files\nfiles:\n%s' "$goal_file" "$file_lines" > "$task_file"
  if [ -n "$diff_range" ]; then
    printf '## range\nrange: %s\n\n## note\ngit 管理下のファイルは、レビュー対象を上記 range の差分に限ります。`git -C %s diff %s -- <file>` で変更内容を確認してください。\nファイル全文は差分を解釈するための文脈としてのみ読み、差分に含まれない既存コードへの指摘はしないでください。\ngit 管理外・新規作成のファイルは差分に出ないため、全文をレビュー対象とします。\n' "$diff_range" "$worktree" "$diff_range" >> "$task_file"
  else
    printf '## note\n対象は差分ではなく成果物のファイル全文です。\ngit 管理外・新規作成のファイルを含む前提のため、差分は取らず、上記ファイルの全文を読んでレビューしてください。\n' >> "$task_file"
  fi
  exec bash "$runner" "$worktree" "$task_name" "$inputs_dir"
}
