#!/usr/bin/env bash
# 검증 일괄. 하나라도 실패하면 0이 아닌 종료 코드.
# 커밋 전 수동 실행, post-commit 훅에서 1회 자동 실행, CI 에서 실행.
#
# **하네스 검사와 프로젝트 검증을 나눈다.** 위쪽은 어느 리포에서나 같고, 아래쪽은
# `script/verify-project.sh` 가 갖는다 — 그 파일은 프로젝트 소유라 하네스 갱신이 덮지 않는다.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# 1) 생성물이 설정과 일치하는가. 어긋나면 훅·권한·에이전트 정의가 설정과 다른 것을 강제한다.
for cli in .harness/bin/harness bin/harness; do
  if [ -x "$cli" ]; then
    "$cli" check || exit 1
    break
  fi
done

# 2) 셸 회귀 테스트. 셸은 어느 포맷터도 보지 않으므로 여기서 돈다.
#    가드와 루프 제어는 조용히 망가져도 통과만 하므로 검사 없이는 고장을 알 수 없다.
#    원격도 리뷰 도구도 부르지 않는다 — 성공하면 마지막 줄만 남긴다.
for t in script/test-review-loop.sh script/test-carryover-issue.sh \
         script/test-bash-guard.sh script/test-usage-log.sh; do
  [ -x "$t" ] || continue
  log=$(mktemp)
  if ! "$t" > "$log" 2>&1; then
    cat "$log" >&2
    rm -f "$log"
    exit 1
  fi
  tail -1 "$log"
  rm -f "$log"
done

# 3) 프로젝트 검증 — 계층 의존 규칙·포맷·테스트. 내용은 프로젝트가 갖는다.
if [ -x script/verify-project.sh ]; then
  script/verify-project.sh || exit 1
else
  echo "warning: script/verify-project.sh is missing — project verification did not run" >&2
fi
