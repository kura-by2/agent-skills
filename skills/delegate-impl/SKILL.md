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

- **モデル一覧（`scripts/llm-models/llm-models.json`）**: backend・model・description を持つオブジェクトの配列（claude は比較表の値を comparison オブジェクトでも持つ）。委譲の前に `scripts/llm-models/script.sh` を呼んで最新化する（失敗しても続行し、既存の一覧を使う）。一覧が不在なら Jev の候補が空になり、フォールバックへ倒れる。
- **フォールバック（自スキル配下の `scripts/fallback/<backend>.txt`・git 追跡外）**: 中身はモデル名1行。backend ごとのファイル（impl は `codex.txt` と `claude.txt`）に分かれ、鮮度判定（24時間）・Jev の choice での作り直し・失敗時の前回値維持は backend ごとに完結する。その backend が 24時間以上古い（または不在）のときだけ、このスキルのエージェント定義（`.claude/agents/impl.md`。codex backend 分も impl.md）を伏せ字化したものを state にして、その backend だけを1問で作り直す。定義ファイルが無い・伏せ字化に失敗したときはその backend の作り直し失敗として扱う。作り直しに失敗した backend は前回値をそのまま使い、どの backend にも値が無ければ fail-closed（どのファイルに何を書けば続行できるかを stderr に出す）。
- **委譲ごとの判定**: 指示ファイル本文を、要約用の共通スクリプトが選んだ要約モデルでマスキング（構成・作業内容・範囲・条件は残し、機密情報・固有名詞・パス・URL・識別子・コード・インシデント情報だけを伏せ字に置き換え、要約・圧縮はしない）し、そのマスキング済み本文を Jev に送って llm-models の中から使うモデルを choice で判定する。候補は codex と claude 両方。確信度 0.5 以下・鍵なし・HTTP 失敗・3秒超過・マスキング失敗のときは `fallback/<backend>.txt`（候補 backend の順で最初に値があるもの）を使う。
- 指示ファイルの原文は Jev に送らない（マスキング済み本文のみ）。接続先は `api.typesafe.ai` に固定し、鍵の値と原文はログ・出力に書かない。

## バックエンド

`impl-exec.sh` は選ばれた backend に応じて、`lib.sh` の実行関数を直接呼んで codex（`codex exec -C <work_dir>`）か claude（`claude -p --agent impl --model <model>`）を起動する。`impl-exec.sh` がモデル判定・2回失敗時の切替・backend ごとの実行をまとめて担う。claude は cwd を変えず、作業対象 worktree・inputs・追加資料ディレクトリを `--add-dir` で渡す。impl エージェントは書き込みとコミットを許可し、検証コマンド（テスト・lint・ビルド・アプリ起動）の実行を禁止する。

## LLM 切替（impl のみ）

同じ backend で2回連続して非0終了（`DELEGATE_PERMISSION_OUT_OF_SCOPE` を除く）したら、`fallback/<backend>.txt` のもう一方の backend のモデルで、同じ worktree・同じ指示ファイルのまま再実行する（指示文は追加しない）。1回目の失敗後は同じモデルでもう1回実行する。

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
