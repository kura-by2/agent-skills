#!/usr/bin/env bash
# 移動先が存在しないときだけ git mv する（上書き・既存ディレクトリ内への移動を防ぐ）。
# usage: git-mv.sh <src> <dst>   相対パスはカレントディレクトリ基準。
set -eu
[ $# -eq 2 ] || { echo "usage: git-mv.sh <src> <dst>" >&2; exit 2; }
abs() { case $1 in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
src=$(abs "$1") dst=$(abs "$2")
[ -e "$src" ] || [ -L "$src" ] || { echo "移動元が存在しない: $1" >&2; exit 1; }
if [ -e "$dst" ] || [ -L "$dst" ]; then
  echo "移動先が既に存在する: $2" >&2
  echo "中身を確認すること。既存ディレクトリの中へ入れる意図なら、移動後のフルパス（$2/<name>）を指定する。" >&2
  exit 1
fi
[ -d "$(dirname -- "$dst")" ] || { echo "移動先の親ディレクトリが存在しない: $(dirname -- "$2")" >&2; exit 1; }
git -C "$(dirname -- "$src")" mv -- "$src" "$dst"
echo "git moved: $1 -> $2"
