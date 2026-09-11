#!/bin/bash
# Usage: scan-commands.sh [targets.md path]
# targets.md の target（複数可）配下の日付別ログ(<date>.log)を lookback_days 範囲で読み、
# 引数の揺れ（パス・日付・連番・slug等）を正規化したうえで
#   1) 繰り返されているコマンド（正規化シグネチャの頻度）
#   2) 繰り返されている手順（連続するコマンド列）
# を抽出して出力する。スキル化／スクリプト化候補の検出を補助する「ざっくり版」。
#
# 正規化の考え方（完璧な精度は不要）:
#   - 各行を && / || / ; でサブコマンドに分割し、空白でトークン分離する
#   - フラグ(-x) / 代入(KEY=val) / リダイレクト(2>&1 等) / 数値 / 日付 / クォート文字列 は捨てる
#   - パスは basename にし、スクリプト(.sh/.py/...)だけ残す（操作の同一性）。データパスは捨てる
#   - 先頭(プログラム名) + スクリプト名 + サブコマンド的な純アルファベット語 だけをシグネチャにする
#   これにより `bash /a/save-context.sh foo /tmp/x.md` と `bash /b/save-context.sh bar ...`
#   は同じ `bash save-context.sh` に畳まれ、繰り返しが浮上する。
set -euo pipefail

TARGETS="${1:-$(dirname "$0")/../targets.md}"
MINOCC=2   # この回数以上だけ候補として出す

# "key:" に続く "  - value" の列挙を取り出す
get_list() {
  awk -v key="$1:" '$0==key{f=1;next} f&&/^[[:space:]]+- /{sub(/^[[:space:]]*- /,"");gsub(/"/,"");print;next} f&&/^[^[:space:]]/{f=0}' "$TARGETS"
}
# "key: value" の単一値を取り出す
get_val() {
  grep -E "^$1:" "$TARGETS" | head -1 | awk '{print $2}'
}

LOOKBACK=$(get_val lookback_days); LOOKBACK=${LOOKBACK:-30}

# target を1つずつ解決し、存在するディレクトリだけを集める
mapfile -t TARGET_DIRS < <(get_list target)
VALID_DIRS=()
for dir in "${TARGET_DIRS[@]}"; do
  [ -z "$dir" ] && continue
  dir="${dir/#\~/$HOME}"
  [[ "$dir" = /* ]] || dir="${CLAUDE_PROJECT_DIR:?}/$dir"
  if [ -d "$dir" ]; then
    VALID_DIRS+=("$dir")
  else
    echo "skip: $dir (not found)" >&2
  fi
done

if [ "${#VALID_DIRS[@]}" -eq 0 ]; then
  echo "target ディレクトリが見つかりません" >&2
  exit 0
fi

# lookback 範囲の日付別ログを収集
mapfile -t FILES < <(find "${VALID_DIRS[@]}" -type f -name '*.log' -mtime -"$LOOKBACK" | sort)
if [ "${#FILES[@]}" -eq 0 ]; then
  echo "対象ログが見つかりません" >&2
  exit 0
fi

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

# 正規化・頻度集計・手順(連続列)集計を awk で行う。
# 出力(中間): "C<TAB>count<TAB>sig"（コマンド） / "S<TAB>count<TAB>seq"（手順, \x02区切り）
awk -v MIN="$MINOCC" '
function basename_(p,  a,n){ n=split(p,a,"/"); return (a[n]!="" ? a[n] : a[n-1]) }
function is_script(t){ return t ~ /\.(sh|py|rb|js|ts|pl|sql)$/ }
# 1サブコマンド -> 正規化シグネチャ（空文字なら無視）
function normcmd(cmd,  parts,np,i,t,bt,sig){
  np=split(cmd,parts," ")
  # 先頭がシェル制御キーワードのサブコマンド(for/if/...)はノイズなので捨てる
  if(parts[1] ~ /^(for|do|done|if|then|fi|else|elif|while|in|case|esac)$/) return ""
  sig=""
  for(i=1;i<=np;i++){
    t=parts[i]
    if(t=="") continue
    if(t=="|") break                                        # パイプ以降は別コマンド扱い（先頭のみ見る）
    if(t ~ /^-/) continue                                   # フラグ
    if(t ~ /^[A-Za-z_][A-Za-z0-9_]*=/) continue             # KEY=val
    if(t ~ /^[0-9]*[<>]/) continue                          # リダイレクト 2>&1, >/dev/null 等
    if(t=="&&" || t=="||" || t==";") continue
    if(t ~ /^["'\'']/) continue                             # クォート開始（文字列引数）
    if(t ~ /^[0-9]+$/) continue                             # 純数値
    if(t ~ /[0-9]{4}-[0-9]{2}-[0-9]{2}/) continue           # 日付
    if(t ~ /\//){ bt=basename_(t); if(is_script(bt)) t=bt; else continue }  # パス: スクリプトのみ残す
    if(sig==""){                                            # プログラム名は必ず残す
      sig=t
      if(t=="echo") break                                   # echo の引数はノイズなので見ない
      continue
    }
    if(is_script(t) || t ~ /^[a-z][a-z]*$/) sig=sig " " t    # スクリプト名 or サブコマンド語のみ
    # それ以外（slug/ファイル名等の引数）は捨てる
  }
  return sig
}
function record(sig){
  if(sig=="") return
  cnt[sig]++                                                # 単体コマンド頻度
  if(index(sig," ")==0) return                              # 1語(grep/cat等)は手順の連結に使わない
  # 直近2件と連結して bigram / trigram を作る（ファイル内のみ）
  if(p1!=""){ seq[p1 SEP sig]++; if(p2!="") seq[p2 SEP p1 SEP sig]++ }
  p2=p1; p1=sig
}
BEGIN{ SEP=sprintf("%c",2) }
FNR==1{ p1=""; p2="" }                                       # ファイル境界で手順チェーンをリセット
/scan-commands\.sh/{ next }                                  # 監査自身のスキャン行は除外
{
  line=$0
  gsub(/ *&& */, SEP, line); gsub(/ *\|\| */, SEP, line); gsub(/ *; */, SEP, line)
  n=split(line, sub_, SEP)
  for(j=1;j<=n;j++) record(normcmd(sub_[j]))
}
END{
  # 単発の最小コマンド(1語: ls/cat/grep等)は畳めないので除外し、意味のあるものだけ出す
  for(s in cnt) if(cnt[s]>=MIN && index(s," ")>0) printf "C\t%d\t%s\n", cnt[s], s
  for(k in seq) if(seq[k]>=MIN) printf "S\t%d\t%s\n", seq[k], k
}
' "${FILES[@]}" > "$TMP"

echo "## 繰り返しコマンド（引数正規化, ${MINOCC}回以上）"
cmds=$(grep '^C' "$TMP" | sort -t$'\t' -k2,2nr -k3,3 | sed 's/^C\t//' || true)
[ -n "$cmds" ] && printf '%s\n' "$cmds" || echo "(なし)"

echo
echo "## 繰り返し手順（連続コマンド列, ${MINOCC}回以上）"
seqs=$(grep '^S' "$TMP" | sort -t$'\t' -k2,2nr | sed 's/^S\t//' | sed $'s/\x02/ » /g' || true)
[ -n "$seqs" ] && printf '%s\n' "$seqs" || echo "(なし)"
