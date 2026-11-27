# 개발 상태

## Android 0.4.1 수정

- 재생목록 편집 시 YouTube 항목 ID로 곡을 이동한다. 원격 순서를 확인한 뒤 버전이 포함된 목록 이름을 반영한다.
- Android 기본·원형 런처 아이콘 XML 네 개를 ReplicaTube 원본과 해시로 대조했다. 배경은 #FF0035다.
- ./scripts/check-android.ps1 통과. 정적 분석과 위젯 테스트 14개, Release APK 서명 및 버전 0.4.1+5를 확인했다.
- 연결된 Android 기기가 없어 실제 계정의 재생목록 순서와 Fold8 런처 표시는 미검증이다. 다음 확인은 곡 이동 후 다른 기기에서 같은 목록을 다시 여는 것이다.

## Android 시험판 0.4.0

`crates/replica-music-core` Rust 코드와 Flutter 내부 네트워크·재생 코드(`HttpClient`, `just_audio`, `ffi`)를 모두 제거했다. Flutter(`apps/replica/lib`)는 UI와 `MethodChannel` 브리지만 담당한다.

- **공통 Kotlin 백엔드 (`apps/replica/android/replica-backend`)**: `vendor/YMusicV4`를 수정 없이 Gradle `includeBuild`로 연결했다.
  - 검색(`yt/search`), 계정 정보(`yt/account`), 보관함·재생목록 조회(`yt/library`, `yt/playlist`), 곡 추가·제거(`yt/playlist/add`, `yt/playlist/remove`), SABR 오디오 다운로드(`DynamicEnginePlayer` + `SabrSpecBuilder` + `SabrSession`), 썸네일 로딩(`KmpHttpClient`)은 모두 `vendor/YMusicV4` 모듈을 사용한다.
  - `vendor/YMusicV4`에 없는 빈 `.rm` 목록 생성, 목록 이름 변경·삭제, 곡 순서 동기화, 기기별 재생 기록, GitHub Releases 앱 업데이트(`tyt0815/Replica`), 오류 로그 저장은 상위 저장소의 순수 Kotlin 백엔드에서 YMusic의 `:kmpHttp:core`와 공유 쿠키를 재사용해 보완했다.
- **Android 어댑터 (`apps/replica/android/app`)**: `WebViewCookieJar`, `YMusicPlayerBridge`(`LocalPlayer` 우선, `ffmpeg-build` 부재 시 Media3 `ExoPlayer` 폴백), `AppUpdatePlugin`, `WebLoginActivity`, `proguard-rules.pro`(QuickJS/MSE JNI keep)를 연결했다.

## 확인한 동작

- `0.4.0` 커밋 `6078b51`에 태그 `v0.4.0`을 붙여 [v0.4.0 릴리스](https://github.com/tyt0815/Replica/releases/tag/v0.4.0)를 게시했다.
- 첨부 파일은 `Replica-0.4.0-release.apk`(19.9MB)와 `Replica-0.4.0-release.apk.sha256`이다. `./scripts/release-android.ps1`로 게시 전후 내려받은 APK의 SHA-256(`fadf9064e994f299173655bd81f928094f7ca989b5dbe4e45094ea13f3eead10`) 일치를 확인했다.
- `git submodule status --recursive`: `vendor/YMusicV4` 변경 없음 확인.
- `./scripts/check-android.ps1`: `flutter pub get`, `dart format`(0 changed), `flutter analyze`(이슈 없음), 위젯 테스트 14개 통과, Release APK(`dist/Replica-0.4.0-release.apk`, 19.9MB) 빌드 및 배포 인증서 지문(`4b61423c...`)·패키지 ID(`io.replicamedia.replica`)·버전(`0.4.0+4`) 검증 완료.
- Android 15 x86_64 에뮬레이터(`emulator-5580`) 검증:
  - 기존 `0.3.0`(`versionCode=3`) 위에 `0.4.0`(`versionCode=4`) Release APK 덮어쓰기 설치 성공.
  - `vendor/YMusicV4` QuickJS `DynamicEngineManager`를 통한 `10 second piano` 검색 결과 정상 표시.
  - `vendor/YMusicV4` `DynamicEnginePlayer` + `SabrSession`을 통한 `10 Second Piano Piece 1.webm` 다운로드(8초) 완료.
  - 미니 플레이어 재생 시 `USAGE_MEDIA` / `CONTENT_TYPE_MUSIC` 오디오 출력(`state:started`, 48kHz)과 일시정지 시 출력 중단 확인.

## 미해결 항목

- ARM64 실기기 검증은 남아 있다.
- Fold8 커버·내부 화면의 세로·가로 회전과 접기·펼치기 실기기 검증은 남아 있다(위젯 테스트로 4가지 화면 상태 레이아웃은 검증됨).
- `ffmpeg-build`가 로컬에 없어 MSE 스트리밍 플레이어와 `AudioFxNative`는 비활성 상태이며, 로컬 재생은 Media3 `ExoPlayer` 폴백으로 동작한다.

## 다음 시작점

영상 재생 화면과 FFmpeg/MSE 스트리밍 연결, 엔진 JS OTA 수신·복구 검증, Windows 데스크톱 사이드카/JNI 연결을 진행한다.

## 배포 인계

Replica Music의 작업 지침, README, 환경·검증·빌드 스크립트와 게시된 v0.16.1을 대조했다. Replica는 기존 빌드 스크립트의 APK별 `.sha256` 이름을 사용한다. [참고 릴리스](https://github.com/tyt0815/ReplicaMusic/releases/tag/v0.16.1)

Replica 0.1.0은 디버그 키로 서명한 로컬 시험판이다. 0.2.0부터 전용 배포 인증서를 사용한다. 공개 저장소의 최신 릴리스를 설정 화면에서 확인한다. APK 크기와 GitHub가 제공한 SHA-256을 대조한 뒤 시스템 설치 화면을 연다. 배포 시 [릴리스 작업](../AGENTS.md#릴리스-작업)을 따른다.
