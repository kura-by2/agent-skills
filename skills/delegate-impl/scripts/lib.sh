#!/usr/bin/env bash
# delegate-impl / delegate-sub / delegate-review 各スキルに同梱する実行基盤。
# モデル一覧の取得はリポジトリ直下の scripts/llm-models/ が担い、その候補 TSV 化は
# scripts/llm-models/criteria.sh、Jev の choice 判定は scripts/jev-choice.sh、指示本文の要約は
# scripts/summarize/script.sh、ファイルの鮮度判定は scripts/file-fresh.sh を共有する。
# フォールバックの保存など、それ以外は各スキル配下だけで完結する。
#
# 役割:
#   - backend 別フォールバック fallback/<backend>.txt（モデル名1行）の生成・保持（backend ごとに24時間）
#   - 委譲ごとの Jev によるモデル判定（本文は送らず要約のみ）
#   - codex / claude（agent 指定）での委譲実行
#
# モデルの候補元は scripts/llm-models/llm-models.json（backend・model・description を持つオブジェクトの
# 配列。claude は比較表の値を comparison オブジェクトでも持つ）。委譲の前に
# scripts/llm-models/script.sh を呼んで最新化する（失敗しても続行し、既存の一覧を使う）。一覧が
# 不在なら Jev の候補が空になり、フォールバックへ倒れる。
# 接続先は api.typesafe.ai に固定する。鍵の値と指示ファイル本文はログ・出力に書かない。

DELEGATE_FALLBACK_MAX_AGE_SECONDS=86400 # フォールバックの鮮度（1日）
DELEGATE_JEV_LAST_ERROR="" # 直近の Jev 判定失敗理由（経路トレース用）
DELEGATE_JEV_LAST_OUTPUT="" # 直近の Jev 判定の出力 "choice<TAB>confidence"

# このファイル（lib.sh）の実体があるディレクトリ。symlink 経由で呼ばれても実体から解決する。
# フォールバックは、このスキルしか読まないので、ここ（自スキル配下・git 追跡外）に置く。
DELEGATE_LIB_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# リポジトリ直下の共通スクリプト群。スキルが symlink 経由で呼ばれても実体から解決する。
DELEGATE_SCRIPTS_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/scripts"
DELEGATE_JEV_CHOICE_SCRIPT="$DELEGATE_SCRIPTS_DIR/jev-choice.sh"
DELEGATE_SUMMARIZE_SCRIPT="$DELEGATE_SCRIPTS_DIR/summarize/script.sh"
DELEGATE_LLM_MODELS_SCRIPT="$DELEGATE_SCRIPTS_DIR/llm-models/script.sh"
DELEGATE_LLM_MODELS_FILE="$DELEGATE_SCRIPTS_DIR/llm-models/llm-models.json"
DELEGATE_CRITERIA_SCRIPT="$DELEGATE_SCRIPTS_DIR/llm-models/criteria.sh"
DELEGATE_FILE_FRESH_SCRIPT="$DELEGATE_SCRIPTS_DIR/file-fresh.sh"
DELEGATE_PROJECT_ROOT_SCRIPT="$DELEGATE_SCRIPTS_DIR/project-root.sh"

delegate_mark_sync_deadline_delegate() {
  local session="${CLAUDE_CODE_SESSION_ID:-}"
  [ -n "$session" ] || return 0
  mkdir -p /tmp/claude-sync-deadline 2>/dev/null || return 0
  : > "/tmp/claude-sync-deadline/$session.delegate" 2>/dev/null || true
}

# この backend のフォールバックファイル（自スキル配下・git 追跡外、中身はモデル名1行）。
delegate_fallback_file() {
  printf '%s/fallback/%s.txt\n' "$DELEGATE_LIB_DIR" "$1"
}

# ファイルが鮮度上限より新しければ 0、古い/不在なら非0。
delegate_is_fresh() {
  "$DELEGATE_FILE_FRESH_SCRIPT" "$1" "$DELEGATE_FALLBACK_MAX_AGE_SECONDS"
}

# 本文の伏せ字化（マスキング）を共通スクリプトに委ねる。マスキングの指示文・要約モデルの選択はスクリプト側が担う。
delegate_summary_llm() {
  "$DELEGATE_SUMMARIZE_SCRIPT" "$1"
}

