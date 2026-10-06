---
name: delegate-impl
description: >
  実装作業を委譲先（codex / claude の impl エージェント）に非同期で実行させるスキル。
  `/delegate-impl <work_dir_path>` の形式で呼ぶ。コード編集とコミットだけを委譲する。
---

# delegate-impl

実装内容の詳細（コード・ファイル構造）は考えない。**何をすべきか**だけを伝え、実作業は委譲先に任せる。

作業場所を指定し、その実装を非同期に実行させる。単発でも複数の並列委譲でも、委譲先コマンドは常に `run_in_background: true` で Bash を呼んで起動する。呼び出し側は投入後すぐ sync 点に戻り、委譲先の完了を同期的に待たない。

## 委譲のスコープ

委譲先に依頼するのは **コード編集とコミットのみ**。テスト実行・rubocop / lint・アプリ起動・動作検証など、コード編集以外のツール実行を委譲先にさせない（検証は別工程として委譲する）。

指示ファイルに「テストが通る」「検収に耐える」等、検証・検収を示唆する文言を入れない。これらは委譲先が環境外の迂回実行に走る誘因になり、その失敗報告はシグナルとして信用できない。品質は静的な性質（可読性・保守性・既存の設計/命名/作法との一貫性）で表現する。

## 委譲の粒度

1委譲は1関心事に絞る。独立して完結・検証できる最小単位に分割し、複数の関心事を1つの指示ファイルに混ぜない。複数の関心事を並列に進める場合は、関心事ごとに指示ファイルを分けて並列投入する。1リポジトリは1委譲として扱い、複数リポジトリをまたぐ作業はリポジトリごとに分ける。

## 使い方

```
/delegate-impl <work_dir_path>
```

## モデルの決め方

プロジェクトルートは `AGENT_PROJECT_DIR` → `CLAUDE_PROJECT_DIR` → カレントの git リポジトリルートの順で解決する。以下の `$AGENT_PROJECT_DIR` 表記はこの解決後のルートを指す。state は `.gitignore` で追跡しない。

- **モデル一覧（`$AGENT_PROJECT_DIR/state/delegate/model-tiers.tsv`）**: `backend<TAB>model<TAB>summary` の3列。起動時に最終更新が1日以上前（または不在）なら作り直す。モデル一覧は model-cache（codex: `codex debug models` / claude: 公式 docs Markdown）から退役していない利用可能モデルを取り、各モデルの1行要約を `claude -p --model haiku` で作る。要約に失敗したモデルはキャッシュ上の説明文を使う。キャッシュが1つも無ければ fail-closed（委譲しない）。
- **フォールバック（`$AGENT_PROJECT_DIR/state/delegate/fallback/impl.tsv`）**: `backend<TAB>model`。model-tiers を作り直したときに生成する。impl は codex の行と claude の行の2行（backend ごとに1問、Jev の choice で判定）。Jev が失敗したら既存ファイルを残す。
- **委譲ごとの判定**: 指示ファイル本文を `claude -p --model haiku` で「作業の種類」だけの日本語1文（固有名詞・パス・URL・鍵・コードを含まない）に要約し、その要約を Jev に送って model-tiers の中から使うモデルを choice で判定する。候補は codex と claude 両方。確信度 0.6 未満・鍵なし・HTTP 失敗・3秒超過・要約失敗のときは `fallback/impl.tsv` の1行目を使う。
- 指示ファイル本文は Jev に送らない（要約のみ）。接続先は `api.typesafe.ai` に固定し、鍵の値と本文はログ・出力に書かない。

## バックエンド

`impl-exec.sh` は選ばれた backend に応じて `codex-exec.sh`（`codex exec -C <work_dir>` を起動）か `claude-impl-exec.sh`（`claude -p --agent impl --model <model>` を起動）を呼ぶ。`impl-exec.sh` がモデル判定と2回失敗時の切替を担い、backend ごとの実行はこの2つのスクリプトが行う。claude は cwd を変えず、作業対象 worktree・inputs・追加資料ディレクトリを `--add-dir` で渡す。impl エージェントは書き込みとコミットを許可し、検証コマンド（テスト・lint・ビルド・アプリ起動）の実行を禁止する。

## LLM 切替（impl のみ）

同じ backend で2回連続して非0終了（`DELEGATE_PERMISSION_OUT_OF_SCOPE` を除く）したら、`fallback/impl.tsv` のもう一方の backend の行のモデルで、同じ worktree・同じ指示ファイルのまま再実行する（指示文は追加しない）。1回目の失敗後は同じモデルでもう1回実行する。

