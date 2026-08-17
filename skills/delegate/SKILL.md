---
name: delegate
description: >
  ファンネル（委譲先バックエンド）にコード実装を委譲するスキル。`/delegate worktree_path` の形式で呼ぶ。
  デフォルトの委譲先はCodex。rate-limit等で使えないときはclaudeバックエンドに切り替える。
---

# delegate

実装内容の詳細（コード・ファイル構造）は考えない。**何をすべきか**だけを伝え、実装は委譲先に任せる。

## 委譲のスコープ

委譲先に依頼するのは **コード編集とコミットのみ**。テスト実行・rubocop / lint・アプリ起動・動作検証など、コード編集以外のツール実行を委譲先にさせない（検証は委譲元／別工程の責務）。

指示ファイル（テンプレ・手書き問わず）に「テストが通る」「検収に耐える」等、検証・検収を示唆する文言を入れない。これらは委譲先が環境外の迂回実行に走る誘因になり、その失敗報告はシグナルとして信用できない。品質は静的な性質（可読性・保守性・既存の設計/命名/作法との一貫性）で表現する。

## 使い方

```
/delegate <worktree_path>
```

## バックエンド

実行スクリプトはバックエンドごとに分かれており、引数インターフェースは共通（`<worktree> <task_file> [inputs_dir] [selected_context_file]`）。切り替えは実行するスクリプトの差し替えだけで行う。

- デフォルト: `scripts/codex-exec.sh`（Codex）
- 切替先: `scripts/claude-exec.sh`（claude -p）

Codex は `codex exec -C <worktree>` で起動し、追加の inputs/context ディレクトリだけを `--add-dir` する。claude は `--agent` を付けず素の `claude -p` で起動し、worktree / inputs / context ディレクトリを `--add-dir` する。claude 版は cwd を変えないため、プロンプトで作業対象 worktree と `git -C <worktree>` の使用を明示する。

rate-limit 等でデフォルトが使えない場合、自動でフォールバックせず、切替先での実行をユーザーに提案して承認を得てから実行する。

### モデル階層とキャッシュ

委譲先モデルの思考力階層は `model-tiers.tsv` に持つ。これは git 管理の判断表で、バックエンド・モデル識別子・階層・確認日を人間/呼び出し側LLMが更新する。実行スクリプトはこの表を書き換えない。

モデル確認用キャッシュは `.model-cache/<backend>-models.json` に週次保存する。このキャッシュは生成物なので git 追跡しない。実行スクリプトの冒頭で、キャッシュの mtime の ISO 週が今週ならそのまま委譲し、キャッシュ不在または週が変わっている場合だけ正規手段で再取得する。

codex は `codex debug models` を使って再取得する。claude は CLI にモデル一覧取得コマンドが無いため、認証不要の Anthropic 公式 docs 公開 Markdown（`https://platform.claude.com/docs/en/about-claude/models/overview.md`）を取得し、既存の週次判定用キャッシュファイルに本文をそのまま保存する。

再取得後、キャッシュ内容と `model-tiers.tsv` に差分があれば stderr に警告する。codex は `codex debug models` の JSON から `visibility == "list"` の slug だけを保存し、階層表にあるモデルが一覧から消えている場合を retirement 候補、一覧にあるモデルが階層表に無い場合を未分類として扱う。claude は階層表のモデルIDが公式 docs 本文に存在するか、近傍に deprecated / retired があるかを grep ベースで確認する。警告だけなら委譲は続行する。

モデル一覧または claude 公式 docs Markdown の取得に失敗した場合は fail-closed とし、古いキャッシュで続行せず委譲を実行しない。

## 渡すべき情報

- **何を実装するか**（エンドポイント名・機能の概要）
- **参照すべき既存コード**（似た実装があればそのパスと何を参考にするか）

## 渡してはいけない情報

- 具体的なコード（委譲先が書く）
- ファイルパスの列挙（委譲先が判断する）
- 実装の手順（委譲先が考える）
- 検証・検収の指示（テスト実行・lint・動作確認は委譲のスコープ外）

## 実行コマンド

複雑な指示をプロンプト直書きするとstdin読み込みでハングするため、指示ファイルに書いてから渡す。

### 追加資料の選定

委譲先に追加の参照資料を渡したい場合は、`amuro` スキルを使って現在のタスクに関連するガイドライン（実装/テスト設計指針など）を選定する（全件を無条件には選ばない）。amuro が自分の doc 位置を解決するので、参照先パスをこのスキル側にハードコードしない。選定したファイルの絶対パスを1行1件で `/tmp/delegate-inputs/<task>-context.txt` に書き、実行スクリプトの第4引数に渡す。委譲先には選定済み資料だけが明示される。

コード実装でない委譲や、関連する資料が無い場合（設定ファイルの機械的変更など）は選定ファイルを作らず、従来どおり第3引数までで実行する。

実行スクリプトは、スキル起動時に示されるベースディレクトリ（"Base directory for this skill: ..."）を使って実行する。

指示ファイルは使い捨てのため、スキルディレクトリ内ではなく `/tmp/delegate-inputs/` に作成する。

```bash
mkdir -p /tmp/delegate-inputs
bash {BASE_DIR}/scripts/codex-exec.sh <worktree_path> <task>.md /tmp/delegate-inputs

# 追加資料を選定した場合
bash {BASE_DIR}/scripts/codex-exec.sh <worktree_path> <task>.md /tmp/delegate-inputs /tmp/delegate-inputs/<task>-context.txt
```

バックグラウンドで複数worktreeを並列実行する場合は `run_in_background: true` で Bash を呼ぶ。

## 指示ファイルのテンプレート

`inputs/_template.md`（スキル同梱）を参照し、`/tmp/delegate-inputs/<task>.md` にコピーして使う。

## 失敗時の扱い

- 委譲先コマンド（`codex exec` / `claude -p`）が非0終了した場合・ハングした場合は、独自のワークアラウンドを探さず、ログと状況をユーザーに報告して判断を仰ぐ。
- 同じ指示での自動リトライはしない（指示を変えずに再実行しても結果は変わらない）。

## 例

```bash
bash {BASE_DIR}/scripts/codex-exec.sh /path/to/worktree <task>.md /tmp/delegate-inputs
```
