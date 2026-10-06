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

実行スクリプトを直接呼ぶ。diff 範囲指定は `review-exec.sh`、ファイル指定は `review-files-exec.sh`。

## モデルの決め方

プロジェクトルートは `AGENT_PROJECT_DIR` → `CLAUDE_PROJECT_DIR` → カレントの git リポジトリルートの順で解決する。state は `.gitignore` で追跡しない。

- **モデル一覧（`$AGENT_PROJECT_DIR/state/delegate/model-tiers.tsv`）**: `backend<TAB>model<TAB>summary` の3列。起動時に最終更新が1日以上前（または不在）なら作り直す。モデル一覧は model-cache（codex: `codex debug models` / claude: 公式 docs Markdown）から退役していない利用可能モデルを取り、各モデルの1行要約を `claude -p --model haiku` で作る。要約に失敗したモデルはキャッシュ上の説明文を使う。キャッシュが1つも無ければ fail-closed（委譲しない）。
- **フォールバック（`$AGENT_PROJECT_DIR/state/delegate/fallback/review.tsv`）**: `backend<TAB>model`。model-tiers を作り直したときに claude の1行を Jev の choice で生成する。Jev が失敗したら既存ファイルを残す。
- **委譲ごとの判定**: 生成した指示ファイル本文を `claude -p --model haiku` で「作業の種類」だけの日本語1文（固有名詞・パス・URL・鍵・コードを含まない）に要約し、その要約を Jev に送って model-tiers の中から使うモデルを choice で判定する。候補は claude のみ。確信度 0.6 未満・鍵なし・HTTP 失敗・3秒超過・要約失敗のときは `fallback/review.tsv` を使う。
- 指示ファイル本文は Jev に送らない（要約のみ）。接続先は `api.typesafe.ai` に固定し、鍵の値と本文はログ・出力に書かない。

## バックエンド

`review-agent-exec.sh` は claude（`claude -p --agent review --model <model>`）を起動する。cwd は変えず、作業対象 worktree・inputs・追加資料ディレクトリを `--add-dir` で渡す。review エージェントは Edit/Write/MultiEdit を禁止する。指示ファイルは `review-exec.sh` / `review-files-exec.sh` が生成する。

## 実行コマンド

実行スクリプトは、スキル起動時に示されるベースディレクトリ（"Base directory for this skill: ..."）を使って実行する。指示ファイルは呼び出し元が指定した inputs ディレクトリに生成する（未指定時は `/tmp/delegate-inputs/`）。

```bash
INPUTS_DIR=/tmp/delegate-inputs
mkdir -p "$INPUTS_DIR"
bash {BASE_DIR}/scripts/review-exec.sh <worktree> <goal1> <diff1> [<goal2> <diff2> ...] --inputs-dir "$INPUTS_DIR"
bash {BASE_DIR}/scripts/review-files-exec.sh <worktree> <goal_file> <files> "$INPUTS_DIR" [--range <diff_range>]
```

`review-exec.sh` は同一 worktree の `<goal_file> <diff_range>` 対を1組以上受け取り、対ごとに review エージェント用の指示ファイルを生成して `review-agent-exec.sh` に渡す。inputs ディレクトリは末尾の `--inputs-dir <dir>` で指定する。従来の単一ペアに限り、第4引数の inputs ディレクトリ指定と `diff_range` 省略時の `HEAD` も使える。`HEAD` は追跡済みファイルの未コミット変更のみが対象で、未追跡ファイルは差分に出ないため `review-files-exec.sh` を使う。コミット済み変更は `main..HEAD` や `HEAD~3..HEAD` のように明示する。

`review-files-exec.sh` は `<worktree> <goal_file> <files> [inputs_dir] [--range <diff_range>]` を受け取る。`--range` を指定すると git 管理下のファイルはその diff 範囲だけがレビュー対象になり、ファイル全文は差分を解釈する文脈としてのみ読ませる。`--range` を省略するとファイル全文がレビュー対象になる。git 管理外・新規作成のファイルは `--range` の有無にかかわらず全文が対象。

どちらのスクリプトも、生成する指示ファイルに「差分に含まれない既存コードへの指摘はしない」旨の note を入れる。

Bash 呼び出しは常に `run_in_background: true` を指定する。

## レビュー対象の受け渡し

- **ブランチを指定する場合**は、そのブランチの起点コミットから最終コミットまでの差分をレビュー対象にする。開始・終了コミットに解決し、`review-exec.sh` に diff_range（例 `main..HEAD`）として渡す。区切りごとの差分だけを渡さない。
- **ブランチを指定しない場合**は、対象ファイルを明示する。`review-files-exec.sh` にファイルを指定し、git 管理下のファイルなら追加でコミットhash（diff_range）も `--range` で指定する。
- レビューを回すために追加でコミットさせない。

## 失敗時の扱い

- 委譲先コマンドが非0終了・ハングした場合は、独自のワークアラウンドを探さず、ログと状況をユーザーに報告して判断を仰ぐ。
- 同じ指示での自動リトライはしない（自動モデル切替もしない）。
- `DELEGATE_PERMISSION_OUT_OF_SCOPE` で終了した場合、指示を修正する前に `.claude/agents/review.md` と実行スクリプトを読んで原因を確定する。推測のまま同型の指示で再委譲しない。
