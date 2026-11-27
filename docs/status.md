# 개발 상태

## Android 시험판 0.3.0

`ReplicaMusic`의 Rust 코어(`crates/replica-music-core`), Flutter UI(`apps/replica/lib`), Android 네이티브 어댑터(`MainActivity`, `AppUpdatePlugin`, `WebLoginActivity`, `AudioService`)와 리소스를 `Replica`(`io.replicamedia.replica`)로 이식했다.

- 보관함, `.rm` 재생목록 동기화, YouTube 검색, 다운로드 우선 재생(`just_audio` + `audio_service` + `audio_session`), Now Playing 시트, 기기별 재생 기록, 테마 전환(시스템·라이트·다크), 오류 로그 내보내기, Fold8 4가지 화면 레이아웃을 포함한다.
- 앱 업데이트 확인과 APK 다운로드 대상 저장소를 `tyt0815/Replica`와 `Replica-*-release.apk`로 연결했다. 앱 시작 시 자동 업데이트 확인은 제거하고 설정 화면의 수동 확인만 유지했다.
- 앱 아이콘을 포인트 색상(`#FF0035`) 배경 위 새 심볼(흰색 둥근 사각형 + `#FF0035` 음표)로 교체했다.
- `scripts/build-core.ps1`을 추가해 호스트와 Android(`arm64-v8a`, `x86_64`) Rust 네이티브 라이브러리를 빌드하고 `./scripts/check-android.ps1`에 통합했다.

## 확인한 동작

- `0.3.0` 커밋 `40faa9c`에 태그 `v0.3.0`을 붙여 [v0.3.0 릴리스](https://github.com/tyt0815/Replica/releases/tag/v0.3.0)를 게시했다.
- 첨부 파일은 `Replica-0.3.0-release.apk`(45.8MB)와 `Replica-0.3.0-release.apk.sha256`이다. `./scripts/release-android.ps1`로 게시 전후 내려받은 APK의 SHA-256(`9edc56c11402b2dd3ba2a5fa311416f78f34b1cc12896695d6ce7e54833041fa`) 일치를 확인했다.
- `cargo test`: Rust 코어 테스트 31개 통과 (1개 live 테스트 무시).
- `./scripts/check-android.ps1`: Rust 호스트·Android 빌드, `flutter pub get`, `dart format` 검사, `flutter analyze`(이슈 없음), 위젯 테스트 14개 전부 통과, Release APK(`dist/Replica-0.3.0-release.apk`, 45.8MB) 빌드와 배포 인증서 지문(`4b61423c...`)·패키지 ID(`io.replicamedia.replica`)·버전(`0.3.0+3`) 검증 완료.
- Android 15 x86_64 에뮬레이터(`emulator-5580`) 검증:
  - 기존 `0.2.0`(`versionCode=2`) 위에 `dist/Replica-0.3.0-release.apk`(`versionCode=3`)를 덮어쓰기 설치했다.
  - 보관함(`저장된 곡`), 하단 독(설정·보관함·검색), 설정 화면(`0.3.0`, 업데이트 확인, 테마)을 확인했다.
  - 검색 탭에서 `jazz`와 `10 second piano` 검색 결과가 Rust 코어로 정상 조회됐다.
  - `10 Second Piano Piece 1`을 4초 만에 `.opus` 파일로 다운로드했고, 재생 시 `USAGE_MEDIA` / `CONTENT_TYPE_MUSIC` 오디오 출력(`state:started`, 48kHz)을 확인했다.
- 이전 릴리스 `v0.2.0`([v0.2.0 릴리스](https://github.com/tyt0815/Replica/releases/tag/v0.2.0), 커밋 `40d53bb`)은 에뮬레이터에서 `0.1.99` -> `0.2.0` 인앱 업데이트와 최신 버전 확인을 검증 완료했다.

## 미해결 항목

- ARM64 실기기 검증은 남아 있다.
- Fold8 커버·내부 화면의 세로·가로 회전과 접기·펼치기 실기기 검증은 남아 있다(위젯 테스트로 4가지 화면 상태 레이아웃은 검증됨).
## 다음 시작점

영상 재생 화면과 YMusic 엔진/OTA 통합, Windows 앱 확장을 진행한다.

## 배포 인계

Replica Music의 작업 지침, README, 환경·검증·빌드 스크립트와 게시된 v0.16.1을 대조했다. 해당 릴리스에는 한국어 변경 사항과 알려진 제약, APK, SHA256SUMS.txt가 있다. 추적된 저장소에 자동 게시 워크플로는 없다. Replica는 기존 빌드 스크립트의 APK별 `.sha256` 이름을 사용한다. [참고 릴리스](https://github.com/tyt0815/ReplicaMusic/releases/tag/v0.16.1)

Replica 0.1.0은 디버그 키로 서명한 로컬 시험판이다. 0.2.0부터 전용 배포 인증서를 사용한다. 공개 저장소의 최신 릴리스를 설정 화면에서 확인한다. APK 크기와 GitHub가 제공한 SHA-256을 대조한 뒤 시스템 설치 화면을 연다. 배포 시 [릴리스 작업](../AGENTS.md#릴리스-작업)을 따른다.
