#!/bin/bash
# 최신 버전으로 업데이트 (git pull) 하면서 내 로컬 기록은 지킨다.
#
# 순서
#   1. 바뀐 파일·새 파일을 .local-backup/<시각>/ 에 그대로 복사 (안전망)
#   2. git stash 로 잠시 치워 두기
#   3. git pull (fast-forward 만)
#   4. git stash pop 으로 내 변경 되돌리기
#      - 같은 파일을 양쪽에서 고쳐 충돌하면: 내 버전을 유지하고,
#        새 버전은 .local-backup/<시각>/upstream/<경로> 에 남긴다.
#   5. 결과 요약 출력. 마지막 줄은 RESULT=ok | RESULT=conflict | RESULT=fail
#
# 사용법: ./update.sh

set -u
cd "$(dirname "$0")" || exit 1

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP=".local-backup/$TS"
STASH_MSG="auto-update $TS"

say()  { printf '%s\n' "$*"; }
STASHED=0
fail() {
  say "❌ $*"
  # 치워 둔 변경이 남아 있으면 되돌려 놓는다
  if [ "$STASHED" -eq 1 ] && git stash list --format='%s' | grep -qF "$STASH_MSG"; then
    ref="$(git stash list --format='%gd %s' | grep -F "$STASH_MSG" | head -1 | cut -d' ' -f1)"
    git stash pop --quiet "$ref" 2>/dev/null && say "   로컬 변경은 원래대로 되돌렸어요." \
      || say "   로컬 변경은 백업 폴더($BACKUP/local)와 git stash에 그대로 있어요. 지워지지 않았어요."
  fi
  say "RESULT=fail"; exit 1
}

# ---------- 0. 사전 점검
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "git 폴더가 아니에요."
GITDIR="$(git rev-parse --git-dir)"
[ -d "$GITDIR/rebase-merge" ] || [ -d "$GITDIR/rebase-apply" ] || [ -f "$GITDIR/MERGE_HEAD" ] \
  && fail "이전 git 작업(merge/rebase)이 끝나지 않은 상태예요. 개발자에게 확인이 필요해요."
BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null)" || fail "브랜치가 아닌 상태(detached HEAD)예요."
UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" \
  || fail "'$BRANCH' 브랜치에 연결된 원격 브랜치가 없어요."

say "🔄 최신 버전 확인 중… ($UPSTREAM)"
git fetch --quiet || fail "인터넷 연결이나 GitHub 접근을 확인해 주세요. 아무것도 바꾸지 않았어요."

BEHIND="$(git rev-list --count HEAD.."$UPSTREAM")"
AHEAD="$(git rev-list --count "$UPSTREAM"..HEAD)"
[ "$AHEAD" -gt 0 ] && fail "이 컴퓨터에 아직 올리지 않은 커밋이 ${AHEAD}개 있어요. 자동 업데이트를 멈췄어요. 아무것도 바꾸지 않았어요."
if [ "$BEHIND" -eq 0 ]; then
  say "✅ 이미 최신 버전이에요. 바꾼 것 없음."
  say "RESULT=ok"
  exit 0
fi

# ---------- 1. 로컬 변경 백업
CHANGED="$(git status --porcelain=v1 --untracked-files=all | grep -v '^!!')"
HAS_LOCAL=0
if [ -n "$CHANGED" ]; then
  HAS_LOCAL=1
  mkdir -p "$BACKUP/local"
  # 수정·추가된 파일 + 새 파일 (삭제된 파일은 복사할 게 없음)
  { git diff --name-only HEAD; git ls-files --others --exclude-standard; } | sort -u | while IFS= read -r f; do
    [ -f "$f" ] || continue
    mkdir -p "$BACKUP/local/$(dirname "$f")"
    cp -p "$f" "$BACKUP/local/$f"
  done
  printf '%s\n' "$CHANGED" > "$BACKUP/status.txt"
  say "💾 내 로컬 변경 $(printf '%s\n' "$CHANGED" | wc -l | tr -d ' ')개를 백업했어요: $BACKUP/local"

  # ---------- 2. stash
  git stash push --include-untracked --quiet -m "$STASH_MSG" && STASHED=1 || fail "로컬 변경을 잠시 치우는(stash) 데 실패했어요. 아무것도 바꾸지 않았어요. 백업: $BACKUP"
fi

# ---------- 3. pull
OLD_HEAD="$(git rev-parse HEAD)"
git merge --ff-only --quiet "$UPSTREAM" || fail "업데이트를 받지 못했어요."
say "⬇️  새 버전 ${BEHIND}개 커밋을 받았어요."
git --no-pager log --oneline "$OLD_HEAD"..HEAD | sed 's/^/     · /'

if [ "$HAS_LOCAL" -eq 0 ]; then
  say "✅ 업데이트 완료. 로컬 변경은 없었어요."
  say "RESULT=ok"
  exit 0
fi

# ---------- 4. stash pop (내 변경 되돌리기)
STASH_REF="$(git stash list --format='%gd %s' | grep -F "$STASH_MSG" | head -1 | cut -d' ' -f1)"
[ -n "$STASH_REF" ] || fail "치워 둔 변경(stash)을 찾지 못했어요. 백업에서 복구해야 해요: $BACKUP/local"

if git stash pop --quiet "$STASH_REF" >/dev/null 2>&1; then
  say "✅ 업데이트 완료. 내 로컬 변경도 그대로 되돌렸어요."
  say "RESULT=ok"
  exit 0
fi

# ---------- 4-1. 충돌 처리: 내 버전 유지, 새 버전은 백업 폴더에 보관
CONFLICTS="$(git diff --name-only --diff-filter=U)"
for f in $CONFLICTS; do
  mkdir -p "$BACKUP/upstream/$(dirname "$f")"
  git show "HEAD:$f" > "$BACKUP/upstream/$f" 2>/dev/null
  git checkout --theirs -- "$f"      # stash pop 에서 theirs = 내 로컬 변경
done

# 내가 새로 만든 파일(untracked)과 같은 이름의 파일이 새 버전에 생겨 복원이 안 된 경우:
# 내 파일을 되살리고, 새 버전 파일은 백업 폴더에 둔다
RESTORE_MISSED=""
if git rev-parse --verify --quiet "$STASH_REF^3" >/dev/null; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if ! git show "$STASH_REF^3:$f" 2>/dev/null | cmp -s - "$f"; then
      if git cat-file -e "HEAD:$f" 2>/dev/null; then
        mkdir -p "$BACKUP/upstream/$(dirname "$f")"
        git show "HEAD:$f" > "$BACKUP/upstream/$f"
      fi
      mkdir -p "$(dirname "$f")"
      git show "$STASH_REF^3:$f" > "$f"
      RESTORE_MISSED="$RESTORE_MISSED $f"
    fi
  done < <(git ls-tree -r --name-only "$STASH_REF^3")
fi

git reset --quiet                     # 스테이징 해제, 파일 내용은 그대로
git stash drop --quiet "$STASH_REF" 2>/dev/null || true

ALL_CONFLICTS="$(printf '%s\n' $CONFLICTS $RESTORE_MISSED | sort -u | grep -v '^$')"
say "⚠️  업데이트는 받았고 내 로컬 변경도 되돌렸어요."
say "    다만 아래 파일은 새 버전에서도 바뀌어서, 일단 내 버전을 유지했어요."
say "    새 버전 내용은 $BACKUP/upstream/ 에 있어요. 두 내용을 합쳐야 해요."
printf '%s\n' "$ALL_CONFLICTS" | sed 's/^/     · /'
say "BACKUP=$BACKUP"
say "RESULT=conflict"
exit 0
