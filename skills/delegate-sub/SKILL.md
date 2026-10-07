---
name: delegate-sub
description: >
  調査・現状把握・設計・トレードオフ比較を委譲先（claude の sub エージェント）に非同期で実行させるスキル。
  `/delegate-sub <work_dir_path>` の形式で呼ぶ。書き込みを伴わない作業を委譲する。
---

# delegate-sub

**何を調べる・設計するか**だけを伝え、実作業は委譲先に任せる。作業場所を指定し、非同期に実行させる。委譲先コマンドは常に `run_in_background: true` で Bash を呼んで起動し、呼び出し側は投入後すぐ sync 点に戻る。

## 委譲のスコープ

sub エージェントは書き込み不可。コード実装・修正・ファイル作成はさせない。完了条件は「応答本文での報告」だけにする（ファイル出力を求めない）。調査/現状把握/設計/トレードオフ比較など、書き込みを伴わない作業を委譲する。

## 委譲の粒度

1委譲は1関心事に絞る。独立して完結できる最小単位に分割し、複数の関心事を1つの指示ファイルに混ぜない。複数の関心事は指示ファイルを分けて並列投入する。1リポジトリは1委譲として扱う。

## 使い方

```
/delegate-sub <work_dir_path>
```

## モデルの決め方

- **モデル一覧（`scripts/llm-models/llm-models.json`）**: backend・model・description を持つオブジェクトの配列（claude は比較表の値を comparison オブジェクトでも持つ）。委譲の前に `scripts/llm-models/script.sh` を呼んで最新化する（失敗しても続行し、既存の一覧を使う）。一覧が不在なら Jev の候補が空になり、フォールバックへ倒れる。
- **フォールバック（自スキル配下の `scripts/fallback/sub.tsv`・git 追跡外）**: `backend<TAB>model`。24時間以上古い（または不在）のときだけ claude の1行を Jev の choice で作り直す。作り直しに失敗したら前回値をそのまま使い、前回値も無ければ fail-closed（どのファイルに何を書けば続行できるかを stderr に出す）。
- **委譲ごとの判定**: 指示ファイル本文を、要約用の共通スクリプトが選んだ要約モデルでマスキング（構成・作業内容・範囲・条件は残し、機密情報・固有名詞・パス・URL・識別子・コード・インシデント情報だけを伏せ字に置き換え、要約・圧縮はしない）し、そのマスキング済み本文を Jev に送って llm-models の中から使うモデルを choice で判定する。候補は claude のみ。確信度 0.5 以下・鍵なし・HTTP 失敗・3秒超過・マスキング失敗のときは `fallback/sub.tsv` を使う。
- 指示ファイルの原文は Jev に送らない（マスキング済み本文のみ）。接続先は `api.typesafe.ai` に固定し、鍵の値と原文はログ・出力に書かない。

## バックエンド

`claude-sub-exec.sh` は claude（`claude -p --agent sub --model <model>`）を起動する。cwd は変えず、作業対象 worktree・inputs・追加資料ディレクトリを `--add-dir` で渡す。sub エージェントは Edit/Write/MultiEdit を禁止する。

## 渡すべき情報

- **何を調べる・設計するか**（調査対象・設計判断の論点）
- **参照すべき既存コード・文書**（出発点があればそのパスと観点）

## 渡してはいけない情報

- 調査の手順・結論の先回り（委譲先が考える）
- ユーザー指示に含まれていない補足・拡大解釈の追加（指示は原発言の範囲で書き写す）

## 実行コマンド

複雑な指示をプロンプト直書きするとstdin読み込みでハングするため、指示ファイルに書いてから渡す。指示ファイルを書く前に委譲先エージェントの定義（`.claude/agents/sub.md`）で権限を確認し、完了条件を「応答本文での報告」に収める。

指示ファイルの作成は `scripts/write-input.sh <task_name> [inputs_dir]`（本文は stdin）を使う。汎用 Write/cat は sync 締切フックで止まるが、この専用ラッパは「委譲の下準備」として明示許可される。未指定時の作成先は `/tmp/delegate-inputs/`。

```bash
INPUTS_DIR=/tmp/delegate-inputs
bash {BASE_DIR}/scripts/write-input.sh <task> "$INPUTS_DIR" <<'EOF'
<指示本文>
EOF
```

### 追加資料の選定

委譲先に追加の参照資料を渡したい場合は、`amuro` スキルで関連するガイドラインを選定し、選定したファイルの絶対パスを1行1件で `$INPUTS_DIR/<task>-context.txt` に書き、実行スクリプトの第4引数に渡す。関連資料が無ければ第3引数までで実行する。

実行スクリプトは、スキル起動時に示されるベースディレクトリ（"Base directory for this skill: ..."）を使って実行する。指示ファイルは呼び出し元が指定した inputs ディレクトリに作成する。

```bash
INPUTS_DIR=/tmp/delegate-inputs
mkdir -p "$INPUTS_DIR"
bash {BASE_DIR}/scripts/claude-sub-exec.sh <work_dir_path> <task>.md "$INPUTS_DIR"

# 追加資料を選定した場合
bash {BASE_DIR}/scripts/claude-sub-exec.sh <work_dir_path> <task>.md "$INPUTS_DIR" "$INPUTS_DIR/<task>-context.txt"
```

Bash 呼び出しは常に `run_in_background: true` を指定する。

## 指示ファイルのテンプレート

`inputs/_template.md`（スキル同梱）を、指定した inputs ディレクトリの `<task>.md` にコピーして使う。該当するセクションは作業に即した内容を書き、該当しないセクション（書き込み・コミットなど sub が行わないもの）は `なし（理由: …）` と書く。テンプレの定型文をそのまま残さない。

## 失敗時の扱い

- 委譲先コマンドが非0終了・ハングした場合は、独自のワークアラウンドを探さず、ログと状況をユーザーに報告して判断を仰ぐ。
- 同じ指示での自動リトライはしない（自動モデル切替もしない）。
- `DELEGATE_PERMISSION_OUT_OF_SCOPE` で終了した場合、指示を修正する前に `.claude/agents/sub.md` と実行スクリプトを読んで原因を確定する。推測のまま同型の指示で再委譲しない。
