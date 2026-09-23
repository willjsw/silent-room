#!/usr/bin/env sh
# 사용 기록에 남길 수 있는 어휘의 정본. usage-log.sh(기록)와 usage-report.sh(집계)가 함께 읽는다.
#
# 기록과 집계가 각자 판단하면 한쪽이 거르지 못한 값이 다른 쪽 출력에 그대로 나온다.
# 통과 목록을 한 곳에 두고 양쪽이 같은 것을 본다.
#
# 여기 없는 이벤트·출처는 other 로, 여기 없는 상세 토큰은 버려진다.
# 새 호출부를 붙일 때 이 목록에 먼저 추가한다.

# 이벤트 종류.
USAGE_EVENTS="block preflight review command note other"

# 기록을 남기는 호출부. test-caller 는 회귀 테스트가 쓴다.
USAGE_SOURCES="commit-msg pre-push pre-commit work-preflight review-mr bash-guard test-caller other"

# 상세에 쓸 수 있는 고정 라벨.
USAGE_LABELS="open-mr mr-query-failed fetch-failed standalone spec-missing plan format protected-branch agent-sync force-push no-verify remote-delete arch-doc"

# 상세에 쓸 수 있는 키=값 의 `키:값정규식` 목록. **키마다 값 형식을 따로 정한다** —
# 값을 영숫자 일반으로 열어 두면 호출부가 잘못 넘긴 사람 이름·식별자가 그대로 기록에 남는다.
# 정규식은 awk ERE 로 평가하며 `:` 를 포함하지 않는다(키와 값을 그 문자로 가른다).
#
# mr    MR 번호 · round 리뷰 회차 · exit 종료 코드 — 모두 숫자다.
# stop  리뷰 루프가 멈춘 사유. mrl-cap = 회차 상한 도달 · repeat = 한 파일의 지적이 연속.
#       종료 코드 3 은 두 사유가 공유하므로 이것으로 가른다.
USAGE_KEY_SPECS="mr:^[0-9]+$ round:^[0-9]+$ exit:^[0-9]+$ stop:^(mrl-cap|repeat)$"

usage_vocab_has() {
  _needle="$2"
  for _item in $1; do
    [ "$_item" = "$_needle" ] && return 0
  done
  return 1
}
