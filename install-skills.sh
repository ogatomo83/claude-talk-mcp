#!/bin/sh
# claude-talk-mcp の skill を ~/.claude/skills に配置する。
#
#   curl -fsSL https://raw.githubusercontent.com/ogatomo83/claude-talk-mcp/main/install-skills.sh | sh
#
# リポジトリを clone 済みなら、そのまま `./install-skills.sh` でもよい（ローカルの
# skills/ をコピーする。ダウンロードはしない）。
#
# 環境変数:
#   SKILLS_DIR   配置先          (既定: ~/.claude/skills)
#   REPO         GitHub の owner/name (既定: ogatomo83/claude-talk-mcp)
#   REF          ブランチ / タグ (既定: main)
#   SKILLS       入れる skill 名をスペース区切りで (既定: voice)

set -eu

REPO="${REPO:-ogatomo83/claude-talk-mcp}"
REF="${REF:-main}"
SKILLS_DIR="${SKILLS_DIR:-$HOME/.claude/skills}"
SKILLS="${SKILLS:-voice}"

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# skills/ の在り処を決める。スクリプトと同階層にあればローカル、なければ tarball を取得。
src_root=''
case "$0" in
  */*) script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) ;;
  *)   script_dir='' ;;
esac

if [ -n "$script_dir" ] && [ -d "$script_dir/skills" ]; then
  src_root="$script_dir"
  say "==> ローカルの skills/ を使います: $src_root/skills"
else
  command -v curl >/dev/null 2>&1 || die "curl が見つかりません"
  tmp=$(mktemp -d) || die "作業ディレクトリを作れません"
  trap 'rm -rf "$tmp"' EXIT INT TERM

  say "==> $REPO@$REF を取得します"
  curl -fsSL "https://codeload.github.com/$REPO/tar.gz/$REF" \
    | tar xz -C "$tmp" --strip-components=1 \
    || die "取得に失敗しました ($REPO@$REF)"
  src_root="$tmp"
fi

[ -d "$src_root/skills" ] || die "skills/ が見つかりません"

mkdir -p "$SKILLS_DIR"

installed=0
for skill in $SKILLS; do
  src="$src_root/skills/$skill"
  dest="$SKILLS_DIR/$skill"

  [ -f "$src/SKILL.md" ] || die "skill '$skill' が見つかりません ($src/SKILL.md)"

  # 既存があり、中身が違うなら退避してから置き換える。
  if [ -e "$dest" ]; then
    if diff -qr "$src" "$dest" >/dev/null 2>&1; then
      say "==> $skill: 既に最新です"
      continue
    fi
    backup="$dest.bak.$(date +%Y%m%d%H%M%S)"
    mv "$dest" "$backup"
    say "==> $skill: 既存を退避しました -> $backup"
  fi

  mkdir -p "$dest"
  # ドットファイルも含めてコピーする。
  (cd "$src" && tar cf - .) | (cd "$dest" && tar xf -)
  say "==> $skill: 配置しました -> $dest"
  installed=$((installed + 1))
done

say ""
if [ "$installed" -gt 0 ]; then
  say "完了。Claude Code を再起動すると skill が読み込まれます。"
else
  say "変更はありませんでした。"
fi
say "voice skill は claude-talk MCP (speak / listen) が登録済みであることを前提にします。"
say "セットアップ: https://github.com/$REPO"
