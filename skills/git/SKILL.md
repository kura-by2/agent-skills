---
name: git
description: >
  複数のgit worktreeを一括操作するスキル。worktreeの状態確認や特定コミットの検索で複数回コマンドを叩いているときに使う。
  `/git worktrees [dir]` で全worktreeのブランチ・ahead/behind・未追跡ファイルを一括表示。
  `/git find <hash> [dir]` で特定コミットが各worktreeに含まれるか検索。
  `/git untracked [dir]` でignoredを含むgit管理外ファイル・ディレクトリを一覧表示。
  `/git remove-worktree <branch|path>` でworktreeを削除（失敗時は自己判断で突破せずユーザー報告）。
  `/git mv <src> <dst>` で移動先が存在しないときだけ git mv する（既存なら失敗する）。
  以下のときに必ず使うこと：
  「git管理下のファイル・ディレクトリを移動・改名したい」→ `/git mv`
  「worktreeの状態を確認したい」「各ブランチのリモートとの差分を見たい」→ `/git worktrees`
  「このコミットがどのブランチに入っているか調べたい」→ `/git find`
  「ignoredを含むgit管理外ファイルを確認したい」→ `/git untracked`
  「worktreeを削除して」→ `/git remove-worktree`
---

# git: worktree一括操作

スクリプトは `scripts/` に同梱済み。スキル起動時に示されるベースディレクトリ（"Base directory for this skill: ..."）を使って実行する。

## `/git worktrees [dir]`

```bash
bash <base_dir>/scripts/worktrees.sh [dir]
```

- `dir` 省略時はカレントディレクトリ
- clean（ahead:0 behind:0 untracked:0）は `✓` で表示、それ以外は詳細を表示

## `/git find <hash> [dir]`

```bash
bash <base_dir>/scripts/find-commit.sh <hash> [dir]
```

- `hash` は前方一致（短縮形OK）
- `dir` 省略時はカレントディレクトリ
- 結果は `FOUND` / `none` で各worktreeごとに表示

## `/git untracked [dir]`

```bash
bash <base_dir>/scripts/untracked.sh [dir]
```

- `dir` 省略時はカレントディレクトリ
- ignoredを含むgit管理外ファイル・ディレクトリを一覧表示
- 対象は単一リポジトリ
- read-only

## `/git remove-worktree <branch|path>`

```bash
bash <base_dir>/scripts/remove-worktree.sh <branch|path>
```

- `branch` 指定時は worktree パスを自動解決
- 失敗したらユーザーに報告し、作業を中断する

## `/git mv <src> <dst>`

```bash
bash <base_dir>/scripts/git-mv.sh <src> <dst>
```

- 相対パスはカレントディレクトリ基準
- 移動先が既に存在する（上書き・既存ディレクトリの中への移動になる）場合は実行せずに失敗する
- 失敗したら移動先の中身を確認してユーザーに報告する。自己判断で移動先を消したり別名に逃がしたりしない
- 既存ディレクトリの中へ入れるのが意図どおりなら、移動後のフルパス（`<dst>/<name>`）を指定して実行し直す
