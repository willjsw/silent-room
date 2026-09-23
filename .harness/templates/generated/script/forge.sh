#!/usr/bin/env sh
# forge 어댑터 진입점. 이슈 트래커와 리뷰 호스트의 어댑터를 골라 source 한다.
#
# 이 파일은 harness.toml 에서 생성된다. 직접 고치지 않는다 —
# forge 선택은 harness.toml 의 [forge] 가 갖고, `harness render` 가 이 파일을 다시 만든다.
# 함수 계약과 구현은 `script/forge/` 아래에 있고 그쪽은 하네스가 관리한다.
#
# 호출부는 이 파일을 source 한 뒤 계약 함수만 쓴다. CLI 이름도 JSON 필드명도 알지 않는다.
#
#   . "$(git rev-parse --show-toplevel)/script/forge.sh"
#
# 이 파일은 source 전용이다. 직접 실행하지 않는다.

_forge_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "error: not inside a git repository" >&2
  return 2 2>/dev/null || exit 2
}

. "$_forge_root/script/forge/_common.sh"

# 한 어댑터 파일이 두 함수군을 모두 갖고 있으므로, 켤 군을 지정해 따로 source 한다.
_FORGE_WANT_TRACKER=1
_FORGE_WANT_REVIEW=0
. "$_forge_root/script/forge/{{FORGE_TRACKER}}.sh"

_FORGE_WANT_TRACKER=0
_FORGE_WANT_REVIEW=1
. "$_forge_root/script/forge/{{FORGE_REVIEW_HOST}}.sh"

unset _forge_root _FORGE_WANT_TRACKER _FORGE_WANT_REVIEW
