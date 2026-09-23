## 이슈 명령

| 하는 일 | 명령 |
|---|---|
| 이슈 조회 | `gh issue view <번호>` |
| 이슈 생성 | `gh issue create` |
| 이슈에 댓글 | `gh issue comment <번호> -b "<본문>"` |
| 현재 사용자명 | `gh api user -q .login` |

이슈 번호는 `#N` 으로 적는다.
이슈 본문 양식은 `.ai/templates/issue-requirement.md`(요구사항)·`.ai/templates/issue-task.md`(task).
