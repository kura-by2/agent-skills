#!/bin/bash

delegate_model_cache_skill_dir() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cd "$script_dir/.." && pwd
}

delegate_model_cache_current_week() {
  date '+%G-%V'
}

delegate_model_cache_file_week() {
  local cache_file="$1"
  date -r "$cache_file" '+%G-%V'
}

delegate_model_cache_is_current() {
  local cache_file="$1"

  [ -f "$cache_file" ] || return 1
  [ "$(delegate_model_cache_file_week "$cache_file")" = "$(delegate_model_cache_current_week)" ]
}

delegate_refresh_codex_model_cache() {
  local cache_file="$1"
  local tmp_file="${cache_file}.tmp"
  local raw_file="${cache_file}.raw"
  local cmd="${DELEGATE_CODEX_MODELS_CMD:-codex debug models}"

  if ! command -v jq >/dev/null 2>&1; then
    printf 'error: jq is required to normalize codex model cache\n' >&2
    return 1
  fi

  if ! bash -c "$cmd" > "$raw_file"; then
    rm -f "$raw_file" "$tmp_file"
    printf 'error: failed to refresh codex model cache with official CLI command: %s\n' "$cmd" >&2
    return 1
  fi

  if ! jq -e --arg fetched_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
      {
        backend: "codex",
        fetched_at: $fetched_at,
        source: "codex debug models",
        models: [
          .models[]
          | select(.visibility == "list")
        ]
      }
    ' "$raw_file" > "$tmp_file"; then
    rm -f "$raw_file" "$tmp_file"
    printf 'error: failed to parse codex model catalog\n' >&2
    return 1
  fi

  rm -f "$raw_file"
  mv "$tmp_file" "$cache_file"
}

delegate_refresh_claude_model_cache() {
  local cache_file="$1"
  local tmp_file="${cache_file}.tmp"
  local url="${DELEGATE_CLAUDE_MODELS_URL:-https://platform.claude.com/docs/en/about-claude/models/overview.md}"

  if ! curl -fsSL --max-time "${DELEGATE_CLAUDE_MODELS_TIMEOUT:-20}" "$url" > "$tmp_file"; then
    rm -f "$tmp_file"
    printf 'error: failed to refresh claude model cache from public official docs: %s\n' "$url" >&2
    return 1
  fi

  if [ ! -s "$tmp_file" ]; then
    rm -f "$tmp_file"
    printf 'error: claude model cache refresh returned an empty response: %s\n' "$url" >&2
    return 1
  fi

  mv "$tmp_file" "$cache_file"
}

delegate_refresh_model_cache() {
  local backend="$1"
  local cache_file="$2"

  mkdir -p "$(dirname "$cache_file")"
  case "$backend" in
    codex)
      delegate_refresh_codex_model_cache "$cache_file"
      ;;
    claude)
      delegate_refresh_claude_model_cache "$cache_file"
      ;;
    *)
      printf 'error: unsupported delegate backend for model cache: %s\n' "$backend" >&2
      return 1
      ;;
  esac
}

delegate_model_backend_from_name() {
  local model="$1"

  case "$model" in
    gpt-*)
      printf 'codex\n'
      ;;
    claude-*)
      printf 'claude\n'
      ;;
    *)
      return 1
      ;;
  esac
}

delegate_routing_file() {
  local skill_dir

  skill_dir="$(delegate_model_cache_skill_dir)"
  printf '%s\n' "${DELEGATE_ROUTING_FILE:-$skill_dir/state/routing.tsv}"
}

delegate_model_for_route() {
  local match_field="$1"
  local match_value="$2"
  local routing_file task_type backend agent model line

  routing_file="$(delegate_routing_file)"

  if [ ! -f "$routing_file" ]; then
    printf 'error: delegate routing table is missing: %s\n' "$routing_file" >&2
    return 1
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    IFS=$'\037' read -r task_type backend agent model _ <<< "${line//$'\t'/$'\037'}"
    [ -n "$task_type" ] || continue
    case "$task_type" in
      \#*)
        continue
        ;;
    esac

    case "$match_field" in
      task_type)
        [ "$task_type" = "$match_value" ] || continue
        ;;
      agent)
        [ "$agent" = "$match_value" ] || continue
        ;;
      *)
        printf 'error: unsupported delegate routing match field: %s\n' "$match_field" >&2
        return 1
        ;;
    esac

    if [ -z "$backend" ] || [ -z "$model" ]; then
      printf 'error: delegate routing row is incomplete for %s %s\n' "$match_field" "$match_value" >&2
      return 1
    fi

    printf '%s\n' "$model"
    return 0
  done < "$routing_file"

  printf 'error: no delegate routing row for %s %s\n' "$match_field" "$match_value" >&2
  return 1
}

