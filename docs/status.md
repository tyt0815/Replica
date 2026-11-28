# 개발 상태

## Android 0.5.2 수정

- 곡 선택 모드 상단 좌측의 **전체 선택** 버튼을 우측 확정 버튼과 같은 42×42 원형 버튼(`_DockCircleButton`)으로 변경했다.
- 선택 모드 하단 독의 **삭제** 버튼 옆에 **재생목록에 추가** 버튼을 추가했다. 선택한 여러 곡을 한 번에 기존 재생목록이나 새 재생목록에 추가하고 원격 동기화를 수행한다.
- `./scripts/check-android.ps1` 통과. 정적 분석, 위젯 테스트 15개(원형 전체 선택 버튼 크기·상태 전환 및 재생목록에 추가 버튼 확인 포함), Release APK(24.5MB) 서명 및 버전 `0.5.2+10`을 확인했다.
- `0.5.2`는 로컬 빌드·테스트 완료 상태이며 GitHub Release 게시는 미진행이다.

## 0.5.1 배포 결과

- [GitHub 최신 릴리스](https://github.com/tyt0815/Replica/releases/tag/v0.5.1)를 게시했다. 태그 커밋은 `196a888`이다.
- `Replica-0.5.1-release.apk`(24.5MB)와 `Replica-0.5.1-release.apk.sha256`을 첨부했다. 게시 전후 내려받은 APK의 SHA-256이 `64ee7109f5097f2923885a98db09ad3071c85e8c256a9b09ad911d5643a44402`로 일치했다.

## Android 0.5.1 수정

- `ymusic-io/ffmpeg-build`(`n9.1-dev-18-g90cca8111b`)의 사전 빌드 Android `libffmpeg.so`(arm64-v8a·x86_64)를 체크섬 검증 후 스테이징하도록 `scripts/check-android.ps1`을 보완했다. `ReplicaBackend`가 `vendor/YMusicV4`의 `Ffmpeg.toOpus` / `Ffmpeg.toM4a`를 호출해 Opus 선택 시 `.opus`(Ogg Opus), M4A 선택 시 커버 아트·메타데이터 포함 `.m4a`로 저장한다.
- 화면 상단의 뒤로 버튼을 제거했다. Android 뒤로 가기로 화면과 곡 선택을 닫는다. 곡을 길게 누르면 해당 곡을 선택한다. 기존 뒤로 버튼 위치의 원형 버튼은 모든 곡이 선택됐을 때 체크를 표시한다.
- 더보기의 편집은 상세 화면 위에 재생목록 설정 다이얼로그를 연다. 이름과 자동 다운로드를 저장한다. 저장된 곡과 재생 기록은 시스템 목록이므로 이름을 고정한다.
- 자동 다운로드는 안 함, Wi-Fi에서만, 항상 중 목록별로 설정한다. 기존 0.5.0에서 켠 목록은 항상으로 읽는다. 안 함이 기본이다. Wi-Fi 모드는 개별 다운로드 시작 전에 활성 연결을 확인한다.
- ./scripts/check-android.ps1 통과. 정적 분석, 위젯 테스트 15개, Release APK(24.5MB) 서명과 버전 0.5.1+9를 확인했다. 위젯 테스트에서 다이얼로그 저장·취소, 이름 변경, Wi-Fi 유무와 새 곡 다운로드를 검증했다.
- Android 에뮬레이터(`webtube_test`)에서 0.5.1 Release APK 설치 후 `10 Second Piano Piece 1.opus` 변환 다운로드(8초)와 자동 재생(`USAGE_MEDIA` / `CONTENT_TYPE_MUSIC`, `state:started`, 48kHz)을 확인했다. 다이얼로그의 세 옵션, 길게 누른 곡 선택, 전체 선택, 가로 회전 후 선택 유지도 확인했다. Fold8 실기기와 실제 YouTube 자동 다운로드는 미검증이다.

## Android 0.5.0 수정

- 편집 중에도 재생목록 상세 화면의 커버, 제목, 곡 목록을 유지한다. 각 행의 왼쪽에서 곡을 선택하고 일반 재생목록의 오른쪽 손잡이로 순서를 바꾼다. 하단 독은 슬라이드 전환한다.
- 일반 YouTube 재생목록의 편집 화면에 동기화 시 자동 다운로드 체크박스를 표시한다. 기본값은 꺼짐이다. 확정한 목록별 설정은 기기에 보관하고, 동기화 후 누락된 파일만 요청한다. 기존 설정 파일은 자동으로 꺼짐으로 해석한다.
- ./scripts/check-android.ps1 통과. 정적 분석, 위젯 테스트 15개, Release APK 서명과 버전 0.5.0+8을 확인했다. 위젯 테스트에서 기본값, 편집 취소, 확정, 새로고침 뒤 새 곡만 다운로드를 검증했다.
- Android 에뮬레이터에서 0.4.3 위에 설치했다. 저장된 곡 편집의 제목과 독을 확인했다. 세로에서 전체 선택 후 가로로 회전해 선택 유지도 확인했다. Fold8 실기기와 실제 YouTube 자동 다운로드는 미검증이다.

## 0.4.3 배포 결과

- [GitHub 최신 릴리스](https://github.com/tyt0815/Replica/releases/tag/v0.4.3)를 게시했다. 태그 커밋은 cac1138이다.
- Replica-0.4.3-release.apk와 체크섬을 첨부했다. 게시 전후 내려받은 APK의 SHA-256이 48eee754eb9b913b3b2da8b21223fa3a6f795a6102c7c6548269b13b2c052b82 로 일치했다.

## Android 0.4.3 수정

- 현재 오디오를 먼저 정지한다. 저장된 곡은 바로 준비하고, 미저장 곡은 다운로드 완료 응답으로 받은 파일 경로를 재생기에 전달한다.
- Android Media3 폴백과 Flutter가 중복 요청하던 오디오 포커스를 Flutter에서 관리한다. Android 브리지는 준비가 완료될 때 파일 로드 응답을 보낸다.
- 재생목록과 저장된 곡 편집에서 원형 선택 표시와 전체 선택·삭제 독을 사용한다. 상단 체크로 변경을 저장한다. 일반 재생목록은 드래그로 순서를 변경한다. 동기화 성공·대기 알림을 제거했다.
- ./scripts/check-android.ps1 통과. 정적 분석, 위젯 테스트 14개, Release APK 서명과 버전 0.4.3+7을 확인했다.
- Android 에뮬레이터 Release APK에서 0.4.2 위 설치, 저장곡 첫 탭의 48kHz 오디오 출력, 곡 전환, 일시정지, 확정 뒤 선택 파일 삭제를 확인했다.
- 다음 확인은 실제 YouTube 미저장 곡 재생과 Fold8 커버·내부의 세로·가로 전환이다.

## 0.4.2 배포 결과

- [GitHub 최신 릴리스](https://github.com/tyt0815/Replica/releases/tag/v0.4.2) 게시 확인. 태그 커밋은 64474d8이다.
- Replica-0.4.2-release.apk와 Replica-0.4.2-release.apk.sha256을 첨부했다. 게시 전후 내려받은 APK의 SHA-256은 f77bd65f1d0c639f3d53fee7d077189610e23c26e3f4447321f3c1a0772817fa 로 일치했다.

## Android 0.4.2 수정

- YMusic의 yplrm1 토큰에서 곡 항목 ID를 추출하도록 수정했다. 곡 이동과 앞 곡 지정에 같은 규칙을 사용한다.
- 목록 생성·조회·이름 변경의 Android 응답과 요청을 Flutter 규격에 맞췄다. 기기별 목록이 없고 History.rm이 있으면 하나를 History.기기이름.rm으로 변경한다. 기존 중복 목록은 보존한다. 새 목록은 첫 곡 기록 전에 ID를 저장한다.
- 최근 재생한 곡을 원격 기록 목록 맨 앞으로 이동하고 최대 100곡을 유지한다.
- ./scripts/check-android.ps1 통과. 정적 분석, 위젯 테스트 14개, 서명된 Release APK 0.4.2+6 검증 완료. 기존 History 이름 변경 후 세 번의 재생 요청이 같은 ID를 쓰는지 검사했다. Gradle :replica-backend:test에서 엔진 토큰 회귀 테스트 통과.
- Android 에뮬레이터에서 0.4.1 위에 0.4.2 설치 및 실행을 확인했다. 다음 확인은 실제 YouTube 계정에서 목록 순서를 바꾸고 다른 클라이언트에서 다시 읽는 것과 Fold8 실기기 확인이다.

## 0.4.1 배포 결과

- 최신 [GitHub Release](https://github.com/tyt0815/Replica/releases/tag/v0.4.1) 게시 완료. 태그 커밋은 79bce59다.
- Replica-0.4.1-release.apk와 해당 .sha256 파일을 게시했다. 게시 전후 내려받은 APK의 SHA-256은 8d67290b7e594261617dd39b65adea78e32977e2302eea7b8be883a82852504a로 일치했다.
- 읽기 전용 Android 에뮬레이터에서 배포 APK 0.4.0 설치 후 0.4.1 덮어쓰기에 성공했다. 패키지 버전과 업데이트 후 앱 시작을 확인했다. Fold8 실기기와 실제 계정의 재생목록 동기화는 미검증이다.

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
