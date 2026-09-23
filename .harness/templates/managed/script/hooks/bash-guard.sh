#!/usr/bin/env sh
# PreToolUse(Bash) 훅. stdin 으로 오는 도구 호출 JSON 에서 실행될 명령을 꺼내
# _guards.sh 의 가드를 순서대로 돌린다. **명령이 실행되기 전에 판정한다.**
#
#   printf '{"tool_input":{"command":"git push origin main"}}' | script/hooks/bash-guard.sh
#
# 종료 코드: 0 = 통과 · 2 = 차단(사유를 stderr 로 낸다)
#
# 명령을 꺼내지 못하면 통과시킨다 — 입력 형식을 잘못 읽어 정상 작업을 막는 쪽이 더 나쁘다.
set -u

H=$(cd "$(dirname "$0")" && pwd)
GUARD_ROOT=$(cd "$H/../.." && pwd)
export GUARD_ROOT

# JSON 문자열 값에는 줄바꿈이 그대로 들어올 수 없으므로(\n 으로 이스케이프된다) 먼저 한 줄로 만든다.
# 그 뒤 "command" 의 값을 닫는 따옴표까지 — 이스케이프된 따옴표는 건너뛰고 — 잘라낸다.
CMD=$(tr -d '\n' | sed -E -n 's/.*"command"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p')
[ -n "$CMD" ] || exit 0

# 최소 언이스케이프. \n 은 줄바꿈 대신 공백으로 둔다 — 가드는 토큰 경계만 보므로 결과가 같고,
# 셸마다 다른 개행 치환 표기에 기대지 않는다.
CMD=$(printf '%s' "$CMD" | sed -e 's/\\"/"/g' -e 's/\\n/ /g' -e 's/\\t/ /g' -e 's/\\\\/\\/g')

# 히어독 본문은 실행될 명령이 아니라 표준 입력으로 흘러가는 텍스트다. 잘라내지 않으면
# 커밋 메시지나 이슈 본문에 적은 `--no-verify` 같은 말이 그 명령의 옵션으로 읽혀 막힌다.
# 그 안에 적힌 위험 명령을 놓치게 되지만, 그것은 실행이 아니라 글이다.
CMD=${CMD%%<<*}
export CMD

# 가드가 쓰는 값(보호 브랜치·보호 문서·forge CLI)은 설정에서 온다.
# **없으면 차단한다.** 목록을 읽지 못한 가드는 전부 통과시키는데, 그건 가드가 없는 것과 같다.
# 미탐을 허용한다는 원칙은 패턴이 놓치는 경우에 대한 것이지 규칙 자체를 잃는 경우가 아니다.
if [ ! -f "$GUARD_ROOT/script/harness.env" ]; then
  echo "blocked: cannot read the harness config at $GUARD_ROOT/script/harness.env, so the guards cannot run" >&2
  echo "help: passing everything through without the lists is the same as having no guard — run \`harness render\` to generate it, then retry" >&2
  exit 2
fi
. "$GUARD_ROOT/script/harness.env"

. "$H/_guards.sh"

guard_protected_branch
guard_force_push
guard_no_verify
guard_remote_delete
guard_arch_docs

exit 0
