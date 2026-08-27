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

git 管理下の実装を委譲する場合、委譲先に依頼するのは **コード編集とコミットのみ**。テスト実行・rubocop / lint・アプリ起動・動作検証など、コード編集以外のツール実行を委譲先にさせない（検証は別工程として委譲する）。git 管理外の作業文書・計画書の編集を委譲する場合は、コミットを完了条件にせず、変更内容の報告で完了とする。

指示ファイル（テンプレ・手書き問わず）に「テストが通る」「検収に耐える」等、検証・検収を示唆する文言を入れない。これらは委譲先が環境外の迂回実行に走る誘因になり、その失敗報告はシグナルとして信用できない。品質は静的な性質（可読性・保守性・既存の設計/命名/作法との一貫性）で表現する。

## 委譲の粒度

1委譲は1関心事に絞る。独立して完結・検証できる最小単位に分割し、複数の関心事（撤去＋新設、複数スキルの改修など）を1つの指示ファイルに混ぜない。

複数の関心事を並列に進める場合は、関心事ごとに指示ファイルを分けて並列投入する。1リポジトリは1委譲として扱い、複数リポジトリをまたぐ作業はリポジトリごとに分ける。

## 使い方

```
/delegate <work_dir_path>
```

## バックエンド

利用可能モデル一覧は `model-tiers.tsv` に持つ。これは `backend<TAB>model<TAB>performance` のローカル固有の設定表（`.gitignore` で追跡しない）で、performance はフォールバック候補の並べ替えに使う。

委譲先の `task_type` と backend / agent / 使用モデルの対応は `routing.tsv` に持つ。これは `task_type<TAB>backend<TAB>agent<TAB>model` のローカル固有の設定表（`.gitignore` で追跡しない）で、実行スクリプトはこの表から具体モデル名を直接読む。implementation の agent は、backend が `claude` のとき `impl`、backend が `codex` のとき空欄にする（codex は agent を使わない）。

起動スクリプトは作業種別で選ぶ。

- 実装: `routing.tsv` の implementation 行の backend で決める（`codex` → `scripts/codex-exec.sh` / `claude` → `scripts/claude-impl-exec.sh`）。委譲前に必ず `routing.tsv` を読み、記憶や既定の思い込みでスクリプトを選ばない。
- その他（調査/現状把握/設計/トレードオフ比較）: `scripts/claude-sub-exec.sh`
- レビュー: `scripts/claude-review-exec.sh`

claude の各エージェント用スクリプトは薄いラッパで、共通処理（モデル解決・追加資料の読み込み・`--add-dir` 組み立て・プロンプト生成・実行と結果出力・フォールバック提案）は `scripts/claude-common.sh` に集約する。

どの backend を使うかは `routing.tsv` が唯一の情報源。backend の切り替え（codex のクォータ切れ・障害による退避など）は `routing.tsv` の書き換えで表現し、このドキュメントに既定を書かない。claude の `impl` エージェントは書き込みとコミットを許可し、検証コマンド（テスト・lint・ビルド・アプリ起動）の実行を禁止する。

Codex は `codex exec -C <work_dir>` で起動し、追加の inputs/context ディレクトリだけを `--add-dir` する。claude はエージェント別スクリプト（`claude-sub-exec.sh` / `claude-impl-exec.sh` / `claude-review-agent-exec.sh`）が共通部 `claude-common.sh` 経由で `claude -p --agent <agent> --model <model>` を起動し、作業場所 / inputs / context ディレクトリを `--add-dir` する。claude 版は cwd を変えないため、プロンプトで作業対象ディレクトリと `git -C <work_dir>` の使用を明示する。

委譲 CLI が非0終了し、出力に `DELEGATE_PERMISSION_OUT_OF_SCOPE` が含まれない場合、実行スクリプトは stderr に `DELEGATE_FALLBACK_SUGGEST<TAB>failed=<model><TAB>next=<model><TAB>reason=exec_failed` を1行だけ出す。これは提案のみであり、自動リトライ・自動モデル切替・`model-tiers.tsv` の書き換えはしないため、「同じ指示での自動リトライはしない」規約と矛盾しない。

### モデル階層とキャッシュ

委譲先モデルの性能順は `model-tiers.tsv` に持つ。これは `backend<TAB>model<TAB>performance` のローカル固有の設定表（`.gitignore` で追跡しない）で、性能値が大きいほど高性能。実行スクリプトはこの表を書き換えない。主選定は `routing.tsv` の具体モデル名を使い、`model-tiers.tsv` はフォールバック候補の並べ替えに使う。

モデル確認用キャッシュは `.model-cache/<backend>-models.json` に週次保存する。このキャッシュは生成物なので git 追跡しない。実行スクリプトの冒頭で、キャッシュの mtime の ISO 週が今週ならそのまま委譲し、キャッシュ不在または週が変わっている場合だけ正規手段で再取得する。

codex は `codex debug models` を使って再取得する。claude は CLI にモデル一覧取得コマンドが無いため、認証不要の Anthropic 公式 docs 公開 Markdown（`https://platform.claude.com/docs/en/about-claude/models/overview.md`）を取得し、既存の週次判定用キャッシュファイルに本文をそのまま保存する。

再取得後のキャッシュ内容と `model-tiers.tsv` の照合、警告、続行可否の詳細は `scripts/model-cache.sh` に実装を集約する。

