# Replica

Replica는 음악과 영상을 한 앱에서 재생하는 Flutter 프로젝트입니다. Android 시험판은 YouTube 검색 결과를 YMusicV4 파서로 읽고 선택한 영상을 YouTube 임베디드 플레이어로 재생합니다.

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

설치 파일은 `flutter build apk --release --target-platform android-arm64,android-x64`로 만듭니다. 경로는 `build/app/outputs/flutter-apk/app-release.apk`입니다. 현재 시험판은 로컬 디버그 키로 서명합니다.

Windows에서는 저장소 루트에서 `./scripts/check-android.ps1`을 실행하면 포맷 검사부터 Release APK 생성까지 진행합니다. `-Mode debug`를 붙이면 Debug APK를 만듭니다. 결과는 `dist/Replica-<버전>-<모드>.apk`와 같은 이름의 `.sha256` 파일입니다. PATH에 Flutter가 있으면 현재 개발 환경을 사용합니다. 없으면 저장소의 `.tools`, 인접한 ReplicaMusic의 `.tools` 순으로 찾습니다.

### 목표

- 음악 화면은 Replica Music의 다운로드 우선 재생과 `.rm` 재생목록 동작을 기준으로 합니다.
- 영상 화면도 Flutter로 구현합니다. Android에서 먼저 검증하고 Windows 지원 범위는 기능별로 확장합니다.
- YMusic 원본은 `vendor/YMusicV4`에 둡니다. Replica UI와 플랫폼 연결 코드는 상위 저장소에서 관리합니다. 빌드에는 대상 플랫폼에 필요한 모듈과 의존성만 포함하는 것이 목표입니다.
- 엔진 OTA는 설치된 앱이 호환되는 JS 번들을 받는 기능입니다. 공식 채널 연동과 실패 시 내장 번들 복구는 기기에서 검증해야 합니다.
- 앱 자체의 업데이트는 GitHub Releases를 사용할 계획입니다. 앱 시작 시와 설정 화면에서 새 버전을 확인하고 사용자가 다운로드와 설치를 선택하는 흐름입니다. 현재 시험판은 APK를 직접 설치합니다. 버전 태그, 첨부 파일, 게시 후 검증 절차는 [릴리스 작업](AGENTS.md#릴리스-작업)에 정리했습니다.

[작업 지침](AGENTS.md) · [개발 상태](docs/status.md) · [YMusicV4](https://github.com/ymusic-io/YMusicV4) · [라이선스](LICENSE)