delegate_model_for_task_type() {
  local task_type="$1"

  delegate_model_for_route task_type "$task_type"
}

delegate_model_for_agent() {
  local agent="$1"

  delegate_model_for_route agent "$agent"
}

delegate_model_cache_file_for_backend() {
  local backend="$1"
  local skill_dir cache_dir

  skill_dir="$(delegate_model_cache_skill_dir)"
  cache_dir="${DELEGATE_MODEL_CACHE_DIR:-$skill_dir/state/.model-cache}"
  printf '%s/%s-models.json\n' "$cache_dir" "$backend"
}

delegate_model_table_for_backend() {
  local backend="$1"
  local order="$2"
  local skill_dir tier_file

  skill_dir="$(delegate_model_cache_skill_dir)"
  tier_file="${DELEGATE_MODEL_TIERS_FILE:-$skill_dir/state/model-tiers.tsv}"

  if [ ! -f "$tier_file" ]; then
    printf 'error: delegate model performance table is missing: %s\n' "$tier_file" >&2
    return 1
  fi

  awk -F '\t' -v backend="$backend" '
    $0 !~ /^#/ && NF >= 3 {
      if ($1 == backend && $3 ~ /^[0-9]+([.][0-9]+)?$/) {
        print $2 "\t" $3 "\t" NR
      }
    }
  ' "$tier_file" |
  if [ "$order" = "asc" ]; then
    sort -t $'\t' -k2,2n -k3,3n
  else
    sort -t $'\t' -k2,2nr -k3,3n
  fi
}

delegate_warn_model_tier_drift() {
  local backend="$1"
  local cache_file="$2"
  local skill_dir tier_file listed_models tier_models

  skill_dir="$(delegate_model_cache_skill_dir)"
  tier_file="${DELEGATE_MODEL_TIERS_FILE:-$skill_dir/state/model-tiers.tsv}"

  if [ ! -f "$tier_file" ]; then
    printf 'warning: delegate model performance table is missing: %s\n' "$tier_file" >&2
    return 0
  fi

  if [ "$backend" = "claude" ]; then
    delegate_model_table_for_backend "$backend" desc | cut -f1 | sort -u |
    while IFS= read -r model || [ -n "$model" ]; do
      [ -n "$model" ] || continue
      if ! grep -Fq "$model" "$cache_file"; then
        printf 'warning: delegate claude model not found in public docs cache: %s\n' "$model" >&2
        continue
      fi
      if grep -Fin -C 2 "$model" "$cache_file" | grep -Eiq 'deprecated|retired'; then
        printf 'warning: delegate claude model has nearby lifecycle warning in public docs cache: %s\n' "$model" >&2
      fi
    done
    return 0
  fi

  listed_models="$(mktemp)"
  tier_models="$(mktemp)"

  if ! jq -r '.models[] | if type == "string" then . else .slug end' "$cache_file" | sort -u > "$listed_models"; then
    printf 'warning: delegate model cache is unreadable for backend %s: %s\n' "$backend" "$cache_file" >&2
    rm -f "$listed_models" "$tier_models"
    return 0
  fi

  delegate_model_table_for_backend "$backend" desc | cut -f1 | sort -u > "$tier_models"

  while IFS= read -r model || [ -n "$model" ]; do
    [ -n "$model" ] || continue
    if ! grep -Fxq "$model" "$listed_models"; then
      printf 'warning: delegate model retirement candidate: %s/%s is in model-tiers.tsv but absent from current cache\n' "$backend" "$model" >&2
    fi
  done < "$tier_models"

  while IFS= read -r model || [ -n "$model" ]; do
    [ -n "$model" ] || continue
    if ! grep -Fxq "$model" "$tier_models"; then
      printf 'warning: delegate model is unclassified: %s/%s appears in current cache but not in model-tiers.tsv\n' "$backend" "$model" >&2
    fi
  done < "$listed_models"

  rm -f "$listed_models" "$tier_models"
}

