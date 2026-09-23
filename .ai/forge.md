# forge 명령 사전

이 프로젝트의 이슈 추적·코드 리뷰 시스템과 그 명령을 적는다.

**이 파일은 harness.toml 에서 생성된다. 직접 고치지 않는다** — `[forge]` 를 바꾸고
`harness render` 를 돌리면 이 사전이 다시 만들어진다. 명령이 실제 어댑터와 갈라질 수 없다.

역할 계약(`.ai/templates/`)과 절차(`.ai/workflows/`)는 이 파일을 참조할 뿐 명령을 직접 적지 않는다.

## 이 프로젝트의 forge

| 항목 | 값 |
|---|---|
| 이슈 추적 | github (`gh`) |
| 코드 리뷰 | github (`gh`) |
| 리뷰 대상 브랜치 | `develop` |

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
## 이슈 명령

| 하는 일 | 명령 |
|---|---|
| 이슈 조회 | `gh issue view <번호>` |
| 이슈 생성 | `gh issue create` |
| 이슈에 댓글 | `gh issue comment <번호> -b "<본문>"` |
| 현재 사용자명 | `gh api user -q .login` |

이슈 번호는 `#N` 으로 적는다.
이슈 본문 양식은 `.ai/templates/issue-requirement.md`(요구사항)·`.ai/templates/issue-task.md`(task).
## 리뷰 요청 명령

| 하는 일 | 명령 |
|---|---|
| PR 조회 | `gh pr view <번호>` |
| PR diff | `gh pr diff <번호>` |
| PR 라벨 | `gh pr edit <번호> --add-label <라벨>` |

PR 번호는 `#N` 으로 적는다. 이슈 번호와 같은 표기이므로 어느 쪽인지 문장에서 밝힌다.

### PR 생성

```bash
gh pr create --title "<제목>" --body-file <본문파일> \
  --base develop --assignee <username> --reviewer <username>
```

- 본문 자동 채움(`--fill`)을 쓰지 않는다 — 양식 항목이 누락된다.
- 본문 작성 규칙은 `.ai/templates/mr-guide.md`, 양식은 `.ai/templates/mr.md`.
- 담당자·리뷰어 기본값은 하네스 설정의 `mr.default_assignee`·`mr.default_reviewer` 다
  (현재 `self` · `self`).

> **어댑터 미검증.** `script/forge/github.sh` 는 실제 리포에서 아직 돌려보지 않았다.
> 인라인 리뷰 댓글과 라벨 생성 경로를 처음 쓸 때 확인한다.
