# Replica

Replica는 음악과 영상을 한 앱에서 재생하는 프로젝트입니다. Flutter로 화면을 만들고 YMusicV4에서 검색과 재생 기능을 가져옵니다. 현재 단계는 저장소 준비입니다. 실행할 앱은 아직 없습니다.

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

- 음악 화면은 Replica Music의 다운로드 우선 재생과 `.rm` 재생목록 동작을 기준으로 합니다.
- 영상 화면도 Flutter로 구현합니다. Android에서 먼저 검증하고 Windows 지원 범위는 기능별로 확장합니다.
- YMusic 원본은 `vendor/YMusicV4`에 둡니다. Replica UI와 플랫폼 연결 코드는 상위 저장소에서 관리합니다. 빌드에는 대상 플랫폼에 필요한 모듈과 의존성만 포함하는 것이 목표입니다.
- 엔진 OTA는 설치된 앱이 호환되는 JS 번들을 받는 기능입니다. 공식 채널 연동과 실패 시 내장 번들 복구는 기기에서 검증해야 합니다.

[작업 지침](AGENTS.md) · [개발 상태](docs/status.md) · [YMusicV4](https://github.com/ymusic-io/YMusicV4) · [라이선스](LICENSE)