delegate_report_model_tier_guidance() {
  local backend cache_file skill_dir tier_file listed_models tier_models difference_models
  local catalog_order tier_order backends

  case "${1:-}" in
    "")
      backends="codex claude"
      ;;
    codex|claude)
      backends="$1"
      ;;
    *)
      printf 'error: unsupported delegate backend for model tier guidance: %s\n' "$1" >&2
      return 1
      ;;
  esac

  skill_dir="$(delegate_model_cache_skill_dir)"
  tier_file="${DELEGATE_MODEL_TIERS_FILE:-$skill_dir/state/model-tiers.tsv}"

  if [ ! -f "$tier_file" ]; then
    printf 'error: delegate model performance table is missing: %s\n' "$tier_file" >&2
    return 1
  fi

  for backend in $backends; do
    cache_file="$(delegate_model_cache_file_for_backend "$backend")"
    printf '=== %s model tier guidance ===\n' "$backend"

    if [ ! -f "$cache_file" ]; then
      printf 'catalog: unavailable (cache missing: %s)\n\n' "$cache_file"
      continue
    fi

    listed_models="$(mktemp)"
    tier_models="$(mktemp)"
    difference_models="$(mktemp)"
    delegate_model_table_for_backend "$backend" desc | cut -f1 | sort -u > "$tier_models"

    if [ "$backend" = "codex" ]; then
      if ! jq -r '
          .models[]
          | select(
              type == "string"
              or (.upgrade.retirement_at == null)
              or (((.upgrade.retirement_at | fromdateiso8601?) // 0) > now)
            )
          | if type == "string" then . else .slug end
        ' "$cache_file" | sort -u > "$listed_models"; then
        printf 'catalog: unavailable (cache is unreadable)\n\n'
        rm -f "$listed_models" "$tier_models" "$difference_models"
        continue
      fi

      printf '%s\n' '-- available catalog models --'
      jq -r '
        .models[]
        | select(
            type == "string"
            or (.upgrade.retirement_at == null)
            or (((.upgrade.retirement_at | fromdateiso8601?) // 0) > now)
          )
        | if type == "string" then
            "id: \(.)\n  details: unavailable (legacy cache format)"
          else
            "id: \(.slug)\n"
            + "  display_name: \(.display_name // "unavailable")\n"
            + "  priority: \((.priority // "unavailable") | tostring)\n"
            + "  description: \(.description // "unavailable")\n"
            + "  default_reasoning_level: \(.default_reasoning_level // "unavailable")\n"
            + "  supported_reasoning_levels: \((.supported_reasoning_levels // "unavailable") | if type == "array" then map(if type == "object" then (.effort // .reasoning_level // tostring) else tostring end) | join(", ") else tostring end)\n"
            + "  retirement_at: \(.upgrade.retirement_at // "none")\n"
            + "  migration_target: \(.upgrade.model // .upgrade.target_model // .upgrade.replacement_model // "none")\n"
            + "  migration_message: \(.upgrade.message // "none")"
          end
      ' "$cache_file"
    else
      printf '%s\n' '-- available catalog models --'
      printf 'The official docs cache is unstructured Markdown; a complete model list and catalog metadata cannot be determined reliably.\n'
      printf 'Tier-table models found in the current docs:\n'
      while IFS= read -r model || [ -n "$model" ]; do
        [ -n "$model" ] || continue
        if grep -Fq "$model" "$cache_file"; then
          printf 'id: %s\n  details: unavailable from structured catalog data\n' "$model"
          printf '%s\n' "$model" >> "$listed_models"
        fi
      done < "$tier_models"
    fi

    printf '%s\n' '-- differences from model-tiers.tsv --'
    printf '%s\n' 'Unclassified (catalog only):'
    comm -23 "$listed_models" "$tier_models" > "$difference_models"
    if [ "$backend" = "claude" ]; then
      printf '  unavailable: the Markdown cache cannot provide a complete catalog list\n'
    elif [ -s "$difference_models" ]; then
      sed 's/^/  /' "$difference_models"
    else
      printf '  none\n'
    fi

    printf '%s\n' 'Retirement candidates (tier table only):'
    comm -13 "$listed_models" "$tier_models" > "$difference_models"
    if [ -s "$difference_models" ]; then
      sed 's/^/  /' "$difference_models"
    else
      printf '  none\n'
    fi

    printf '%s\n' 'Order contradictions:'
    if [ "$backend" = "codex" ]; then
      catalog_order="$(jq -r '
        [.models[]
          | select(type == "object" and (.priority | type == "number"))
          | select((.upgrade.retirement_at == null) or (((.upgrade.retirement_at | fromdateiso8601?) // 0) > now))]
        | sort_by(.priority)
        | .[].slug
      ' "$cache_file" | while IFS= read -r model; do grep -Fxq "$model" "$tier_models" && printf '%s\n' "$model"; done)"
      tier_order="$(delegate_model_table_for_backend codex desc | cut -f1 | while IFS= read -r model; do grep -Fxq "$model" "$listed_models" && printf '%s\n' "$model"; done)"
      if [ -z "$catalog_order" ]; then
        printf '  unavailable: catalog priority values are absent\n'
      elif [ "$catalog_order" = "$tier_order" ]; then
        printf '  none\n'
      else
        printf '  catalog priority order: %s\n' "$(printf '%s\n' "$catalog_order" | paste -sd '>' - | sed 's/>/ > /g')"
        printf '  tier performance order: %s\n' "$(printf '%s\n' "$tier_order" | paste -sd '>' - | sed 's/>/ > /g')"
      fi
    else
      printf '  unavailable: the Markdown cache has no structured priority values\n'
    fi

    printf '\n'
    rm -f "$listed_models" "$tier_models" "$difference_models"
  done
}

delegate_model_is_available() {
  local backend="$1"
  local model="$2"
  local cache_file="$3"

  case "$backend" in
    codex)
      jq -e --arg model "$model" '
        any(.models[];
          if type == "string" then
            . == $model
          else
            .slug == $model
            and (
              .upgrade.retirement_at == null
              or (((.upgrade.retirement_at | fromdateiso8601?) // 0) > now)
            )
          end
        )
      ' "$cache_file" >/dev/null 2>&1
      ;;
    claude)
      grep -Fq "$model" "$cache_file"
      ;;
    *)
      return 1
      ;;
  esac
}

delegate_select_model() {
  local backend="$1"
  local selector="$2"
  local cache_file order model

  cache_file="$(delegate_model_cache_file_for_backend "$backend")"
  order="desc"

  case "$selector" in
    high|highest)
      order="desc"
      ;;
    standard|lowest)
      order="asc"
      ;;
    *)
      printf 'error: unsupported delegate model selector: %s\n' "$selector" >&2
      return 1
      ;;
  esac

  if [ ! -f "$cache_file" ]; then
    printf 'error: delegate model cache is missing for backend %s: %s\n' "$backend" "$cache_file" >&2
    return 1
  fi

  while IFS= read -r model || [ -n "$model" ]; do
    [ -n "$model" ] || continue
    if delegate_model_is_available "$backend" "$model" "$cache_file"; then
      printf '%s\n' "$model"
      return 0
    fi
  done < <(delegate_model_table_for_backend "$backend" "$order" | cut -f1)

  printf 'error: no available delegate model for backend %s selector %s\n' "$backend" "$selector" >&2
  return 1
}

delegate_next_available_model() {
  local failed_model="$1"
  local failed_backend backend cache_file model backends

  if ! failed_backend="$(delegate_model_backend_from_name "$failed_model")"; then
    printf 'none\n'
    return 0
  fi

  case "$failed_backend" in
    codex)
      backends="codex claude"
      ;;
    claude)
      backends="claude codex"
      ;;
  esac

  for backend in $backends; do
    cache_file="$(delegate_model_cache_file_for_backend "$backend")"
    [ -f "$cache_file" ] || continue
    while IFS= read -r model || [ -n "$model" ]; do
      [ -n "$model" ] || continue
      [ "$model" != "$failed_model" ] || continue
      if delegate_model_is_available "$backend" "$model" "$cache_file"; then
        printf '%s\n' "$model"
        return 0
      fi
    done < <(delegate_model_table_for_backend "$backend" desc | cut -f1)
  done

  printf 'none\n'
}

delegate_maybe_emit_fallback_suggest() {
  local failed_model="$1"
  local output_file="$2"
  local rc="$3"
  local next_model

  if [ "$rc" -eq 0 ]; then
    return 0
  fi

  if grep -Fq 'DELEGATE_PERMISSION_OUT_OF_SCOPE' "$output_file"; then
    return 0
  fi

  next_model="$(delegate_next_available_model "$failed_model")"
  printf 'DELEGATE_FALLBACK_SUGGEST\tfailed=%s\tnext=%s\treason=exec_failed\n' "$failed_model" "$next_model" >&2
}

delegate_ensure_model_cache() {
  local backend="$1"
  local skill_dir cache_dir cache_file

  skill_dir="$(delegate_model_cache_skill_dir)"
  cache_dir="${DELEGATE_MODEL_CACHE_DIR:-$skill_dir/state/.model-cache}"
  cache_file="$cache_dir/${backend}-models.json"

  if delegate_model_cache_is_current "$cache_file"; then
    return 0
  fi

  if ! delegate_refresh_model_cache "$backend" "$cache_file"; then
    if [ -f "$cache_file" ]; then
      printf 'warning: delegate backend %s model cache refresh failed; continuing with stale cache from %s\n' \
        "$backend" "$(date -r "$cache_file" '+%Y-%m-%d')" >&2
      delegate_warn_model_tier_drift "$backend" "$cache_file"
      return 0
    fi
    printf 'error: delegate backend %s cannot run because model cache refresh failed and no cache exists\n' "$backend" >&2
    return 1
  fi

  delegate_warn_model_tier_drift "$backend" "$cache_file"
}
