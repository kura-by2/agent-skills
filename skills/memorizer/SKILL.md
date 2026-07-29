---
name: memorizer
description: >
  コンテキスト管理スキル。作業コンテキストをトピック別ファイルに保存・ロード・一覧表示する。
  `/memorizer new <topic>` で空トピック作成、`/memorizer save [topic]` で保存、
  `/memorizer handoff <parent> <child>` で次フェーズ用トピックを作成、
  `/memorizer load <topic...>` でロード、`/memorizer list` で一覧、`/memorizer compact` で類似トピック統合、
  `/memorizer archive [days]` で未参照トピックをアーカイブに退避。
---

# Memorizer: コンテキスト管理

ファイル操作はすべて `{BASE_DIR}/scripts/` のスクリプトに集約されている。
スクリプトがコンテキストルートを `./memory/contexts/`（CWD基準）に固定するので、**手で .md を作成・移動しない。**
処理の詳細は各スクリプトを参照。

## 設計原則

**1トピック = 1つの具体的な問題・機能・目的。** 最小単位で管理し、必要なものを組み合わせてロードする。

```text
✗ auth                     ← 広すぎ
✓ auth-jwt-refresh         ← リフレッシュトークン設計
✓ auth-session-storage     ← セッション保存方式
```

## {topic}.md の構成

LLM が内容を埋めるセクション。各セクション最大5項目。

```markdown
---
topic: {topic}
updated: {date}
depends_on:       # 省略可。ロード時に依存先も読まれる
  - {topic-a}
parent: {topic}   # 省略可。フェーズ引き継ぎ元。ロード時はパス提示のみ
---

## 現在の状態      # 1〜3行。index の summary はここの最初の非空行
## 有効なルール・制約
## 決定事項
## 次のアクション
```

完結した決定・古い経緯は context-log に移す。ただし現在も有効なルール・制約はサマリーから消さない。

## context-log に記録する基準

`{topic}/context-log.md` はプロジェクト内側にしか無い情報の記録（明示時のみ読む）。

- **記録する:** 固有の制約／Xを除外した理由／試して失敗したこと／意思決定の背景／発見した仕様の特殊性／再発防止に要る過去の失敗と原因（＝そのプロジェクト固有の事実に限る）。
- **記録しない:** 公開ドキュメントの内容／一般的ベストプラクティス／再検索可能なエラー解決策／**自分（Claude）の行動ルール・作業手順の再発防止で次回も機械的に効かせたいもの**（context-log は明示ロード時しか読まれず強制力がない。これは `/persist-check` 経由で CLAUDE.md・hook・skill 更新へ落とす）。

---

## コマンド

### `/memorizer`（引数なし）— 初期化
`memory/contexts/index.md` を Read し、トピック一覧を表示する。無ければ「コンテキストなし」。

### `/memorizer new <topic>`
```bash
bash {BASE_DIR}/scripts/new-context.sh <topic>
```

### `/memorizer save [topic]`
1. `topic` 未指定なら会話からトピック名を推定（英小文字・ハイフン区切り）。既存への追記か新規かを判断。
2. 現在の作業を `{topic}.md` の構成に沿って要約し一時ファイルに書く。有効なルール・制約は残し、再発防止に要るルールを削らない。
   ```bash
   bash {BASE_DIR}/scripts/save-context.sh <topic> <body_tmp>
   ```
3. context-log に該当する内容（記録基準参照）があれば一時ファイルに書いて追記。無ければスキップ。
   ```bash
   bash {BASE_DIR}/scripts/append-log.sh <topic> <text_tmp>
   ```

### `/memorizer handoff <parent-topic> <child-topic>`
1. 既存の `parent-topic` から次フェーズ用の `child-topic` を新規作成する。
   ```bash
   bash {BASE_DIR}/scripts/handoff-context.sh <parent-topic> <child-topic>
   ```
2. 子トピック本文には、親の `## 決定事項` と `## 次のアクション` をスナップショットとして写す。子が単体で継続できるようにし、親へのライブ参照には依存しない。
3. 子トピックのフロントマターには `parent: <parent-topic>` を付ける。`parent:` は lazy なポインタで、親トピックの場所を示すだけ。親の退避はしない。

### `/memorizer load <topic...>`
```bash
bash {BASE_DIR}/scripts/load-context.sh <topic...>
```
出力された各パスを依存順に Read する。`PARENT:<topic>:<path>` は `topic` の親トピックのパス提示のみで、Read しない。親を読むのはユーザーが明示的に `/memorizer load <parent-topic>` を指示したときだけ。
`MISSING:<topic>` は `memory/contexts/archive/` を確認し、あれば復元をユーザーに確認のうえ戻して再ロード、無ければスキップを報告。
`merged_from` があるトピックは、列挙された旧トピックの `{old}/context-log.md` も context-log として扱う。
全トピックを3〜5行で要約し、ロードしたトピック一覧を表示する。

### `/memorizer list`
```bash
bash {BASE_DIR}/scripts/list-context.sh
```
出力された index.md（Markdownテーブル）をそのまま提示する。整形・要約しない。

### `/memorizer archive [days]`
```bash
bash {BASE_DIR}/scripts/archive.sh [days]
```
退避結果（件数・トピック名）を報告する。

### `/memorizer compact`
1. `index.md` と全 `{topic}.md` を Read し、重複・類似するトピック群（マージグループ）を特定する。
2. 各グループの内容を統合した本文（フロントマターに `merged_from:` で旧トピックを列挙）を一時ファイルに書いて新トピックを作成し、旧トピックに `merged_into` を付与する。
   ```bash
   bash {BASE_DIR}/scripts/save-context.sh <merged-topic> <body_tmp>
   bash {BASE_DIR}/scripts/mark-merged.sh <merged-topic> <old-topic...>
   ```
3. 統合グループ数と新トピック名を報告する。
