#!/usr/bin/env bash
# 이슈 하나에 대해 구현 착수가 가능한지 판정하고, 가능하면 어느 경로인지 출력한다.
#
#   script/work-preflight.sh <이슈번호>
#
# 출력(stdout): `plan` = 분해가 있는 경로 · `standalone` = 분해 없는 단독 task
# 종료 코드: 0 = 착수 가능 · 1 = 착수 불가(사유를 stderr 로) · 2 = 실행 실패
#
# **착수 전과 구현 위임 직전에 같은 명령을 돌린다.** 판정을 두 곳에 따로 적으면 한쪽에 검사를
# 더할 때 다른 쪽이 낡는다. 두 결과가 다르면 그 사이에 원격이 바뀐 것이므로 위임하지 않는다.
#
# 검사 순서가 결과를 바꾼다. 열린 리뷰 요청을 먼저 본다 — 두 검사 사이에 spec+plan 이 머지되면
# 분해를 먼저 본 경우 "분해 없음 + 열린 것 없음" 이 되어 단독 task 로 오판한다.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
root=$(pwd)
. script/harness.env

if [ $# -ne 1 ]; then echo "usage: script/work-preflight.sh <issue-number>" >&2; exit 2; fi
issue="$1"

log() { "$root/script/usage-log.sh" preflight work-preflight "$1" || true; }

# ① 열린 리뷰 요청 — 있으면 착수하지 않는다.
set +e
open_mrs=$(script/check-open-mrs.sh "$issue")
rc=$?
set -e
case "$rc" in
  0) ;;
  1) log open-mr
     echo "stop: issue $issue already has an open review request ($open_mrs)" >&2
     echo "  it is either a spec+plan awaiting approval or an implementation already in flight" >&2
     exit 1 ;;
  *) log mr-query-failed
     exit 2 ;;
esac

# ② 분해 — 로컬 작업 트리가 아니라 방금 fetch 한 원격의 통합 브랜치를 읽는다.
#    승인된 분해로만 착수가 열린다는 게이트를 이 스크립트가 지킨다.
git fetch -q origin "$BASE_BRANCH" || {
  log fetch-failed
  echo "stop: git fetch failed — refusing to decide from a stale ref" >&2
  exit 2
}

if ! git cat-file -e "FETCH_HEAD:docs/plan/$issue/task.md" 2>/dev/null; then
  log standalone
  echo "standalone"
  exit 0
fi

# ③ 분해가 있으면 그것이 근거로 삼는 명세도 있어야 한다.
#    명세가 지워지거나 이름이 바뀌면 분해만 남고, 완료 조건의 근거가 가리키는 곳이 없어진다.
if ! git ls-tree --name-only FETCH_HEAD docs/spec/ | grep -q "^docs/spec/$issue-"; then
  log spec-missing
  echo "stop: docs/plan/$issue/ has a breakdown but no matching spec at docs/spec/$issue-*.md" >&2
  echo "help: the completion criteria point at nothing — run prework to settle the spec first" >&2
  exit 1
fi

log plan
echo "plan"
