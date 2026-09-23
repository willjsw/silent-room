## 리뷰 요청 명령

| 하는 일 | 명령 |
|---|---|
| MR 조회 | `glab mr view <번호>` |
| MR diff | `glab mr diff <번호> --color=never` |
| MR 라벨 | `glab mr update <번호> --label <라벨>` |

MR 번호는 `!N` 으로 적는다.

### MR 생성

```bash
glab mr create --title "<제목>" --description "$(cat <본문파일>)" \
  --target-branch {{BASE_BRANCH}} --assignee <username> --reviewer <username>
```

- 본문 자동 채움(`--fill`)을 쓰지 않는다 — 양식 항목이 누락된다.
- 본문 작성 규칙은 `.ai/templates/mr-guide.md`, 양식은 `.ai/templates/mr.md`.
- 담당자·리뷰어 기본값은 하네스 설정의 `mr.default_assignee`·`mr.default_reviewer` 다
  (현재 `{{MR_DEFAULT_ASSIGNEE}}` · `{{MR_DEFAULT_REVIEWER}}`).