## 渡すべき情報

- **何を実装するか**（エンドポイント名・機能の概要）
- **参照すべき既存コード**（似た実装があればそのパスと何を参考にするか）

## 渡してはいけない情報

- 具体的なコード（委譲先が書く）
- ファイルパスの列挙（委譲先が判断する）
- 実装の手順（委譲先が考える）
- 検証・検収の指示（テスト実行・lint・動作確認は委譲のスコープ外）
- ユーザー指示に含まれていない補足・拡大解釈・「やったほうがいいこと」の追加（指示は原発言の範囲で書き写す。足したいことがあれば指示ファイルに混ぜず別項目として確認する）

## 実行コマンド

複雑な指示をプロンプト直書きするとstdin読み込みでハングするため、指示ファイルに書いてから渡す。

指示ファイルを書く前に委譲先エージェントの定義（`.claude/agents/impl.md`）で権限（書き込み可否・hook block）を確認し、完了条件をその権限内で書く。

指示ファイルの作成は `scripts/write-input.sh <task_name> [inputs_dir]`（本文は stdin）を使う。汎用 Write/cat は sync 締切フックで止まるが、この専用ラッパは「委譲の下準備」として明示許可される。作成先ディレクトリは呼び出し元が指定でき、未指定時は `/tmp/delegate-inputs/` に作成する。

```bash
INPUTS_DIR=/tmp/delegate-inputs
bash {BASE_DIR}/scripts/write-input.sh <task> "$INPUTS_DIR" <<'EOF'
<指示本文>
EOF
```

### 追加資料の選定

委譲先に追加の参照資料を渡したい場合は、`amuro` スキルを使って現在のタスクに関連するガイドラインを選定する（全件を無条件には選ばない）。選定したファイルの絶対パスを1行1件で `$INPUTS_DIR/<task>-context.txt` に書き、実行スクリプトの第4引数に渡す。コード実装でない委譲や関連資料が無い場合は選定ファイルを作らず第3引数までで実行する。

実行スクリプトは、スキル起動時に示されるベースディレクトリ（"Base directory for this skill: ..."）を使って実行する。指示ファイルは使い捨てのため、スキルディレクトリ内ではなく呼び出し元が指定した inputs ディレクトリに作成する。

```bash
INPUTS_DIR=/tmp/delegate-inputs
mkdir -p "$INPUTS_DIR"
bash {BASE_DIR}/scripts/impl-exec.sh <work_dir_path> <task>.md "$INPUTS_DIR"

# 追加資料を選定した場合
bash {BASE_DIR}/scripts/impl-exec.sh <work_dir_path> <task>.md "$INPUTS_DIR" "$INPUTS_DIR/<task>-context.txt"
```

Bash 呼び出しは常に `run_in_background: true` を指定する。複数の並列実行は、この非同期実行を複数回投入する一形態として扱う。

## レビュー対象の受け渡し

`impl-exec.sh` はレビューを起動しない。委譲先は変更した各ファイルを最終報告に `DELEGATE_CHANGED_FILE<TAB><絶対パス>` 形式（`<TAB>` はタブ文字）で1行ずつ列挙する。`impl-exec.sh` はその申告だけを抽出し、標準出力へ `DELEGATE_REVIEW_FILE<TAB><絶対パス>` 形式で渡す。

委譲先から申告が1行もない場合、`DELEGATE_REVIEW_UNRESOLVED<TAB><worktree><TAB>no_declared_files` を出力する。これは変更なしを意味せず、レビュー対象を特定できていないことを表す。レビューを回すために追加でコミットさせない。

## 指示ファイルのテンプレート

`inputs/_template.md`（スキル同梱）を、指定した inputs ディレクトリの `<task>.md` にコピーして使う。コピーした各セクションは、該当するセクションは作業に即した内容を書き、該当しないセクションは `なし（理由: …）` と書く。テンプレの定型文をそのまま残さない。

## 失敗時の扱い

- 委譲先コマンドがハングした場合は、独自のワークアラウンドを探さず、ログと状況をユーザーに報告して判断を仰ぐ。
- 上記の LLM 切替を除き、同じ指示での自動リトライはしない。
- `DELEGATE_PERMISSION_OUT_OF_SCOPE` で終了した場合、指示を修正する前に委譲先のエージェント定義（`.claude/agents/impl.md`）と実行スクリプトを読んで原因を確定する。推測のまま同型の指示で再委譲しない。
