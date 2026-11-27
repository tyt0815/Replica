# 개발 상태

## Android 시험판 0.1.0

Flutter 3.50.1로 검색 화면과 재생 화면을 구현했다. 검색 요청은 Replica가 보내고, 결과 정렬과 항목 추출은 고정된 YMusic 서브모듈의 `engine-js` 파서를 사용한다. Gradle이 빌드할 때 해당 모듈을 번들로 만든다. 재생에는 YouTube 임베디드 플레이어를 사용한다.

## 확인한 동작

- 저장소 루트의 `./scripts/check-android.ps1`로 포맷 검사, 분석, 위젯 테스트, Release 빌드를 실행했다. `dist/Replica-0.1.0-release.apk`의 SHA-256을 다시 계산해 동봉한 체크섬과 일치하는지 확인했다.

- 앱 커밋 `dd3b21a`에서 `flutter clean` 후 의존성을 복원했다. Dart 포맷 검사, `flutter analyze`, 위젯 테스트 1개가 통과했다.
- Debug APK와 arm64·x86_64 Release APK를 새로 빌드했다. Release APK의 v2 서명과 두 ABI를 확인했다.
- Android 15 x86_64 에뮬레이터 두 대에서 각각 Debug와 Release를 설치했다. 두 기기 모두 Jazz 검색 결과를 열고 같은 앱 프로세스의 오디오 출력을 확인했다. 뒤로 가면 검색 결과가 유지되고 오디오가 멈췄다.
- ARM64 실기기 검증은 남아 있다. Flutter는 현재 Gradle, Android Gradle Plugin, Kotlin 버전에 대해 향후 지원 종료 경고를 출력했다.

## 다음 시작점

Android에 YMusic 네이티브 플레이어를 연결한다. 같은 영상에서 오디오 전용 재생과 영상 전환을 검증한다. 이어서 JS 엔진 OTA 수신과 실패 시 복구를 확인한다. 오프라인 재생, 보관함, Windows 앱은 후속 범위다.

## 배포 인계

Replica Music의 작업 지침, README, 환경·검증·빌드 스크립트와 게시된 v0.16.1을 대조했다. 해당 릴리스에는 한국어 변경 사항과 알려진 제약, APK, SHA256SUMS.txt가 있다. 추적된 저장소에 자동 게시 워크플로는 없다. Replica는 기존 빌드 스크립트의 APK별 `.sha256` 이름을 사용한다. [참고 릴리스](https://github.com/tyt0815/ReplicaMusic/releases/tag/v0.16.1)

Replica 0.1.0은 로컬 시험판이다. 정식 배포용 서명, GitHub Release 게시, 앱 시작·설정 화면의 업데이트 확인은 후속 작업이다. 배포 시 [릴리스 작업](../AGENTS.md#릴리스-작업)을 따른다.
