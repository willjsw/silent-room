#!/usr/bin/env bash
# 이슈 하나에 연결된 **열린** 리뷰 요청을 조회한다.
#
#   script/check-open-mrs.sh <이슈번호>
#
# 종료 코드: 0 = 열린 리뷰 요청 없음 · 1 = 있음(번호를 출력) · 2 = 실행 실패
#
# 열린 리뷰 요청이 있으면 두 경우 중 하나이고 어느 쪽이든 착수하지 않는다.
#   - 분해가 없는데 열려 있다 → 승인 대기 중인 spec+plan 리뷰 요청일 수 있다
#   - 분해가 있는데 열려 있다 → 이미 이 이슈의 구현이 돌고 있다
#
# **제목을 문자열로 훑지 않는다.** 제목에 이슈가 둘 이상 들어가면 패턴이 빗나간다.
# 연결은 어댑터가 판정한다 — forge 가 이슈↔리뷰 요청 연결을 주면 그것을 쓰고,
# 주지 않으면 브랜치 이름과 본문의 종료 참조라는 하네스 자신의 문법으로 찾는다.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

if [ $# -ne 1 ]; then echo "usage: script/check-open-mrs.sh <issue-number>" >&2; exit 2; fi

. script/forge.sh
review_require || exit 2

opened=$(harness_issue_open_mrs "$1") || {
  echo "stop: could not query the review requests linked to issue $1" >&2
  exit 2
}

[ -n "${opened// /}" ] || exit 0
echo "$opened"
exit 1
