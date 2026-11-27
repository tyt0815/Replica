use reqwest::blocking::{Client, Response};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File},
    io::{Read, Write},
    path::Path,
    sync::{
        LazyLock,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    time::Duration,
};
use url::Url;

const RELEASES_API_URL: &str =
    "https://api.github.com/repos/tyt0815/Replica/releases?per_page=10";
const RELEASE_DOWNLOAD_PREFIX: &str = "https://github.com/tyt0815/Replica/releases/download/";
const USER_AGENT: &str = "replica-updater";
const MAX_REDIRECTS: usize = 5;
const MAX_APK_BYTES: u64 = 256 * 1024 * 1024;

static UPDATE_DOWNLOADED_BYTES: AtomicU64 = AtomicU64::new(0);
static UPDATE_TOTAL_BYTES: AtomicU64 = AtomicU64::new(0);
static UPDATE_CANCELLED: AtomicBool = AtomicBool::new(false);

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct UpdateDownloadProgress {
    pub downloaded_bytes: u64,
    pub total_bytes: u64,
}

pub fn update_download_progress() -> UpdateDownloadProgress {
    UpdateDownloadProgress {
        downloaded_bytes: UPDATE_DOWNLOADED_BYTES.load(Ordering::Relaxed),
        total_bytes: UPDATE_TOTAL_BYTES.load(Ordering::Relaxed),
    }
}

pub fn cancel_update_download() {
    UPDATE_CANCELLED.store(true, Ordering::Relaxed);
}

fn reset_update_download_progress(total_bytes: u64) {
    UPDATE_DOWNLOADED_BYTES.store(0, Ordering::Relaxed);
    UPDATE_TOTAL_BYTES.store(total_bytes, Ordering::Relaxed);
}

static UPDATE_CLIENT: LazyLock<Result<Client, String>> = LazyLock::new(|| {
    Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .tcp_nodelay(true)
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(300))
        .build()
        .map_err(|_| "업데이트 네트워크 초기화 실패".into())
});

fn update_client() -> Result<&'static Client, String> {
    UPDATE_CLIENT.as_ref().map_err(Clone::clone)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Version {
    pub major: u32,
    pub minor: u32,
    pub patch: u32,
}

pub fn parse_version(raw: &str) -> Option<Version> {
    let without_build = raw.trim().split('+').next()?.trim();
    let core = without_build.strip_prefix('v').unwrap_or(without_build);
    let mut parts = core.split('.');
    let major = parts.next()?.parse::<u32>().ok()?;
    let minor = parts.next()?.parse::<u32>().ok()?;
    let patch = parts.next()?.parse::<u32>().ok()?;
    if parts.next().is_some() {
        return None;
    }
    Some(Version {
        major,
        minor,
        patch,
    })
}

