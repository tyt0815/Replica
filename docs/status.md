# 개발 상태

## Android 시험판 0.1.0

Flutter 3.50.1로 검색 화면과 재생 화면을 구현했다. 검색 요청은 Replica가 보내고, 결과 정렬과 항목 추출은 고정된 YMusic 서브모듈의 `engine-js` 파서를 사용한다. Gradle이 빌드할 때 해당 모듈을 번들로 만든다. 재생에는 YouTube 임베디드 플레이어를 사용한다.

## 확인한 동작

- `apps/replica`에서 `flutter analyze`, `flutter test`, `flutter build apk --debug`를 실행했다. 분석 오류 없이 위젯 테스트와 빌드가 통과했다.
- x86_64 Android 에뮬레이터에서 APK를 설치하고 Jazz 검색 결과의 제목과 채널명을 확인했다. 첫 결과를 선택한 뒤 플레이어 자막과 같은 앱 프로세스의 활성 오디오 출력을 확인했다.

- arm64와 x86_64를 포함한 release APK를 빌드했다. 같은 에뮬레이터에 설치해 앱 시작과 검색 결과를 다시 확인했다.

## 다음 시작점

Android에 YMusic 네이티브 플레이어를 연결한다. 같은 영상에서 오디오 전용 재생과 영상 전환을 검증한다. 이어서 JS 엔진 OTA 수신과 실패 시 복구를 확인한다. 오프라인 재생, 보관함, Windows 앱은 후속 범위다.

