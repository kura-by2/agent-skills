---
name: delegate
description: >
  ファンネル（委譲先バックエンド）に作業を委譲するスキル。`/delegate work_dir_path` の形式で呼ぶ。
  作業種別に応じて委譲先へ振り分ける。
---

# delegate

実装内容の詳細（コード・ファイル構造）は考えない。**何をすべきか**だけを伝え、実作業は委譲先に任せる。

delegate の役割は、作業場所を指定し、その作業を非同期に実行させること。単発でも複数の並列委譲でも、委譲先コマンドは常に `run_in_background: true` で Bash を呼んで起動する。呼び出し側は投入後すぐ sync 点に戻り、委譲先の完了を同期的に待たない。

## 委譲のスコープ

実装を委譲する場合、委譲先に依頼するのは **コード編集とコミットのみ**。テスト実行・rubocop / lint・アプリ起動・動作検証など、コード編集以外のツール実行を委譲先にさせない（検証は委譲元／別工程の責務）。

指示ファイル（テンプレ・手書き問わず）に「テストが通る」「検収に耐える」等、検証・検収を示唆する文言を入れない。これらは委譲先が環境外の迂回実行に走る誘因になり、その失敗報告はシグナルとして信用できない。品質は静的な性質（可読性・保守性・既存の設計/命名/作法との一貫性）で表現する。

## 使い方

```
/delegate <work_dir_path>
```

## バックエンド

委譲先は作業種別で固定する。

- 実装: `scripts/codex-exec.sh`（Codex、agent指定なし、Codex既定モデル）
- その他（調査/現状把握/設計/トレードオフ比較）: `scripts/claude-exec.sh sub high ...`（claude、agent `sub`、高性能モデル）
- レビュー: `scripts/claude-review-exec.sh ...`（内部で `scripts/claude-exec.sh review standard ...` を実行。claude、agent `review`、低性能側モデル）

Codex は `codex exec -C <work_dir>` で起動し、追加の inputs/context ディレクトリだけを `--add-dir` する。claude は `claude -p --agent <agent> --model <model>` で起動し、作業場所 / inputs / context ディレクトリを `--add-dir` する。claude 版は cwd を変えないため、プロンプトで作業対象ディレクトリと `git -C <work_dir>` の使用を明示する。

指定モデルが rate-limit 等で使えない場合は、同じ作業種別を満たせる代替を当該実行で自動的に探して使う。順序は、まず同サービスの低性能モデル、解消しなければ別サービス（codex↔claude）のモデルとする。対応表（`model-tiers.tsv` / `delegate-routes.tsv`）を書き換えるためのユーザー確認は、このフォールバック時のみ必要とする。週次の再取得・確定・保存のタイミングでは、従来どおり確認は不要。適切な代替が無い場合は、ログと状況をユーザーに報告して判断を仰ぐ。

### モデル階層とキャッシュ

委譲先モデルの思考力階層は `model-tiers.tsv` に持つ。これは git 管理の階層表で、バックエンド・モデル識別子・階層・確認日を人間/呼び出し側LLMが更新する。実行スクリプトはこの表を書き換えない。

モデル確認用キャッシュは `.model-cache/<backend>-models.json` に週次保存する。このキャッシュは生成物なので git 追跡しない。実行スクリプトの冒頭で、キャッシュの mtime の ISO 週が今週ならそのまま委譲し、キャッシュ不在または週が変わっている場合だけ正規手段で再取得する。

codex は `codex debug models` を使って再取得する。claude は CLI にモデル一覧取得コマンドが無いため、認証不要の Anthropic 公式 docs 公開 Markdown（`https://platform.claude.com/docs/en/about-claude/models/overview.md`）を取得し、既存の週次判定用キャッシュファイルに本文をそのまま保存する。

再取得後のキャッシュ内容と `model-tiers.tsv` の照合、警告、続行可否の詳細は `scripts/model-cache.sh` に実装を集約する。

