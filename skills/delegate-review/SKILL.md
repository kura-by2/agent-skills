---
name: delegate-review
description: >
  ゴールアライメントレビューを委譲先（claude の review エージェント）に非同期で実行させるスキル。
  `/delegate-review` から実行スクリプトを呼ぶ。書き込みを伴わないレビューを委譲する。
---

# delegate-review

ゴール定義に対して変更内容が目的を達成しているかを照合させる。レビュー自体はせず、作業場所・ゴール・レビュー対象を指定して非同期に実行させる。委譲先コマンドは常に `run_in_background: true` で Bash を呼んで起動し、呼び出し側は投入後すぐ sync 点に戻る。

## 委譲のスコープ

review エージェントは書き込み不可。修正・改善の実装はさせない。「目的が達成されているか」「アピールが維持されているか」だけを判定させる。コード編集を伴わない委譲のため、`DELEGATE_CHANGED_FILE` の受け渡しは対象外。

## 使い方

実行スクリプトを直接呼ぶ。diff 範囲指定は `claude-review-exec.sh`、ファイル指定は `claude-review-files-exec.sh`。

## モデルの決め方

- **モデル一覧（`scripts/llm-models/llm-models.json`）**: backend・model・description を持つオブジェクトの配列（claude は比較表の値を comparison オブジェクトでも持つ）。委譲の前に `scripts/llm-models/script.sh` を呼んで最新化する（失敗しても続行し、既存の一覧を使う）。一覧が不在なら Jev の候補が空になり、フォールバックへ倒れる。
- **フォールバック（自スキル配下の `scripts/fallback/claude.txt`・git 追跡外）**: 中身はモデル名1行。鮮度判定（24時間）・Jev の choice での作り直し・失敗時の前回値維持は backend ごとに完結する（review は claude のみ）。24時間以上古い（または不在）のときだけ Jev の choice で作り直す。作り直しに失敗したら前回値をそのまま使い、値が無ければ fail-closed（どのファイルに何を書けば続行できるかを stderr に出す）。
- **委譲ごとの判定**: 生成した指示ファイル本文を、要約用の共通スクリプトが選んだ要約モデルでマスキング（構成・作業内容・範囲・条件は残し、機密情報・固有名詞・パス・URL・識別子・コード・インシデント情報だけを伏せ字に置き換え、要約・圧縮はしない）し、そのマスキング済み本文を Jev に送って llm-models の中から使うモデルを choice で判定する。候補は claude のみ。確信度 0.5 以下・鍵なし・HTTP 失敗・3秒超過・マスキング失敗のときは `fallback/claude.txt` を使う。
- 指示ファイルの原文は Jev に送らない（マスキング済み本文のみ）。接続先は `api.typesafe.ai` に固定し、鍵の値と原文はログ・出力に書かない。

## バックエンド

`claude-review-exec.sh` / `claude-review-files-exec.sh` は指示ファイルを生成し、`lib.sh` の委譲処理（モデル解決・claude 起動）を直接呼んで claude（`claude -p --agent review --model <model>`）を起動する。cwd は変えず、作業対象 worktree・inputs ディレクトリを `--add-dir` で渡す。review エージェントは Edit/Write/MultiEdit を禁止する。

## 実行コマンド

実行スクリプトは、スキル起動時に示されるベースディレクトリ（"Base directory for this skill: ..."）を使って実行する。指示ファイルは呼び出し元が指定した inputs ディレクトリに生成する（未指定時は `/tmp/delegate-inputs/`）。

goal ファイルの作成は `scripts/write-input.sh <task_name> [inputs_dir]`（本文は stdin）を使う。汎用 Write/cat は sync 締切フックで止まるが、この専用ラッパは「委譲の下準備」として明示許可される。review の goal は自由記述のため必須セクション検査は課さない。作成先ディレクトリは呼び出し元が指定でき、未指定時は `/tmp/delegate-inputs/` に作成する。作成した goal ファイルを `claude-review-exec.sh` / `claude-review-files-exec.sh` の `<goal_file>` に渡す。

```bash
INPUTS_DIR=/tmp/delegate-inputs
bash {BASE_DIR}/scripts/write-input.sh <goal_task> "$INPUTS_DIR" <<'EOF'
<goal 本文>
EOF
```

```bash
INPUTS_DIR=/tmp/delegate-inputs
mkdir -p "$INPUTS_DIR"
bash {BASE_DIR}/scripts/claude-review-exec.sh <worktree> <goal1> <diff1> [<goal2> <diff2> ...] --inputs-dir "$INPUTS_DIR"
bash {BASE_DIR}/scripts/claude-review-files-exec.sh <worktree> <goal_file> <files> "$INPUTS_DIR" [--range <diff_range>]
```

`claude-review-exec.sh` は同一 worktree の `<goal_file> <diff_range>` 対を1組以上受け取り、対ごとに review エージェント用の指示ファイルを生成して委譲する。inputs ディレクトリは末尾の `--inputs-dir <dir>` で指定する。従来の単一ペアに限り、第4引数の inputs ディレクトリ指定と `diff_range` 省略時の `HEAD` も使える。`HEAD` は追跡済みファイルの未コミット変更のみが対象で、未追跡ファイルは差分に出ないため `claude-review-files-exec.sh` を使う。コミット済み変更は `main..HEAD` や `HEAD~3..HEAD` のように明示する。

`claude-review-files-exec.sh` は `<worktree> <goal_file> <files> [inputs_dir] [--range <diff_range>]` を受け取る。`--range` を指定すると git 管理下のファイルはその diff 範囲だけがレビュー対象になり、ファイル全文は差分を解釈する文脈としてのみ読ませる。`--range` を省略するとファイル全文がレビュー対象になる。git 管理外・新規作成のファイルは `--range` の有無にかかわらず全文が対象。

どちらのスクリプトも、生成する指示ファイルに「差分に含まれない既存コードへの指摘はしない」旨の note を入れる。

Bash 呼び出しは常に `run_in_background: true` を指定する。

## レビュー対象の受け渡し

- **ブランチを指定する場合**は、そのブランチの起点コミットから最終コミットまでの差分をレビュー対象にする。開始・終了コミットに解決し、`claude-review-exec.sh` に diff_range（例 `main..HEAD`）として渡す。区切りごとの差分だけを渡さない。
- **ブランチを指定しない場合**は、対象ファイルを明示する。`claude-review-files-exec.sh` にファイルを指定し、git 管理下のファイルなら追加でコミットhash（diff_range）も `--range` で指定する。
- レビューを回すために追加でコミットさせない。

## 失敗時の扱い

- 委譲先コマンドが非0終了・ハングした場合は、独自のワークアラウンドを探さず、ログと状況をユーザーに報告して判断を仰ぐ。
- 同じ指示での自動リトライはしない（自動モデル切替もしない）。
- `DELEGATE_PERMISSION_OUT_OF_SCOPE` で終了した場合、指示を修正する前に `.claude/agents/review.md` と実行スクリプトを読んで原因を確定する。推測のまま同型の指示で再委譲しない。
