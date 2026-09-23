# forge 명령 사전

이 프로젝트의 이슈 추적·코드 리뷰 시스템과 그 명령을 적는다.

**이 파일은 harness.toml 에서 생성된다. 직접 고치지 않는다** — `[forge]` 를 바꾸고
`harness render` 를 돌리면 이 사전이 다시 만들어진다. 명령이 실제 어댑터와 갈라질 수 없다.

역할 계약(`.ai/templates/`)과 절차(`.ai/workflows/`)는 이 파일을 참조할 뿐 명령을 직접 적지 않는다.

## 이 프로젝트의 forge

| 항목 | 값 |
|---|---|
| 이슈 추적 | {{FORGE_TRACKER}} (`{{FORGE_TRACKER_CLI}}`) |
| 코드 리뷰 | {{FORGE_REVIEW_HOST}} (`{{FORGE_REVIEW_CLI}}`) |
| 리뷰 대상 브랜치 | `{{BASE_BRANCH}}` |

## 용어

이 리포의 모든 문서에서 **MR** 은 "리뷰 요청 단위" 를 뜻한다. GitHub 에서는 PR 이 그것이다 —
문서를 고치지 않고 이 줄로 대응한다.

## 스크립트에서 쓸 때

셸에서 조회·조작이 필요하면 **명령을 직접 부르지 않고 어댑터 함수를 쓴다.**
forge 를 바꿔도 부르는 쪽이 그대로 돌고, 페이지네이션과 응답 형태 차이를 어댑터가 흡수한다.

```bash
. "$(git rev-parse --show-toplevel)/script/forge.sh"
review_mr_threads 12          # 정규화 JSON 으로 돌아온다
```

함수 목록과 출력 계약은 `script/forge/_common.sh` 상단에 있다.

## 쓰기 권한

이슈·리뷰 요청 생성과 댓글 등록은 **사용자가 명시적으로 지시한 턴에서만** 한다.
머지와 이슈 종료는 어떤 경우에도 하지 않는다.
