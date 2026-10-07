---
name: delegate-models
description: >
  委譲先モデル一覧（delegate-models.tsv）の鮮度を確認し、必要なら作り直すスキル。
  `/delegate-models` で実行する。委譲スキルが委譲の前にキックする。
---

# delegate-models

委譲先に渡せるモデルの一覧（`backend<TAB>model<TAB>summary`）を鮮度管理する。更新が必要なら作り直し、新しければ何もしない。委譲元・委譲スキルは、委譲の前にこのスキルを実行して一覧を最新に保つ。

## 置き場所

プロジェクトルートは `AGENT_PROJECT_DIR` → `CLAUDE_PROJECT_DIR` → カレントの git リポジトリルートの順で解決する。以下の `$AGENT_PROJECT_DIR` 表記はこの解決後のルートを指す。一覧とキャッシュは state 配下に置き、`.gitignore` で追跡しない。

- **モデル一覧（`$AGENT_PROJECT_DIR/state/delegate/delegate-models.tsv`）**: `backend<TAB>model<TAB>summary` の3列。
- **モデルキャッシュ（`$AGENT_PROJECT_DIR/state/delegate/.model-cache/<backend>-models.json`）**: 一覧の生成元（codex: `codex debug models` / claude: 公式 docs Markdown）。
- **要約モデル（`$AGENT_PROJECT_DIR/state/delegate/summary-model`）**: 要約に使うモデル名を1行で保存する。24時間固定。

## やること

`/delegate-models` を実行すると、まず要約に使うモデルを確保し、次に最終更新が1日以上前（または不在）のときだけ delegate-models.tsv を作り直す。新しければ何もしない。

要約モデルは24時間固定にし、`summary-model` が1日以上前（または不在）のときだけ選び直す。選び直しは固定の問い「要約するのに適切なモデルはどれ？」で Jev に判定させる。候補は claude backend のモデル（summarize.sh が claude で動くため）で、delegate-models.tsv があればその summary、まだ無ければモデルキャッシュの説明文を候補の説明に使う。確信度 0.6 未満や Jev 失敗のときは前回保存したモデル名をそのまま使う。前回値も無ければ、既定モデルへ倒さず `summary-model` にモデル名を書くよう促して非0終了する。

作り直すときは、backend（codex・claude）ごとに model-cache から退役していない利用可能モデルを取り、各モデルの1行要約を設定から隔離した claude（確保した要約モデル）で作る。要約に失敗したモデルはキャッシュ上の説明文を使う。キャッシュが1つも無ければ fail-closed（一覧を作らず非0終了）。既存の一覧が古くても、再生成に失敗したときは既存ファイルを残す。

要約には隔離した claude（空の作業ディレクトリ・`--setting-sources ''`・`--strict-mcp-config`）を使い、指示ファイル本文や鍵を外部に送らない。

## 実行コマンド

スキル起動時に示されるベースディレクトリ（"Base directory for this skill: ..."）を使って実行する。

```bash
bash {BASE_DIR}/scripts/delegate-models.sh
```
