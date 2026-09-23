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

# 1) 계층 의존 규칙. 기준은 `.ai/project/architecture.md` 가 갖는다.
#    domain 은 java.* 외 아무것도 import 하지 않는다.
domain=src/main/java/com/willjsw/silentroom/domain
if [ -d "$domain" ]; then
  offenders=$(grep -rn --include='*.java' '^import ' "$domain" \
    | grep -vE ':import (static )?java\.' || true)
  if [ -n "$offenders" ]; then
    echo "error: the domain layer may import only java.* — found:" >&2
    printf '%s\n' "$offenders" >&2
    exit 1
  fi
fi

# 2) 포맷 검사. 위반은 `./mvnw spotless:apply` 로 고친다.
./mvnw -q spotless:check

# 3) 테스트 전체.
./mvnw -q test