fn format_version(v: Version) -> String {
    format!("{}.{}.{}", v.major, v.minor, v.patch)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdateCheckResult {
    pub update_available: bool,
    pub current_version: String,
    pub latest_version: String,
    pub tag_name: String,
    pub release_notes: String,
    pub asset_name: Option<String>,
    pub asset_url: Option<String>,
    pub asset_size: Option<u64>,
    pub sha256: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DownloadedUpdate {
    pub path: String,
    pub sha256: String,
    pub bytes: u64,
}

pub fn check_latest_release(current_version_raw: &str) -> Result<UpdateCheckResult, String> {
    let current = parse_version(current_version_raw)
        .ok_or_else(|| format!("현재 버전 형식이 올바르지 않습니다: {current_version_raw}"))?;
    let client = update_client()?;
    let response = client
        .get(RELEASES_API_URL)
        .timeout(Duration::from_secs(12))
        .header(reqwest::header::USER_AGENT, USER_AGENT)
        .header(reqwest::header::ACCEPT, "application/vnd.github+json")
        .send()
        .map_err(|_| "GitHub 릴리스 확인에 실패했습니다.")?;
    if !response.status().is_success() {
        return Err(format!("GitHub 릴리스 조회 오류 ({})", response.status()));
    }
    let releases: Vec<Value> = response
        .json()
        .map_err(|_| "GitHub 릴리스 응답을 해석하지 못했습니다.")?;

    select_best_release(current, &releases)
}

pub fn select_best_release(
    current: Version,
    releases: &[Value],
) -> Result<UpdateCheckResult, String> {
    let mut best: Option<(Version, &Value, String, String, Option<u64>, Option<String>)> = None;

    for release in releases {
        if release.get("draft").and_then(Value::as_bool) == Some(true) {
            continue;
        }
        let Some(tag) = release.get("tag_name").and_then(Value::as_str) else {
            continue;
        };
        let Some(version) = parse_version(tag) else {
            continue;
        };
        let assets = release
            .get("assets")
            .and_then(Value::as_array)
            .map(Vec::as_slice)
            .unwrap_or(&[]);
        let Some(apk) = assets.iter().find(|asset| {
            asset
                .get("name")
                .and_then(Value::as_str)
                .is_some_and(|name| name.starts_with("Replica-") && name.ends_with(".apk"))
        }) else {
            continue;
        };
        let Some(asset_name) = apk.get("name").and_then(Value::as_str) else {
            continue;
        };
        let Some(asset_url) = apk.get("browser_download_url").and_then(Value::as_str) else {
            continue;
        };
        if !asset_url.starts_with(RELEASE_DOWNLOAD_PREFIX) {
            continue;
        }
        let asset_size = apk.get("size").and_then(Value::as_u64);
        let sha256 = apk
            .get("digest")
            .and_then(Value::as_str)
            .and_then(valid_sha256);

        let replace = match &best {
            None => true,
            Some((best_ver, _, _, _, _, _)) => version > *best_ver,
        };
        if replace {
            best = Some((
                version,
                release,
                asset_name.to_owned(),
                asset_url.to_owned(),
                asset_size,
                sha256,
            ));
        }
    }

    let current_str = format_version(current);
    let Some((latest_ver, release, asset_name, asset_url, asset_size, sha256)) = best else {
        return Ok(UpdateCheckResult {
            update_available: false,
            current_version: current_str.clone(),
            latest_version: current_str,
            tag_name: String::new(),
            release_notes: String::new(),
            asset_name: None,
            asset_url: None,
            asset_size: None,
            sha256: None,
        });
    };

    Ok(UpdateCheckResult {
        update_available: latest_ver > current,
        current_version: current_str,
        latest_version: format_version(latest_ver),
        tag_name: release
            .get("tag_name")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned(),
        release_notes: release
            .get("body")
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim()
            .to_owned(),
        asset_name: Some(asset_name),
        asset_url: Some(asset_url),
        asset_size,
        sha256,
    })
}

fn valid_sha256(raw: &str) -> Option<String> {
    let hex = raw.trim().strip_prefix("sha256:").unwrap_or(raw.trim());
    if hex.len() == 64 && hex.bytes().all(|b| b.is_ascii_hexdigit()) {
        Some(hex.to_ascii_lowercase())
    } else {
        None
    }
}

fn allowed_redirect_host(url: &Url) -> bool {
    url.scheme() == "https"
        && url.username().is_empty()
        && url.password().is_none()
        && url.port().is_none()
        && matches!(
            url.host_str(),
            Some(
                "github.com"
                    | "objects.githubusercontent.com"
                    | "release-assets.githubusercontent.com"
            )
        )
}

fn get_following_redirects(client: &Client, initial: Url) -> Result<Response, String> {
    let mut current = initial;
    for _ in 0..=MAX_REDIRECTS {
        let response = client
            .get(current.clone())
            .header(reqwest::header::USER_AGENT, USER_AGENT)
            .send()
            .map_err(|_| "업데이트 파일 다운로드에 실패했습니다.")?;
        if response.status().is_redirection() {
            let location = response
                .headers()
                .get(reqwest::header::LOCATION)
                .and_then(|v| v.to_str().ok())
                .ok_or("업데이트 리다이렉트 주소가 없습니다.")?;
            let next = current
                .join(location)
                .map_err(|_| "업데이트 리다이렉트 주소를 해석하지 못했습니다.")?;
            if !allowed_redirect_host(&next) {
                return Err("허용되지 않은 업데이트 호스트입니다.".into());
            }
            current = next;
            continue;
        }
        if !response.status().is_success() {
            return Err(format!("업데이트 다운로드 오류 ({})", response.status()));
        }
        return Ok(response);
    }
    Err("업데이트 리다이렉트 횟수를 초과했습니다.".into())
}

pub fn download_update_apk(
    asset_url: &str,
    expected_sha256: Option<&str>,
    cache_dir: &Path,
) -> Result<DownloadedUpdate, String> {
    if !asset_url.starts_with(RELEASE_DOWNLOAD_PREFIX) {
        return Err("허용되지 않은 업데이트 다운로드 주소입니다.".into());
    }
    let parsed = Url::parse(asset_url).map_err(|_| "업데이트 주소가 올바르지 않습니다.")?;
    let filename = parsed
        .path_segments()
        .and_then(|mut s| s.next_back())
        .filter(|name| {
            name.starts_with("Replica-")
                && name.ends_with(".apk")
                && !name.contains("..")
                && name
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b'_'))
        })
        .ok_or("업데이트 APK 파일 이름이 올바르지 않습니다.")?
        .to_owned();

    let update_dir = cache_dir.join("update");
    fs::create_dir_all(&update_dir).map_err(|_| "업데이트 캐시 폴더를 만들지 못했습니다.")?;
    let final_path = update_dir.join(&filename);
    let part_path = update_dir.join(format!("{filename}.part"));

    UPDATE_CANCELLED.store(false, Ordering::Relaxed);
    reset_update_download_progress(0);
    let client = update_client()?;
    let mut response = get_following_redirects(client, parsed)?;
    if UPDATE_CANCELLED.load(Ordering::Relaxed) {
        reset_update_download_progress(0);
        return Err("업데이트 다운로드가 취소되었습니다.".into());
    }
    let expected_total = response.content_length().unwrap_or(0);
    UPDATE_TOTAL_BYTES.store(expected_total, Ordering::Relaxed);

    let mut file = File::create(&part_path).map_err(|_| "임시 APK 파일을 만들지 못했습니다.")?;
    let mut hasher = Sha256::new();
    let mut buf = [0u8; 64 * 1024];
    let mut total = 0u64;
    loop {
        if UPDATE_CANCELLED.load(Ordering::Relaxed) {
            drop(file);
            let _ = fs::remove_file(&part_path);
            reset_update_download_progress(0);
            return Err("업데이트 다운로드가 취소되었습니다.".into());
        }
        let read = match response.read(&mut buf) {
            Ok(n) => n,
            Err(_) => {
                drop(file);
                let _ = fs::remove_file(&part_path);
                reset_update_download_progress(0);
                return Err("APK 다운로드 중 오류가 발생했습니다.".into());
            }
        };
        if read == 0 {
            break;
        }
        total = total.saturating_add(read as u64);
        if total > MAX_APK_BYTES {
            drop(file);
            let _ = fs::remove_file(&part_path);
            reset_update_download_progress(0);
            return Err("APK 파일 크기가 허용 한도를 초과했습니다.".into());
        }
        hasher.update(&buf[..read]);
        if file.write_all(&buf[..read]).is_err() {
            drop(file);
            let _ = fs::remove_file(&part_path);
            reset_update_download_progress(0);
            return Err("APK 파일 쓰기에 실패했습니다.".into());
        }
        UPDATE_DOWNLOADED_BYTES.store(total, Ordering::Relaxed);
    }
    UPDATE_TOTAL_BYTES.store(total, Ordering::Relaxed);
    UPDATE_DOWNLOADED_BYTES.store(total, Ordering::Relaxed);
    if file.flush().is_err() {
        drop(file);
        let _ = fs::remove_file(&part_path);
        reset_update_download_progress(0);
        return Err("APK 저장에 실패했습니다.".into());
    }
    drop(file);

    if expected_total > 0 && total != expected_total {
        let _ = fs::remove_file(&part_path);
        reset_update_download_progress(0);
        return Err("업데이트 파일 다운로드가 중단되어 불완전합니다.".into());
    }

    let actual_sha = format!("{:x}", hasher.finalize());
    if let Some(expected) = expected_sha256.and_then(valid_sha256)
        && actual_sha != expected
    {
        let _ = fs::remove_file(&part_path);
        reset_update_download_progress(0);
        return Err("다운로드한 APK의 무결성 검증(SHA-256)에 실패했습니다.".into());
    }

    if final_path.exists() {
        let _ = fs::remove_file(&final_path);
    }
    if fs::rename(&part_path, &final_path).is_err() {
        let _ = fs::remove_file(&part_path);
        reset_update_download_progress(0);
        return Err("APK 파일 이동에 실패했습니다.".into());
    }

    Ok(DownloadedUpdate {
        path: final_path.to_string_lossy().into_owned(),
        sha256: actual_sha,
        bytes: total,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_and_compares_semver() {
        assert_eq!(
            parse_version("v0.1.0"),
            Some(Version {
                major: 0,
                minor: 1,
                patch: 0
            })
        );
        assert_eq!(
            parse_version("0.2.3+5"),
            Some(Version {
                major: 0,
                minor: 2,
                patch: 3
            })
        );
        assert!(parse_version("0.2.0").unwrap() > parse_version("0.1.9").unwrap());
    }

    #[test]
    fn selects_newer_github_release_with_apk() {
        let releases = vec![
            json!({
                "tag_name": "v0.1.0",
                "draft": false,
                "body": "초기 릴리스",
                "assets": [{
                    "name": "Replica-0.1.0-release.apk",
                    "size": 12345,
                    "browser_download_url": "https://github.com/tyt0815/Replica/releases/download/v0.1.0/Replica-0.1.0-release.apk"
                }]
            }),
            json!({
                "tag_name": "v0.2.0",
                "draft": false,
                "body": "기능 추가",
                "assets": [{
                    "name": "Replica-0.2.0-release.apk",
                    "size": 23456,
                    "browser_download_url": "https://github.com/tyt0815/Replica/releases/download/v0.2.0/Replica-0.2.0-release.apk"
                }]
            }),
        ];
        let result = select_best_release(parse_version("0.1.0").unwrap(), &releases).unwrap();
        assert!(result.update_available);
        assert_eq!(result.latest_version, "0.2.0");
        assert_eq!(result.asset_name.as_deref(), Some("Replica-0.2.0-release.apk"));
    }
}
