---
name: model-tiers
description: >
  委譲先モデル一覧（model-tiers.tsv）の鮮度を確認し、必要なら作り直すスキル。
  `/model-tiers` で実行する。委譲スキルが委譲の前にキックする。
---

# model-tiers

委譲先に渡せるモデルの一覧（`backend<TAB>model<TAB>summary`）を鮮度管理する。更新が必要なら作り直し、新しければ何もしない。委譲元・委譲スキルは、委譲の前にこのスキルを実行して一覧を最新に保つ。

## 置き場所

プロジェクトルートは `AGENT_PROJECT_DIR` → `CLAUDE_PROJECT_DIR` → カレントの git リポジトリルートの順で解決する。以下の `$AGENT_PROJECT_DIR` 表記はこの解決後のルートを指す。一覧とキャッシュは state 配下に置き、`.gitignore` で追跡しない。

- **モデル一覧（`$AGENT_PROJECT_DIR/state/delegate/model-tiers.tsv`）**: `backend<TAB>model<TAB>summary` の3列。
- **モデルキャッシュ（`$AGENT_PROJECT_DIR/state/delegate/.model-cache/<backend>-models.json`）**: 一覧の生成元（codex: `codex debug models` / claude: 公式 docs Markdown）。

## やること

`/model-tiers` を実行すると、最終更新が1日以上前（または不在）のときだけ model-tiers.tsv を作り直す。新しければ何もしない。

作り直すときは、backend（codex・claude）ごとに model-cache から退役していない利用可能モデルを取り、各モデルの1行要約を設定から隔離した `claude -p --model haiku` で作る。要約に失敗したモデルはキャッシュ上の説明文を使う。キャッシュが1つも無ければ fail-closed（一覧を作らず非0終了）。既存の一覧が古くても、再生成に失敗したときは既存ファイルを残す。

要約には隔離した claude（空の作業ディレクトリ・`--setting-sources ''`・`--strict-mcp-config`）を使い、指示ファイル本文や鍵を外部に送らない。

## 実行コマンド

スキル起動時に示されるベースディレクトリ（"Base directory for this skill: ..."）を使って実行する。

```bash
bash {BASE_DIR}/scripts/model-tiers.sh
```
