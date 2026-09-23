#!/usr/bin/env bash
# 이 프로젝트의 검증. **프로젝트 소유 파일이다** — 하네스 갱신이 덮지 않는다.
#
# `script/run-lint-test.sh` 가 하네스 검사를 마친 뒤 이것을 부른다.
# 하나라도 실패하면 0이 아닌 종료 코드로 끝낸다.
#
# 순서가 중요하다. **계층 의존 검사를 포맷·테스트보다 먼저 둔다** — 싸고, 위반이면
# 어차피 설계를 고쳐야 한다. 포맷 위반은 자동 수정으로 끝나지만 의존 위반은 아니다.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# 계층 의존 규칙. 기준은 `.ai/project/architecture.md` 가 갖는다.
#
# 손으로 돌리는 grep 을 문서에 적지 말고 여기 넣는다 — 문서에 적힌 검사는 아무도 돌리지 않고,
# 여기 넣으면 커밋 직후와 CI 가 대신 돌린다. 형태는 이렇다.
#
#   if grep -rn --include='*.java' -E '^import (org\.springframework|lombok)\.' src/main/java/**/domain/; then
#     echo "error: domain layer must not import a framework" >&2
#     exit 1
#   fi
#
# <!-- TBD: 이 프로젝트의 의존 검사를 채운다 -->

# 포맷 검사와 테스트. 명령은 `.ai/project/commands.md` 가 갖는다.
# <!-- TBD: 이 프로젝트의 lint·test 명령을 채운다 -->

# 설치 직후에는 여기서 멈추는 것이 정상이다. 프로젝트 검증을 채워야 검증 루프가 완성된다.
echo "verify-project: not filled in yet" >&2
echo "help: put the lint and test commands from .ai/project/commands.md and the dependency check from architecture.md here" >&2
exit 1
