# Replica

Replica는 음악과 영상을 한 앱에서 재생하는 Flutter 프로젝트입니다. Android 시험판은 YouTube 검색 결과를 YMusicV4 파서로 읽고 선택한 영상을 YouTube 임베디드 플레이어로 재생합니다.

검색에서 선택한 영상은 스트리밍합니다. 보관함의 음악 재생과 음악 기록은 따로 관리합니다.

## 시작하기

Git을 설치한 뒤 저장소를 받습니다.

```sh
git clone --recurse-submodules https://github.com/tyt0815/Replica.git
cd Replica
git submodule status --recursive
```

이미 받은 저장소에서는 다음 명령으로 고정된 엔진 버전을 복원합니다.

```sh
git submodule update --init --recursive
```

## 개발 방향

### Android 시험판 실행

Flutter(Dart 3.14 이상), Android SDK, JDK 21, Node.js와 npm을 준비합니다. 서브모듈을 초기화한 뒤 아래 명령을 실행합니다. Gradle은 고정된 esbuild 버전으로 YMusic 검색 파서와 그 의존성을 묶습니다. 첫 빌드에는 인터넷 연결이 필요합니다.

```sh
cd apps/replica
flutter pub get
flutter analyze
flutter test
flutter run
```

[최신 Android APK](https://github.com/tyt0815/Replica/releases/latest)를 내려받아 설치할 수 있습니다. 0.2.0부터 배포 전용 키로 서명합니다. 기존 0.1.0 로컬 시험판은 서명이 달라서 덮어쓸 수 없습니다. 기존 앱 삭제 시 앱 데이터도 삭제됩니다.

Windows에서는 저장소 루트에서 `./scripts/check-android.ps1`을 실행하면 포맷 검사부터 Release APK 생성까지 진행합니다. `-Mode debug`를 붙이면 Debug APK를 만듭니다. 결과는 `dist/Replica-<버전>-<모드>.apk`와 같은 이름의 `.sha256` 파일입니다. PATH에 Flutter가 있으면 현재 개발 환경을 사용합니다. 없으면 저장소의 `.tools`, 인접한 ReplicaMusic의 `.tools` 순으로 찾습니다.

### 목표

- 음악 화면은 Replica Music의 다운로드 우선 재생과 `.rm` 재생목록 동작을 기준으로 합니다.
- 영상 화면도 Flutter로 구현합니다. Android에서 먼저 검증하고 Windows 지원 범위는 기능별로 확장합니다.
- YMusic 원본은 `vendor/YMusicV4`에 둡니다. Replica UI와 플랫폼 연결 코드는 상위 저장소에서 관리합니다. 빌드에는 대상 플랫폼에 필요한 모듈과 의존성만 포함하는 것이 목표입니다.
- 엔진 OTA는 설치된 앱이 호환되는 JS 번들을 받는 기능입니다. 공식 채널 연동과 실패 시 내장 번들 복구는 기기에서 검증해야 합니다.
- 설정의 **앱 업데이트 확인**에서 공개 GitHub Releases를 확인할 수 있습니다. 다운로드한 APK의 크기와 SHA-256을 확인한 뒤 Android 설치 화면을 엽니다. 기기가 요청하면 Replica의 앱 설치를 허용합니다.

### 릴리스 게시

배포 키가 없는 개발 환경에서는 `./scripts/check-android.ps1 -Mode debug`를 사용합니다. Release 빌드는 기본적으로 사용자 홈의 `.replica-signing/key.properties`를 읽습니다. 다른 위치는 `REPLICA_SIGNING_PROPERTIES`로 지정합니다. 이 파일의 필드는 `storeFile`, `storePassword`, `keyAlias`, `keyPassword`입니다. 키 파일 경로는 설정 파일 기준입니다. 키와 설정 파일은 함께 비공개로 백업해야 다음 버전에 같은 서명을 사용할 수 있습니다.

배포 환경에서 검증할 커밋을 main에 푸시한 뒤 `./scripts/release-android.ps1 -NotesFile <한국어-릴리스-노트-경로>`를 실행합니다. GitHub CLI 인증이 필요합니다. 스크립트는 버전 태그와 초안을 만들고 APK와 체크섬을 올립니다. 첨부물 검증 후 게시하고 게시본을 다시 내려받아 확인합니다. [릴리스 작업](AGENTS.md#릴리스-작업)

[작업 지침](AGENTS.md) · [개발 상태](docs/status.md) · [YMusicV4](https://github.com/ymusic-io/YMusicV4) · [라이선스](LICENSE)