# マスキング後の本文として妥当か判定する。空のみ不正（非0）。
# 本文は複数行・長文になり、拒否文言の語も普通に現れ得るため、行数・長さ・拒否文での判定はしない。
delegate_summary_ok() {
  local raw="$1"
  [ -n "$raw" ] || return 1
  return 0
}

# summary を state に、criteria（"名前<TAB>説明" の行）を候補にして共通スクリプトに問い合わせる。
# 判定結果 "choice<TAB>confidence" を DELEGATE_JEV_LAST_OUTPUT に、失敗理由を DELEGATE_JEV_LAST_ERROR に入れる。
# コマンド置換で呼ぶと失敗理由がサブシェルに閉じ込められるため、この関数は直接呼び出し、結果は両グローバルから読む。
# 第4引数に最低確信度を渡すと、その未満は low_confidence として失敗扱いになる（省略時は閾値判定なし）。
delegate_jev_choice() {
  local summary="$1" criteria="$2" instructions="$3" min_confidence="${4:-}"
  local out err err_file opts=()
  DELEGATE_JEV_LAST_ERROR=""
  DELEGATE_JEV_LAST_OUTPUT=""
  [ -n "$min_confidence" ] && opts=(--min-confidence "$min_confidence")
  err_file="$(mktemp)" || { DELEGATE_JEV_LAST_ERROR="http_error"; return 1; }
  if out="$(printf '%s' "$criteria" | "$DELEGATE_JEV_CHOICE_SCRIPT" "${opts[@]}" "$summary" "$instructions" 2>"$err_file")"; then
    rm -f "$err_file"
    DELEGATE_JEV_LAST_OUTPUT="$out"
    return 0
  fi
  err="$(cat "$err_file")"
  rm -f "$err_file"
  DELEGATE_JEV_LAST_ERROR="${err:-http_error}"
  return 1
}

delegate_backend_from_model() {
  case "$1" in
    gpt-*) printf 'codex\n' ;;
    claude-*) printf 'claude\n' ;;
    *) return 1 ;;
  esac
}

# このエージェントの定義ファイル（プロジェクトルートの .claude/agents/<agent>.md）。
# impl は codex backend 分も含めこのファイル（impl.md）を使う。プロジェクトルートは共通スクリプトで解決する。
delegate_agent_def_file() {
  local root
  root="$("$DELEGATE_PROJECT_ROOT_SCRIPT")" || return 1
  printf '%s/.claude/agents/%s.md\n' "$root" "$1"
}

# この backend のフォールバックを Jev で再生成する。1問判定してモデル名1行を書く。
# state にはこのスキルのエージェント定義（.claude/agents/<agent>.md）を伏せ字化して渡し、その役割に合うモデルを選ばせる。
# 定義ファイルが無い／伏せ字化に失敗したときはこの backend の再選定失敗とし、Jev がモデルを返さなければ非0を返す（既存ファイルは上書きしない）。
delegate_rebuild_fallback() {
  local agent="$1" backend="$2" fallback_file="$3"
  local criteria def_file state choice conf tmp
  criteria="$("$DELEGATE_CRITERIA_SCRIPT" "$backend")" || criteria=""
  if [ -z "$criteria" ]; then
    printf 'delegate %s fallback-gen: backend=%s source=none reason=none\n' "$agent" "$backend" >&2
    return 1
  fi
  def_file="$(delegate_agent_def_file "$agent")" || def_file=""
  if [ -z "$def_file" ] || [ ! -f "$def_file" ]; then
    printf 'delegate %s fallback-gen: backend=%s source=none reason=agent_def_missing\n' "$agent" "$backend" >&2
    return 1
  fi
  if ! state="$(delegate_summarize_task "$def_file")"; then
    printf 'delegate %s fallback-gen: backend=%s source=none reason=summary_failed\n' "$agent" "$backend" >&2
    return 1
  fi
  if ! delegate_jev_choice "$state" "$criteria" \
    "この backend の既定として最も適したモデルを選ぶ。"; then
    printf 'delegate %s fallback-gen: backend=%s source=none reason=%s\n' \
      "$agent" "$backend" "${DELEGATE_JEV_LAST_ERROR:-none}" >&2
    return 1
  fi
  IFS=$'\t' read -r choice conf <<< "$DELEGATE_JEV_LAST_OUTPUT"
  if [ -z "$choice" ]; then
    printf 'delegate %s fallback-gen: backend=%s source=none reason=http_error\n' "$agent" "$backend" >&2
    return 1
  fi
  printf 'delegate %s fallback-gen: backend=%s model=%s source=jev confidence=%s\n' \
    "$agent" "$backend" "$choice" "$conf" >&2
  tmp="$(mktemp)"
  printf '%s\n' "$choice" > "$tmp"
  mv "$tmp" "$fallback_file"
}