モデル一覧または claude 公式 docs Markdown の取得に失敗した場合、古いキャッシュが存在すればその日付を警告1行で出して続行する（廃止モデル指定の失敗は exec 失敗として `DELEGATE_FALLBACK_SUGGEST` で可視化される）。キャッシュが1つも無い場合のみ fail-closed とし委譲を実行しない。

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

指示ファイルの作成は `scripts/write-input.sh <task_name> [inputs_dir]`（本文は stdin）を使う。汎用 Write/cat は sync 締切フックで止まるが、この専用ラッパは「委譲の下準備」として明示許可される。作成先ディレクトリは呼び出し元が指定でき、未指定時は `/tmp/delegate-inputs/` に作成する。

```bash
INPUTS_DIR=/tmp/delegate-inputs
bash {BASE_DIR}/scripts/write-input.sh <task> "$INPUTS_DIR" <<'EOF'
<指示本文>
EOF
```

### 追加資料の選定

委譲先に追加の参照資料を渡したい場合は、`amuro` スキルを使って現在のタスクに関連するガイドライン（実装/テスト設計指針など）を選定する（全件を無条件には選ばない）。amuro が自分の doc 位置を解決するので、参照先パスをこのスキル側にハードコードしない。選定したファイルの絶対パスを1行1件で `$INPUTS_DIR/<task>-context.txt` に書き、実行スクリプトの第4引数に渡す。委譲先には選定済み資料だけが明示される。

コード実装でない委譲や、関連する資料が無い場合（設定ファイルの機械的変更など）は選定ファイルを作らず、従来どおり第3引数までで実行する。

実行スクリプトは、スキル起動時に示されるベースディレクトリ（"Base directory for this skill: ..."）を使って実行する。

指示ファイルは使い捨てのため、スキルディレクトリ内ではなく呼び出し元が指定した inputs ディレクトリに作成する。未指定時の既定値は `/tmp/delegate-inputs/`。

```bash
INPUTS_DIR=/tmp/delegate-inputs
mkdir -p "$INPUTS_DIR"
bash {BASE_DIR}/scripts/codex-exec.sh <work_dir_path> <task>.md "$INPUTS_DIR"
bash {BASE_DIR}/scripts/claude-sub-exec.sh <work_dir_path> <task>.md "$INPUTS_DIR"
bash {BASE_DIR}/scripts/claude-review-exec.sh <work_dir_path> <goal_file> [diff_range] "$INPUTS_DIR"

# 追加資料を選定した場合
bash {BASE_DIR}/scripts/codex-exec.sh <work_dir_path> <task>.md "$INPUTS_DIR" "$INPUTS_DIR/<task>-context.txt"
bash {BASE_DIR}/scripts/claude-sub-exec.sh <work_dir_path> <task>.md "$INPUTS_DIR" "$INPUTS_DIR/<task>-context.txt"
```

`claude-review-exec.sh` は `<goal_file>` とレビュー対象 diff 範囲から review エージェント用の指示ファイルを inputs ディレクトリに生成し、`claude-review-agent-exec.sh` に渡す。使用モデルは `routing.tsv` の review 行から `claude-common.sh` が読む。`diff_range` を省略した場合は `HEAD` を使い、追跡済みファイルの未コミット変更のみをレビュー対象にする。未追跡ファイル・git 管理外ファイルはこの方法では差分に出ないため、それらのレビューには `claude-review-files-exec.sh` でファイルパスを指定する。コミット済み変更をレビューする場合は `main..HEAD` や `HEAD~3..HEAD` のように明示する。

Bash 呼び出しは常に `run_in_background: true` を指定する。複数の並列実行は、この非同期実行を複数回投入する一形態として扱う。

## レビュー（必須）

実装委譲（`codex-exec.sh` / `claude-impl-exec.sh` によるコード編集）が完了したら、**必ず**レビューを回す。レビューを別工程として委譲せずに diff を目視しただけ、`bash -n` や構文確認をしただけでは完了にしない。

- 対象には、その委譲が変更したファイルを指定する。git 管理下のファイルの場合は diff_range（コミット範囲）を渡し（例: `HEAD~1..HEAD`）、git 管理外のファイルの場合はファイルパスを指定する。レビューを回すためにコミットさせない。
- レビュー結果を確認するまで、そのサブタスクを完了扱いにしない・ユーザーへ完了報告をしない。
- 指摘が出た場合は、修正も実装委譲としてやり直し、再度レビューを回す。

調査・設計など、コード編集を伴わない委譲はこの対象外。

## 指示ファイルのテンプレート

`inputs/_template.md`（スキル同梱）を参照し、指定した inputs ディレクトリの `<task>.md` にコピーして使う。

## 失敗時の扱い

- 委譲先コマンド（`codex exec` / `claude -p`）が非0終了した場合・ハングした場合は、独自のワークアラウンドを探さず、ログと状況をユーザーに報告して判断を仰ぐ。
- 同じ指示での自動リトライはしない（指示を変えずに再実行しても結果は変わらない）。

## 例

```bash
INPUTS_DIR=/tmp/delegate-inputs
bash {BASE_DIR}/scripts/codex-exec.sh /path/to/workdir <task>.md "$INPUTS_DIR"
bash {BASE_DIR}/scripts/claude-sub-exec.sh /path/to/workdir <task>.md "$INPUTS_DIR"
bash {BASE_DIR}/scripts/claude-review-exec.sh /path/to/workdir /path/to/goal.md main..HEAD "$INPUTS_DIR"
```
