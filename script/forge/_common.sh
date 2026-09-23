#!/usr/bin/env sh
# forge 어댑터 계약과 기본 구현. `script/forge.sh` 가 이 파일과 선택된 어댑터를 source 한다.
#
# **이슈 트래커와 리뷰 호스트는 따로 고른다.** Jira 로 이슈를 관리하면서 GitHub 에서 리뷰할 수
# 있으므로 함수를 두 군으로 나눈다. 같은 forge 를 쓰면 어댑터 파일 하나가 둘 다 구현한다.
#
# 호출부(review-mr.sh 등)는 아래 함수만 쓴다. CLI 이름도 JSON 필드명도 알지 않는다.
#
# ── 이슈 트래커 ──────────────────────────────────────────────────────────────
#   tracker_require                         CLI 설치·인증 확인. 안 되면 종료 코드 2
#   tracker_issue_view <id>                 이슈 하나를 정규화 JSON 으로
#   tracker_issue_list                      열린·닫힌 이슈 전부를 정규화 JSON 배열로 (전 페이지)
#   tracker_issue_create <제목> <본문파일> <라벨> <담당자> <마일스톤>   → 만든 이슈의 id 한 줄
#   tracker_issue_note <id> <본문>          이슈 댓글 1건
#   tracker_current_user                    현재 사용자명 한 줄
#
# ── 리뷰 호스트 ──────────────────────────────────────────────────────────────
#   review_require                          CLI 설치·인증 확인
#   review_mr_view <n>                      리뷰 요청 하나를 정규화 JSON 으로
#   review_mr_diff <n>                      unified diff 를 stdout 으로
#   review_mr_labels_set <n> <붙일것> <뗄것>  공백 구분 목록. 빈 문자열 허용
#   review_mr_threads <n>                   리뷰 스레드 전수를 정규화 JSON 배열로
#   review_mr_note_inline <n> <파일> <줄> <본문>
#   review_mr_note_summary <n> <본문파일>
#   review_mr_list_open                     열린 리뷰 요청 전부를 정규화 JSON 배열로
#
# ── 정규화 JSON ──────────────────────────────────────────────────────────────
#   이슈   {"iid","title","state","description","labels":[],"assignee","milestone"}
#   리뷰   {"iid","source_branch","head_sha","description","labels":[],"state"}
#   스레드 [{"inline":bool,"path","line","notes":[{"body","created_at"}]}]
#          시스템 노트(라벨 변경·커밋 추가 안내)는 어댑터가 이미 걸러낸다.
#          페이지네이션도 어댑터가 끝까지 돈다 — 호출부는 전수를 받는다고 가정한다.
#
# 값이 없는 자리는 빈 문자열이고 키 자체를 빼지 않는다. 호출부가 키 유무를 따지지 않게 한다.
#
# 이 파일은 source 전용이다. 직접 실행하지 않는다.
set -u

forge_require() {
  tracker_require || return 2
  review_require || return 2
}

# 이슈 하나에 걸린 **열린** 리뷰 요청. 공백 구분 번호를 stdout 으로, 없으면 빈 줄.
#
# **forge 기능이 아니라 하네스 자신의 문법에서 도출한다.** 이슈 하나가 브랜치 하나·MR 하나이고
# 브랜치 이름과 MR 본문의 종료 참조가 고정 형식이므로, 열린 목록만 받으면 같은 답이 나온다.
# 이슈↔MR 연결을 직접 주는 forge 는 어댑터가 이 함수를 덮어쓴다.
harness_issue_open_mrs() {
  _id="$1"
  review_mr_list_open | python3 -c '
import json, re, sys

issue = sys.argv[1]
closes = sys.argv[2] or "Closes"
# 브랜치 이름: <태그>/<이슈>-<요약>. 종료 참조: <closes> <이슈참조>
branch = re.compile(r"^[A-Za-z]+/%s(?:[^0-9A-Za-z]|$)" % re.escape(issue))
body = re.compile(r"(?i)\b%s\s+\S*%s(?![0-9A-Za-z])" % (re.escape(closes), re.escape(issue)))

found = []
for mr in json.load(sys.stdin):
    if branch.match(mr.get("source_branch") or "") or body.search(mr.get("description") or ""):
        found.append(str(mr.get("iid")))
print(" ".join(found))
' "$_id" "${ISSUE_CLOSES_KEYWORD:-Closes}"
}