# 委譲前処理: モデル一覧（llm-models）を最新化（失敗しても続行）し、候補 backend ごとに、その backend の
# フォールバックが 24時間以上古い（または不在）のときだけ Jev で作り直す。鮮度判定・作り直し・失敗時の
# 前回値維持は backend ごとに完結する。作り直しに失敗した backend は前回値をそのまま使う。
# どの backend にも値が無いときだけ非0で終了し、継続方法を案内する。
delegate_ensure_tiers_and_fallback() {
  local agent="$1"; shift
  local fb_backends=("$@")
  local backend fallback_file available=0

  # モデル一覧を最新化する。失敗しても続行し、既存の一覧（あれば）を使う。
  "$DELEGATE_LLM_MODELS_SCRIPT" >/dev/null 2>&1 || true

  mkdir -p "$DELEGATE_LIB_DIR/fallback" 2>/dev/null || true

  for backend in "${fb_backends[@]}"; do
    fallback_file="$(delegate_fallback_file "$backend")"

    if delegate_is_fresh "$fallback_file"; then
      available=1
      continue
    fi

    if delegate_rebuild_fallback "$agent" "$backend" "$fallback_file"; then
      available=1
      continue
    fi

    if [ -f "$fallback_file" ]; then
      printf 'warning: delegate could not rebuild fallback for %s backend %s via Jev (keeping previous)\n' \
        "$agent" "$backend" >&2
      available=1
      continue
    fi

    printf 'error: delegate %s backend %s cannot determine a fallback model and no previous value exists. Write a model name (1 line, e.g. <model>) into %s to continue.\n' \
      "$agent" "$backend" "$fallback_file" >&2
  done

  [ "$available" -eq 1 ]
}

# 指示ファイル本文を保存済みの要約モデルでマスキングする。構成・作業内容・範囲・条件は残し、
# 機密情報・固有名詞・パス・URL・識別子・コード・インシデント情報だけを汎用の伏せ字に置き換える。
# 要約・圧縮はしない。失敗・空は非0。
delegate_summarize_task() {
  local task_path="$1" raw
  [ -f "$task_path" ] || return 1
  [ "${DELEGATE_SKIP_LLM:-}" != "1" ] || return 1
  raw="$(delegate_summary_llm "$(cat "$task_path")")" || return 1
  delegate_summary_ok "$raw" || return 1
  printf '%s\n' "$raw"
}

# この backend のフォールバックファイル（モデル名1行）を読み、"backend<TAB>model" を返す。
# ファイルが無い／空のときは非0。
delegate_fallback_model() {
  local agent="$1" backend="$2"
  local fallback_file model
  fallback_file="$(delegate_fallback_file "$backend")"
  [ -f "$fallback_file" ] || return 1
  IFS= read -r model < "$fallback_file" || model=""
  [ -n "$model" ] || return 1
  printf '%s\t%s\n' "$backend" "$model"
}

