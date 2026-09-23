#!/usr/bin/env sh
# 기계가 읽는 문자열의 정본. 리뷰 본문·MR 본문·이슈 본문에서 스크립트가 찾는 표지를 모은다.
#
# **왜 한 곳인가.** 이 문자열들은 쓰는 쪽(역할 계약과 양식)과 읽는 쪽(스크립트)이 다르다.
# 각자 자기 파일에 적으면 한쪽만 고쳐져 파서가 조용히 빈 결과를 내거나 계약 위반으로 멈춘다.
# 여기 두고 양쪽이 같은 것을 보게 한다. `script/test-review-loop.sh` 가 계약 문서와의 일치를 검사한다.
#
# **설정이 아니다.** 프로젝트마다 달라지는 값이 아니라 하네스의 형식 규약이다.
# 바꾸려면 여기와 `.ai/templates/code-reviewer.md`·`.ai/templates/mr.md`·
# `.ai/templates/issue-task.md` 를 같은 커밋에서 함께 고친다.
#
# 이 파일은 source 전용이다. 직접 실행하지 않는다.

# ── 리뷰 본문 (리뷰어가 쓰고 post-review.sh 가 읽는다) ───────────────────────
FMT_FINDINGS_HEADING='## 발견 사항'
FMT_FINDINGS_LEVEL=2
FMT_NO_FINDINGS='발견 사항 없음'
FMT_VERDICT_PASS='REVIEW_VERDICT: PASS'
FMT_VERDICT_CHANGES='REVIEW_VERDICT: CHANGES_REQUESTED'
FMT_OUT_OF_SCOPE='범위 밖 — 이월 필요'

# 판정에 넣고 인라인으로 다는 심각도. minor 는 소음이 판정을 묻으므로 뺀다.
FMT_INLINE_SEVERITIES='blocker major'

# 파일:라인을 적지 않은 발견이 반복 집계에서 차지하는 자리.
FMT_NO_LOCATION='(파일 미지정)'

# ── 등록 노트 (post-review.sh 가 쓰고 review-mr.sh 가 다음 회차에 읽는다) ────
FMT_SUMMARY_HEADING='## 자동 리뷰 결과'
FMT_REVIEWED_HEAD='리뷰 시점 head'

# ── MR 본문 (`.ai/templates/mr.md` 의 절 제목. review-mr.sh 가 리뷰 맥락으로 넘긴다) ──
FMT_MR_PURPOSE='변경 목적'
FMT_MR_REVIEW_POINTS='리뷰 요청 포인트'
FMT_MR_CLOSES='Closes'

# ── 이슈 본문 (`.ai/templates/issue-task.md` 의 절 제목) ─────────────────────
FMT_ISSUE_WORK='작업 내용'
FMT_ISSUE_RELATES='relates to'

# 분해 파일에서 task 절을 가르는 머리글. `.ai/templates/planner.md` 가 이 형식을 지시한다.
FMT_TASK_HEADING='^## (T[0-9]+) · (.+)$'