委譲先3分類の対応表は `.model-cache/delegate-routes.tsv` に生成する。これは `model-tiers.tsv` と利用可能モデル一覧から週次キャッシュ更新時に組み立てる生成物であり、git 追跡しない。

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

指示ファイルの作成は `scripts/write-input.sh <task_name>`（本文は stdin）を使う。汎用 Write/cat は sync 締切フックで止まるが、この専用ラッパは「委譲の下準備」として明示許可される。作成先は `/tmp/delegate-inputs/<task_name>.md`。

```bash
bash {BASE_DIR}/scripts/write-input.sh <task> <<'EOF'
<指示本文>
EOF
```

### 追加資料の選定

委譲先に追加の参照資料を渡したい場合は、`amuro` スキルを使って現在のタスクに関連するガイドライン（実装/テスト設計指針など）を選定する（全件を無条件には選ばない）。amuro が自分の doc 位置を解決するので、参照先パスをこのスキル側にハードコードしない。選定したファイルの絶対パスを1行1件で `/tmp/delegate-inputs/<task>-context.txt` に書き、実行スクリプトの第4引数に渡す。委譲先には選定済み資料だけが明示される。

コード実装でない委譲や、関連する資料が無い場合（設定ファイルの機械的変更など）は選定ファイルを作らず、従来どおり第3引数までで実行する。

実行スクリプトは、スキル起動時に示されるベースディレクトリ（"Base directory for this skill: ..."）を使って実行する。

指示ファイルは使い捨てのため、スキルディレクトリ内ではなく `/tmp/delegate-inputs/` に作成する。

```bash
mkdir -p /tmp/delegate-inputs
bash {BASE_DIR}/scripts/codex-exec.sh <work_dir_path> <task>.md /tmp/delegate-inputs
bash {BASE_DIR}/scripts/claude-exec.sh sub high <work_dir_path> <task>.md /tmp/delegate-inputs
bash {BASE_DIR}/scripts/claude-review-exec.sh <work_dir_path> <goal_file> [diff_range] /tmp/delegate-inputs

# 追加資料を選定した場合
bash {BASE_DIR}/scripts/codex-exec.sh <work_dir_path> <task>.md /tmp/delegate-inputs /tmp/delegate-inputs/<task>-context.txt
bash {BASE_DIR}/scripts/claude-exec.sh sub high <work_dir_path> <task>.md /tmp/delegate-inputs /tmp/delegate-inputs/<task>-context.txt
```

`claude-review-exec.sh` は `<goal_file>` とレビュー対象 diff 範囲から review エージェント用の指示ファイルを `/tmp/delegate-inputs/` に生成し、`claude-exec.sh review standard` に渡す。`diff_range` を省略した場合は `HEAD` を使い、未コミット差分をレビュー対象にする。コミット済み変更をレビューする場合は `main..HEAD` や `HEAD~3..HEAD` のように明示する。

Bash 呼び出しは常に `run_in_background: true` を指定する。複数の並列実行は、この非同期実行を複数回投入する一形態として扱う。

## 指示ファイルのテンプレート

`inputs/_template.md`（スキル同梱）を参照し、`/tmp/delegate-inputs/<task>.md` にコピーして使う。

## 失敗時の扱い

- 委譲先コマンド（`codex exec` / `claude -p`）が非0終了した場合・ハングした場合は、独自のワークアラウンドを探さず、ログと状況をユーザーに報告して判断を仰ぐ。
- 同じ指示での自動リトライはしない（指示を変えずに再実行しても結果は変わらない）。

## 例

```bash
bash {BASE_DIR}/scripts/codex-exec.sh /path/to/workdir <task>.md /tmp/delegate-inputs
bash {BASE_DIR}/scripts/claude-exec.sh sub high /path/to/workdir <task>.md /tmp/delegate-inputs
bash {BASE_DIR}/scripts/claude-review-exec.sh /path/to/workdir /path/to/goal.md main..HEAD /tmp/delegate-inputs
```
