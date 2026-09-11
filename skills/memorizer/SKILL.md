---
name: memorizer
description: >
  コンテキスト管理スキル。作業コンテキストをトピック別ファイルに保存・ロード・一覧表示する。
  `/memorizer new <topic>` で空トピック作成、`/memorizer save [topic]` で保存、
  `/memorizer handoff <parent> <child>` で次フェーズ用トピックを作成、
  `/memorizer load <topic...>` でロード、`/memorizer depended <topic...>` で依存先を補足読み、
  `/memorizer list` で一覧、`/memorizer compact` で類似トピック統合、
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
depends_on:       # 省略可。depended で補足読みされる
  - {topic-a}
goal_doc:         # 省略可。このトピックの不変ゴール・計画書の絶対パス。load 時に無条件で Read する。
  /absolute/path/to/plan.md
---

## 現在の状態      # 1〜3行。index の summary はここの最初の非空行
## 決定事項        # 現在も有効な制約・行動ルールもここに集約する
## 次のアクション
```

完結した決定・古い経緯は context-log に移す。ただし現在も有効な制約は `## 決定事項` から消さない。

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
2. 現在の作業を `{topic}.md` の構成に沿って要約し一時ファイルに書く。有効な制約も `## 決定事項` に含めて残し、再発防止に要るルールを削らない。既存トピックに旧「制約」節が残っていれば、その内容を `## 決定事項` へ寄せて節ごと畳む。
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
3. 子トピックのフロントマターには `depends_on:` で `<parent-topic>` を付ける。`depends_on:` は lazy なポインタで、`/memorizer depended` の補足読み対象になる。依存先の退避はしない。

### `/memorizer load <topic...>`
```bash
bash {BASE_DIR}/scripts/load-context.sh <topic...>
```
出力された通常のパスを Read する。depends_on は load では自動で読まない。
フロントマターに `goal_doc:` があれば、そのファイルを**無条件で Read** してゴールとして採用する。ゴールを固定した上で `## 決定事項`・`## 次のアクション` を実行前提として採用し、その後に要約・一覧提示へ進む。
`MISSING:<topic>` は `memory/contexts/archive/` を確認し、あれば復元をユーザーに確認のうえ戻して再ロード、無ければスキップを報告。
`merged_from` があるトピックは、列挙された旧トピックの `{old}/context-log.md` も context-log として扱う。
全トピックを3〜5行で要約し、ロードしたトピック一覧を表示する。
**要約・一覧提示で止めない。** `## 決定事項`・`## 次のアクション`・本文中の前提値（base ブランチ・命名/設計規約・実験の狙い等）を、以後の作業の「実行の前提」として採用する。以降そのセッションでは、context 内で答えが出る事項をユーザーへ聞き返さない（「どこを見るか」が context に書いてあるなら自分で特定する）。実環境（worktree 一覧・別の計画書など）と食い違う場合も、まず context 記載を正として突き合わせてから動き、食い違いの解消をユーザーへ丸投げしない。
ロードしたトピックの内容だけでは明らかに情報が不足している場合、`/memorizer depended <topic>` の実行をユーザーに推奨として提示する。
モデル判断で自発的に depended を実行して読むことは控えめにするが、必要な場合は許容する。

### `/memorizer depended [topic...]`
`topic` 未指定なら、このセッションでロード済みのトピック名をすべて渡す。
```bash
bash {BASE_DIR}/scripts/depended-context.sh <topic...>
```
出力された通常のパスを補足情報として Read する。起点トピック自身は出力されず、depends_on を再帰的にたどった依存先だけが出力される。
`MISSING:<topic>` は load と同様に扱う。

### `/memorizer list`
```bash
bash {BASE_DIR}/scripts/list-context.sh
```
出力結果を Markdown 表（topic / updated / summary）に整形して提示する。行の取捨選択・要約はしない。

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
