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
  --base {{BASE_BRANCH}} --assignee <username> --reviewer <username>
```

- 본문 자동 채움(`--fill`)을 쓰지 않는다 — 양식 항목이 누락된다.
- 본문 작성 규칙은 `.ai/templates/mr-guide.md`, 양식은 `.ai/templates/mr.md`.
- 담당자·리뷰어 기본값은 하네스 설정의 `mr.default_assignee`·`mr.default_reviewer` 다
  (현재 `{{MR_DEFAULT_ASSIGNEE}}` · `{{MR_DEFAULT_REVIEWER}}`).

> **어댑터 미검증.** `script/forge/github.sh` 는 실제 리포에서 아직 돌려보지 않았다.
> 인라인 리뷰 댓글과 라벨 생성 경로를 처음 쓸 때 확인한다.
