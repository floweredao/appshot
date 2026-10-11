# Appshot

[English](README.md)

지금 보고 있는 창을 대화 비서에게 넘기는 맥 메뉴 막대 앱이에요. Codex 맥 앱의 Appshots 기능을 본떠 만들었어요.

양쪽 Command 키를 같이 누르면 이렇게 동작해요.

1. 맨 앞 창을 ScreenCaptureKit으로 찍어요. 그림자는 빼고 원본 해상도로 찍어요.
2. 손쉬운 사용(Accessibility) API로 창 안 글자를 모아요. 앱이 주면 스크롤 밖 글자까지 모아요. 앱 이름, 창 제목, 브라우저 주소(URL)도 같이 적어요.
3. 작은 입력창이 떠요. 한 줄을 쓰고(안 써도 돼요) Return을 누르면 보내고, Esc를 누르면 취소해요. 답을 받을 곳은 "최근 대화"나 설정에 적은 채널 가운데서 고를 수 있어요.

Appshot은 디스코드나 다른 네트워크 서비스에 직접 보내지 않아요. 아래처럼 파일로 비서에게 넘겨요.

```
<inboxDir>/<yyyyMMdd-HHmmss-SSS>/
  shot.png    원본 해상도 창 스크린샷
  shot.jpg    미리보기 (긴 변 1568px)
  text.md     창 글자 (Markdown)
  meta.json   앱·창·URL·한 줄·보낼 채널·오류
```

폴더는 임시 폴더에 먼저 만든 뒤 이름을 바꿔 제자리에 넣어요. 그 안의 파일도 하나씩 `.tmp`로 쓴 뒤 이름을 바꿔요. 마지막에 비서의 이벤트 로그에 한 줄을 덧붙여요.

```
EVENT APPSHOT <폴더 절대 경로>
```

비서는 이 로그를 지켜보다가 폴더를 읽고 `meta.channel.id` 채널에 답해요.

## 필요한 것

- macOS 15 이상. macOS 26 이상에서는 입력창이 Liquid Glass로 보여요.
- Xcode 16 이상과 [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Apple Development 인증서. 늘 같은 인증서로 서명해야 업데이트한 뒤에도 화면 기록·손쉬운 사용 권한이 유지돼요.

## 빌드와 설치

```sh
echo 'DEVELOPMENT_TEAM = <팀 ID>' > Config/Local.xcconfig   # git에 안 들어가요
./scripts/build.sh --install                                # -> /Applications/Appshot.app
swift test --package-path Packages/AppshotCore              # 단위 테스트
```

처음 실행하면 "로그인 시 열기"가 켜지고 설정 창이 떠요. 설정 창에서 이렇게 해 주세요.

- **화면 기록**(스크린샷용)과 **손쉬운 사용**(창 글자와 단축키용)을 허용하고 **다시 시작**을 눌러요.
- 설정 파일을 만들어요(아래 참고).
- 원하면 단축키를 바꿔요. 양쪽 ⌘, 양쪽 ⌥, 양쪽 ⇧, 양쪽 ⌃ 가운데 고르거나 원하는 키 조합을 녹화할 수 있어요.

## 설정 파일

채널 ID나 경로 같은 내 컴퓨터만의 값은 저장소에 넣지 않아요. Appshot은 `~/Library/Application Support/Appshot/config.json`을 읽어요.

```json
{
  "stateDir": "~/path/to/assistant/state",
  "inboxDir": "~/path/to/assistant/inbox/appshot",
  "channels": [
    { "key": "general", "label": "#general", "id": "GENERAL_CHANNEL_ID" },
    { "key": "coding",  "label": "#coding",  "id": "CODING_CHANNEL_ID" },
    { "key": "dm",      "label": "DM",       "id": "DM_CHANNEL_ID" }
  ],
  "fallbackChannel": "general",
  "assistantName": "비서"
}
```

- `stateDir`: `events.log`, `owner-inbox.jsonl`, `handled-ids.txt`가 있는 폴더예요. 각 파일은 `eventsLog`, `ownerInbox`, `handledIds`로 따로 지정할 수 있어요. 상대 경로를 쓰면 `stateDir` 기준으로 찾아요.
- `inboxDir`: 앱샷 폴더를 만드는 곳이에요.
- `channels`: 입력창에 보여 줄 채널이에요.
- `fallbackChannel`: 대화 기록이 없을 때 "최근"이 가리킬 채널이에요.

"최근 대화"는 이렇게 정해요. `handled-ids.txt`의 마지막 ID로 `owner-inbox.jsonl`(한 줄에 `id`·`channel`이 든 JSON 하나)에서 그 메시지의 채널을 찾아요. 그 ID가 없으면 `owner-inbox.jsonl`의 마지막 줄 채널을 쓰고, 둘 다 없으면 `fallbackChannel`을 써요.

설정 파일과 inbox는 `~/Documents`, `~/Desktop`, `~/Downloads` 밖에 두세요. 그 안에 두면 읽을 때마다 macOS가 폴더 접근 허락을 물어요.

## 스크립트로 실행

```sh
open -n -W -a Appshot --stdout out.txt --stderr err.txt --args \
  --appshot-now --note "이거 뭐야?" --channel recent [--config /경로/config.json] [--delay-ms 500]
```

입력창 없이 맨 앞 창을 찍어 폴더를 만들고, 폴더 경로를 출력한 뒤 0으로 끝나요. 0이 아닌 종료 코드는 2 설정 오류, 3 창 없음, 4 모르는 채널, 5 저장 실패예요. 권한이 없어도 폴더는 만들고, 빠진 부분은 `meta.json`의 `errors`에 적어요.

## 개인 정보

- 비밀번호 칸(`AXSecureTextField`)은 읽지 않아요.
- 캡처는 내 맥의 `inboxDir`에만 남아요. Appshot은 네트워크로 아무것도 보내지 않아요.
- `scripts/prepush-check.sh`는 gitleaks를 돌리고, 추적 중인 파일·커밋 기록·커밋 작성자 정보에서 이메일, 홈 경로, 디스코드 ID 모양 숫자, 그림 파일, 개인 문자열을 찾아요. 개인 문자열 목록은 git에 안 들어가는 파일에 적어요. `ln -s ../../scripts/prepush-check.sh .git/hooks/pre-push`로 푸시 전 훅으로 걸 수 있어요.

## 라이선스

MIT. [LICENSE](LICENSE)를 보세요.