# agent 用に使用モデルを決める。標準出力 "backend<TAB>model"。
# 委譲ごとに Jev（マスキング→choice、閾値 0.5）で選び、鍵なし・失敗・低確信度・マスキング失敗は fallback へ倒す。
delegate_resolve_model() {
  local agent="$1" task_path="$2"; shift 2
  local backends=("$@")
  local tiers_file summary criteria out choice conf backend reason="none" fb fb_model
  tiers_file="$DELEGATE_LLM_MODELS_FILE"

  if [ ! -f "$tiers_file" ]; then
    reason="none"
  elif [ -z "${JEV_API_KEY:-}" ]; then
    reason="no_key"
  elif ! summary="$(delegate_summarize_task "$task_path")"; then
    reason="summary_failed"
  else
    criteria="$("$DELEGATE_CRITERIA_SCRIPT" "${backends[@]}")" || criteria=""
    if [ -z "$criteria" ]; then
      reason="none"
    elif ! delegate_jev_choice "$summary" "$criteria" "この作業にマッチした品質を担保できる、一番コストが低いモデルはどれ？" 0.5; then
      reason="${DELEGATE_JEV_LAST_ERROR:-http_error}"
    else
      IFS=$'\t' read -r choice conf <<< "$DELEGATE_JEV_LAST_OUTPUT"
      if ! backend="$(delegate_backend_from_model "$choice")"; then
        reason="http_error"
      else
        printf 'delegate %s: model=%s source=jev confidence=%s\n' "$agent" "$choice" "$conf" >&2
        printf '%s\t%s\n' "$backend" "$choice"
        return 0
      fi
    fi
  fi

  # fallback は候補 backend の順に最初に値があるものを使う。
  fb=""
  for backend in "${backends[@]}"; do
    if fb="$(delegate_fallback_model "$agent" "$backend")"; then
      break
    fi
    fb=""
  done
  fb_model="$(printf '%s' "$fb" | cut -f2)"
  printf 'delegate %s: model=%s source=fallback reason=%s\n' "$agent" "${fb_model:-none}" "$reason" >&2
  [ -n "$fb" ] || return 1
  printf '%s\n' "$fb"
}

# selected_context_file（1行1パス）から CONTEXT_PROMPT と ADD_DIRS を名前渡しで埋める。
delegate_build_context() {
  local selected_file="$1"
  local -n _ctx="$2"
  local -n _dirs="$3"
  _ctx=""
  local body="" path
  [ -n "$selected_file" ] && [ -f "$selected_file" ] || return 0
  while IFS= read -r path || [ -n "$path" ]; do
    path="$(printf '%s' "$path" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$path" ] || continue
    case "$path" in \#*) continue ;; esac
    if [ ! -f "$path" ] || [[ "${path,,}" != *.md && "${path,,}" != *.markdown ]]; then
      printf 'warning: selected delegate context is not a Markdown file: %s\n' "$path" >&2
      continue
    fi
    body+=$'\n- '"$path"
    _dirs+=("$(dirname "$path")")
  done < "$selected_file"
  if [ -n "$body" ]; then
    _ctx=$'\n現在のタスクに適用する追加資料は次のとおりです。これらだけを読んでルールを適用し、最終報告に「適用した追加資料」としてファイルパスを明記してください。'"$body"
  fi
}

# codex で委譲を実行する。追加 add-dir 対象は末尾の引数で渡す。
delegate_run_codex() {
  local worktree="$1" task_path="$2" model="$3" context_prompt="$4"; shift 4
  local add_dirs=("$@")
  local args=(exec -C "$worktree" --model "$model") d
  for d in "${add_dirs[@]+"${add_dirs[@]}"}"; do
    args+=(--add-dir "$d")
  done
  args+=(--dangerously-bypass-approvals-and-sandbox "${task_path} を読んで対応してください。${context_prompt}")
  if [ "${DELEGATE_SKIP_EXEC:-}" = "1" ]; then
    printf 'delegate: skipped codex exec because DELEGATE_SKIP_EXEC=1\n' >&2
    return 0
  fi
  codex "${args[@]}" < /dev/null
}

# claude で委譲を実行する（agent 指定）。cwd は変えず worktree は --add-dir で渡す。
delegate_run_claude() {
  local agent="$1" worktree="$2" task_path="$3" model="$4" context_prompt="$5"; shift 5
  local add_dirs=("$@")
  local prompt="作業対象のリポジトリは ${worktree} です。${task_path} を読んで対応してください。ファイルの作成・編集・削除は ${worktree}（および渡された inputs）内に限定すること。読み取り専用の参照やコマンド実行は、システム情報など ${worktree} 外を対象にしても禁止しない。自分の権限範囲外の作業を求められたら固定文言 DELEGATE_PERMISSION_OUT_OF_SCOPE だけを出して終了すること。${context_prompt}"
  local args=(-p "$prompt" --agent "$agent" --model "$model") d
  for d in "${add_dirs[@]+"${add_dirs[@]}"}"; do
    args+=(--add-dir "$d")
  done
  args+=(--dangerously-skip-permissions)
  if [ "${DELEGATE_SKIP_EXEC:-}" = "1" ]; then
    printf 'delegate: skipped claude exec because DELEGATE_SKIP_EXEC=1\n' >&2
    return 0
  fi
  CLAUDE_DELEGATE_SESSION=1 claude "${args[@]}" < /dev/null
}
