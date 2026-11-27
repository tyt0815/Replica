use crate::{
    opus_mux::{self, OpusMetadata},
    sabr,
    youtube::{self, AudioFormat, TrackSummary},
};
use serde::{Deserialize, Serialize};
use std::{
    collections::{HashMap, HashSet},
    fs::{self, File},
    io::{Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    sync::{
        Arc, LazyLock, Mutex,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    time::{Duration, Instant, SystemTime},
};

const AUDIO_EXTENSIONS: &[&str] = &["opus", "m4a", "webm", "mp4"];
const META_DIR_NAME: &str = ".meta";
const MAX_TITLE_BYTES: usize = 180;
const MIN_AUDIO_BYTES: u64 = 1024;
const RANGE_CHUNK_BYTES: u64 = 4 * 1024 * 1024;
const MAX_CHUNK_RETRIES: usize = 3;
const CHUNK_RETRY_BACKOFF_MS: [u64; 3] = [400, 1000, 2200];
const MAX_AUDIO_DOWNLOAD_ROUNDS: usize = 5;
const AUDIO_ROUND_BACKOFF_MS: [u64; 4] = [800, 1500, 2500, 4000];
const PRE_CANCEL_TTL_SECS: u64 = 15;

#[derive(Debug, Clone, Default)]
pub struct DownloadOptions {
    pub format: AudioFormat,
    pub sabr_session: Option<sabr::WebSabrSessionInput>,
}

struct SabrPartial {
    path: Option<PathBuf>,
    segments: sabr::SegmentIndex,
}

impl SabrPartial {
    fn new(path: PathBuf) -> Self {
        Self {
            path: Some(path),
            segments: sabr::SegmentIndex::default(),
        }
    }
}

impl Drop for SabrPartial {
    fn drop(&mut self) {
        if let Some(path) = self.path.as_ref() {
            let _ = fs::remove_file(path);
        }
    }
}

#[derive(Debug, Clone)]
pub struct DownloadError {
    pub message: String,
    pub code: Option<&'static str>,
}

impl DownloadError {
    fn plain(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            code: None,
        }
    }

    fn with_code(message: impl Into<String>, code: &'static str) -> Self {
        Self {
            message: message.into(),
            code: Some(code),
        }
    }
}

impl From<String> for DownloadError {
    fn from(message: String) -> Self {
        Self::plain(message)
    }
}

impl From<&str> for DownloadError {
    fn from(message: &str) -> Self {
        Self::plain(message)
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, Default)]
pub struct TrackDownloadProgress {
    pub downloaded_bytes: u64,
    pub total_bytes: u64,
}

fn parse_content_range_total(header_val: &str) -> Option<u64> {
    let (_, total_str) = header_val.trim().rsplit_once('/')?;
    if total_str == "*" {
        return None;
    }
    total_str.trim().parse::<u64>().ok().filter(|&n| n > 0)
}

static ACTIVE_DOWNLOAD_CANCELS: LazyLock<Mutex<HashMap<String, Arc<AtomicBool>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
static ACTIVE_TRACK_PROGRESS: LazyLock<Mutex<HashMap<String, TrackDownloadProgress>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
static PRE_CANCELLED_DOWNLOADS: LazyLock<Mutex<HashMap<String, Instant>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

fn set_track_progress(video_id: &str, downloaded_bytes: u64, total_bytes: u64) {
    let mut map = ACTIVE_TRACK_PROGRESS
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    map.insert(
        video_id.to_owned(),
        TrackDownloadProgress {
            downloaded_bytes,
            total_bytes,
        },
    );
}

fn clear_track_progress(video_id: &str) {
    let mut map = ACTIVE_TRACK_PROGRESS
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    map.remove(video_id);
}

pub fn read_all_track_progress() -> HashMap<String, TrackDownloadProgress> {
    ACTIVE_TRACK_PROGRESS
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .clone()
}
static FINALIZE_LOCK: LazyLock<Mutex<()>> = LazyLock::new(|| Mutex::new(()));
static ACTIVE_THUMB_THREADS: AtomicUsize = AtomicUsize::new(0);
const MAX_CONCURRENT_THUMB_THREADS: usize = 4;
const STALE_TEMP_FILE_AGE_SECS: u64 = 600;

pub fn cancel_track_download(video_id: &str) {
    let active = ACTIVE_DOWNLOAD_CANCELS
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if let Some(flag) = active.get(video_id) {
        flag.store(true, Ordering::Relaxed);
        return;
    }
    let mut pre = PRE_CANCELLED_DOWNLOADS
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let now = Instant::now();
    pre.retain(|_, ts| now.saturating_duration_since(*ts).as_secs() < PRE_CANCEL_TTL_SECS);
    pre.insert(video_id.to_owned(), now);
}

fn register_download_cancel(video_id: &str) -> Arc<AtomicBool> {
    let mut active = ACTIVE_DOWNLOAD_CANCELS
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let mut pre = PRE_CANCELLED_DOWNLOADS
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let now = Instant::now();
    pre.retain(|_, ts| now.saturating_duration_since(*ts).as_secs() < PRE_CANCEL_TTL_SECS);
    let already_cancelled = pre
        .remove(video_id)
        .is_some_and(|ts| now.saturating_duration_since(ts).as_secs() < PRE_CANCEL_TTL_SECS);
    let flag = Arc::new(AtomicBool::new(already_cancelled));
    active.insert(video_id.to_owned(), Arc::clone(&flag));
    flag
}

fn unregister_download_cancel(video_id: &str, flag: &Arc<AtomicBool>) {
    let mut active = ACTIVE_DOWNLOAD_CANCELS
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if let Some(current) = active.get(video_id)
        && Arc::ptr_eq(current, flag)
    {
        active.remove(video_id);
    }
}

fn sleep_cancelable(total_ms: u64, cancel: &AtomicBool) -> bool {
    let mut remaining = total_ms;
    while remaining > 0 {
        if cancel.load(Ordering::Relaxed) {
            return false;
        }
        let step = remaining.min(50);
        std::thread::sleep(Duration::from_millis(step));
        remaining -= step;
    }
    !cancel.load(Ordering::Relaxed)
}

fn is_permanent_http_status(status: reqwest::StatusCode) -> bool {
    matches!(
        status,
        reqwest::StatusCode::FORBIDDEN
            | reqwest::StatusCode::NOT_FOUND
            | reqwest::StatusCode::GONE
            | reqwest::StatusCode::UNAUTHORIZED
    )
}

pub fn validate_audio_header(path: &Path, extension: &str) -> bool {
    let Ok(meta) = fs::metadata(path) else {
        return false;
    };
    if meta.len() < MIN_AUDIO_BYTES {
        return false;
    }
    let Ok(mut file) = File::open(path) else {
        return false;
    };
    let mut header = [0u8; 16];
    let Ok(n) = file.read(&mut header) else {
        return false;
    };
    if n < 8 {
        return false;
    }
    match extension.to_ascii_lowercase().as_str() {
        "m4a" | "mp4" => &header[4..8] == b"ftyp",
        "webm" => header[0..4] == [0x1A, 0x45, 0xDF, 0xA3],
        "opus" | "ogg" => &header[0..4] == b"OggS" || header[0..4] == [0x1A, 0x45, 0xDF, 0xA3],
        _ => true,
    }
}

fn validate_downloaded_container(path: &Path, extension: &str) -> bool {
    if !validate_audio_header(path, extension) {
        return false;
    }
    match extension.to_ascii_lowercase().as_str() {
        "m4a" | "mp4" => sabr::validate_mp4_file(path),
        "opus" => opus_mux::validate_ogg_opus_file(path),
        _ => true,
    }
}

fn thumbnail_candidates(video_id: &str, url: &str) -> Vec<String> {
    let trimmed = url.trim();
    let mut candidates = Vec::new();
    if youtube::valid_video_id(video_id) && (trimmed.is_empty() || trimmed.contains("ytimg.com")) {
        candidates.push(format!(
            "https://i.ytimg.com/vi/{video_id}/maxresdefault.jpg"
        ));
        candidates.push(format!("https://i.ytimg.com/vi/{video_id}/hq720.jpg"));
        candidates.push(format!("https://i.ytimg.com/vi/{video_id}/mqdefault.jpg"));
    } else if (trimmed.contains("googleusercontent.com") || trimmed.contains("ggpht.com"))
        && let Some(eq_idx) = trimmed.find('=')
    {
        candidates.push(format!("{}=w1080-h1080-l90-rj", &trimmed[..eq_idx]));
    }
    if trimmed.starts_with("https://") {
        candidates.push(trimmed.to_owned());
    }
    candidates
}

fn fetch_thumbnail_jpeg(video_id: &str, url: &str, timeout_secs: u64) -> Option<Vec<u8>> {
    let client = youtube::http_client().ok()?;
    for candidate in thumbnail_candidates(video_id, url) {
        let Ok(resp) = client
            .get(&candidate)
            .timeout(Duration::from_secs(timeout_secs))
            .send()
        else {
            continue;
        };
        if !resp.status().is_success() {
            continue;
        }
        if let Ok(bytes) = resp.bytes()
            && bytes.len() >= 1500
            && bytes.len() <= 6 * 1024 * 1024
            && bytes.starts_with(&[0xFF, 0xD8])
        {
            return Some(bytes.to_vec());
        }
    }
    None
}

fn read_or_fetch_cover_jpeg(video_id: &str, url: &str, storage_dir: &Path) -> Option<Vec<u8>> {
    let thumb_path = meta_dir(storage_dir).join(format!("{video_id}.jpg"));
    if let Ok(bytes) = fs::read(&thumb_path)
        && bytes.starts_with(&[0xFF, 0xD8])
    {
        return Some(bytes);
    }
    if url.trim().is_empty() && !youtube::valid_video_id(video_id) {
        return None;
    }
    fetch_thumbnail_jpeg(video_id, url, 3)
}

fn cache_thumbnail_atomic(video_id: &str, url: &str, storage_dir: &Path) {
    let trimmed = url.trim();
    if !trimmed.starts_with("https://") {
        return;
    }
    let dir = meta_dir(storage_dir);
    let thumb_path = dir.join(format!("{video_id}.jpg"));
    if thumb_path.is_file() {
        return;
    }
    let Some(bytes) = fetch_thumbnail_jpeg(video_id, trimmed, 6) else {
        return;
    };
    let _ = fs::create_dir_all(&dir);
    let unique_ts = SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let tmp_path = dir.join(format!(".{video_id}.{unique_ts}.jpg.tmp"));
    if fs::write(&tmp_path, bytes).is_ok() {
        let _guard = FINALIZE_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if !meta_file_path(video_id, storage_dir).is_file()
            && !legacy_meta_file_path(video_id, storage_dir).is_file()
        {
            let _ = fs::remove_file(&tmp_path);
            return;
        }
        if fs::rename(&tmp_path, &thumb_path).is_err() {
            let _ = fs::remove_file(&thumb_path);
            if fs::rename(&tmp_path, &thumb_path).is_err() {
                let _ = fs::remove_file(&tmp_path);
            }
        }
    }
}

fn spawn_cache_thumbnail_async(video_id: &str, url: &str, storage_dir: &Path) {
    let trimmed = url.trim();
    if !trimmed.starts_with("https://") {
        return;
    }
    let thumb_path = meta_dir(storage_dir).join(format!("{video_id}.jpg"));
    if thumb_path.is_file() {
        return;
    }
    let prev = ACTIVE_THUMB_THREADS.fetch_add(1, Ordering::AcqRel);
    if prev >= MAX_CONCURRENT_THUMB_THREADS {
        ACTIVE_THUMB_THREADS.fetch_sub(1, Ordering::AcqRel);
        return;
    }
    let vid = video_id.to_owned();
    let owned_url = trimmed.to_owned();
    let dir = storage_dir.to_path_buf();
    let spawn_res = std::thread::Builder::new()
        .name("rm-thumb".into())
        .spawn(move || {
            cache_thumbnail_atomic(&vid, &owned_url, &dir);
            ACTIVE_THUMB_THREADS.fetch_sub(1, Ordering::AcqRel);
        });
    if spawn_res.is_err() {
        ACTIVE_THUMB_THREADS.fetch_sub(1, Ordering::AcqRel);
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DownloadedTrack {
    pub video_id: String,
    pub title: String,
    pub artist: String,
    pub duration: String,
    pub thumbnail: String,
    pub file_path: String,
    pub extension: String,
    pub bytes: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StorageUsage {
    pub used_bytes: u64,
    pub item_count: u64,
}

fn meta_dir(storage_dir: &Path) -> PathBuf {
    storage_dir.join(META_DIR_NAME)
}

fn meta_file_path(video_id: &str, storage_dir: &Path) -> PathBuf {
    meta_dir(storage_dir).join(format!("{video_id}.json"))
}

fn legacy_meta_file_path(video_id: &str, storage_dir: &Path) -> PathBuf {
    storage_dir.join(format!("{video_id}.json"))
}

fn read_metadata_record(path: &Path) -> Option<DownloadedTrack> {
    let raw = fs::read(path).ok()?;
    serde_json::from_slice::<DownloadedTrack>(&raw).ok()
}

fn is_windows_reserved_name(name: &str) -> bool {
    let base = name.split('.').next().unwrap_or(name);
    let upper = base.to_ascii_uppercase();
    matches!(
        upper.as_str(),
        "CON"
            | "PRN"
            | "AUX"
            | "NUL"
            | "COM1"
            | "COM2"
            | "COM3"
            | "COM4"
            | "COM5"
            | "COM6"
            | "COM7"
            | "COM8"
            | "COM9"
            | "LPT1"
            | "LPT2"
            | "LPT3"
            | "LPT4"
            | "LPT5"
            | "LPT6"
            | "LPT7"
            | "LPT8"
            | "LPT9"
    )
}

pub fn sanitize_filename(raw_title: &str, fallback_id: &str) -> String {
    let mut cleaned = String::with_capacity(raw_title.len());
    let mut prev_space = false;
    for ch in raw_title.chars() {
        let forbidden = matches!(
            ch,
            '\\' | '/' | ':' | '*' | '?' | '"' | '<' | '>' | '|' | '\0'..='\x1f'
        );
        if forbidden || ch.is_whitespace() {
            if !prev_space && !cleaned.is_empty() {
                cleaned.push(' ');
                prev_space = true;
            }
        } else {
            cleaned.push(ch);
            prev_space = false;
        }
    }
    let pre_trimmed = cleaned.trim_matches(|c: char| c.is_whitespace() || c == '.');
    let mut byte_bounded = String::with_capacity(pre_trimmed.len().min(MAX_TITLE_BYTES));
    for ch in pre_trimmed.chars() {
        if byte_bounded.len() + ch.len_utf8() > MAX_TITLE_BYTES {
            break;
        }
        byte_bounded.push(ch);
    }
    let final_name = byte_bounded.trim_matches(|c: char| c.is_whitespace() || c == '.');
    if final_name.is_empty() || is_windows_reserved_name(final_name) {
        fallback_id.to_owned()
    } else {
        final_name.to_owned()
    }
}

pub fn resolve_audio_path(
    title: &str,
    video_id: &str,
    extension: &str,
    storage_dir: &Path,
) -> PathBuf {
    let base = sanitize_filename(title, video_id);
    let primary = storage_dir.join(format!("{base}.{extension}"));
    if !primary.exists() {
        return primary;
    }
    if let Some(existing) = find_local_audio(video_id, storage_dir)
        && existing == primary
    {
        return primary;
    }
    storage_dir.join(format!("{base} ({video_id}).{extension}"))
}

pub fn find_local_audio(video_id: &str, storage_dir: &Path) -> Option<PathBuf> {
    if !youtube::valid_video_id(video_id) {
        return None;
    }
    for meta_path in [
        meta_file_path(video_id, storage_dir),
        legacy_meta_file_path(video_id, storage_dir),
    ] {
        if let Some(record) = read_metadata_record(&meta_path) {
            let path = PathBuf::from(&record.file_path);
            if path.is_file() {
                return Some(path);
            }
            let _ = fs::remove_file(&meta_path);
            let thumb = meta_dir(storage_dir).join(format!("{video_id}.jpg"));
            if thumb.is_file() {
                let _ = fs::remove_file(thumb);
            }
        }
    }
    for ext in AUDIO_EXTENSIONS {
        let candidate = storage_dir.join(format!("{video_id}.{ext}"));
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

fn copy_response_body(
    resp: &mut reqwest::blocking::Response,
    file: &mut File,
    buf: &mut [u8],
    cancel: &AtomicBool,
    video_id: &str,
    base_written: u64,
    expected_total: u64,
) -> Result<u64, (String, bool, u64)> {
    let mut chunk_written = 0u64;
    loop {
        if cancel.load(Ordering::Relaxed) {
            return Err(("다운로드가 취소되었습니다.".into(), false, chunk_written));
        }
        let read = resp.read(buf).map_err(|_| {
            (
                "음원 수신 중 네트워크 연결이 끊겼습니다.".to_owned(),
                true,
                chunk_written,
            )
        })?;
        if read == 0 {
            break;
        }
        file.write_all(&buf[..read]).map_err(|_| {
            (
                "음원 파일 쓰기에 실패했습니다.".to_owned(),
                false,
                chunk_written,
            )
        })?;
        chunk_written = chunk_written.saturating_add(read as u64);
        set_track_progress(
            video_id,
            base_written.saturating_add(chunk_written),
            expected_total,
        );
    }
    Ok(chunk_written)
}

fn extract_expected_len(
    resp: &reqwest::blocking::Response,
    is_partial: bool,
    stream_content_length: Option<u64>,
) -> Option<u64> {
    resp.headers()
        .get(reqwest::header::CONTENT_RANGE)
        .and_then(|v| v.to_str().ok())
        .and_then(parse_content_range_total)
        .or_else(|| {
            if !is_partial {
                resp.content_length()
            } else {
                None
            }
        })
        .or(stream_content_length)
}

fn download_stream_to_part(
    client: &reqwest::blocking::Client,
    stream: &youtube::AudioStreamInfo,
    first_response: reqwest::blocking::Response,
    part_path: &Path,
    cancel_flag: &AtomicBool,
) -> Result<u64, (String, bool)> {
    let mut is_partial = first_response.status() == reqwest::StatusCode::PARTIAL_CONTENT;
    let mut expected_len = extract_expected_len(&first_response, is_partial, stream.content_length);
    set_track_progress(&stream.video_id, 0, expected_len.unwrap_or(0));

    let mut file =
        File::create(part_path).map_err(|_| ("임시 파일을 만들지 못했습니다.".into(), false))?;
    let mut buf = [0u8; 64 * 1024];
    let mut total_written = 0u64;

    let mut first_resp = Some(first_response);
    let mut first_ok = false;
    let mut first_err = ("음원 수신 중 네트워크 연결이 끊겼습니다.".to_owned(), true);
    let first_end = RANGE_CHUNK_BYTES - 1;
    for attempt in 0..=MAX_CHUNK_RETRIES {
        if cancel_flag.load(Ordering::Relaxed) {
            drop(file);
            let _ = fs::remove_file(part_path);
            return Err(("다운로드가 취소되었습니다.".into(), false));
        }
        if attempt > 0 {
            let backoff = CHUNK_RETRY_BACKOFF_MS
                .get(attempt - 1)
                .copied()
                .unwrap_or(2200);
            if !sleep_cancelable(backoff, cancel_flag) {
                drop(file);
                let _ = fs::remove_file(part_path);
                return Err(("다운로드가 취소되었습니다.".into(), false));
            }
            let resume_from = if is_partial { total_written } else { 0 };
            if file.seek(SeekFrom::Start(resume_from)).is_err()
                || file.set_len(resume_from).is_err()
            {
                first_err = ("음원 임시 파일 복구에 실패했습니다.".into(), false);
                break;
            }
            let req_end = match expected_len {
                Some(total) => first_end.min(total.saturating_sub(1)),
                None => first_end,
            };
            if resume_from > req_end {
                first_ok = true;
                break;
            }
            match client
                .get(&stream.url)
                .header("User-Agent", &stream.user_agent)
                .header("Range", format!("bytes={resume_from}-{req_end}"))
                .send()
            {
                Ok(r)
                    if matches!(
                        r.status(),
                        reqwest::StatusCode::PARTIAL_CONTENT | reqwest::StatusCode::OK
                    ) =>
                {
                    let got_partial = r.status() == reqwest::StatusCode::PARTIAL_CONTENT;
                    if !got_partial && resume_from > 0 {
                        if file.seek(SeekFrom::Start(0)).is_err() || file.set_len(0).is_err() {
                            first_err = ("음원 임시 파일 복구에 실패했습니다.".into(), false);
                            break;
                        }
                        total_written = 0;
                    }
                    is_partial = got_partial;
                    expected_len = extract_expected_len(&r, is_partial, stream.content_length);
                    set_track_progress(&stream.video_id, total_written, expected_len.unwrap_or(0));
                    first_resp = Some(r);
                }
                Ok(r) => {
                    let status = r.status();
                    first_err = (format!("음원 다운로드 오류 ({status})"), true);
                    if is_permanent_http_status(status) {
                        break;
                    }
                    continue;
                }
                Err(_) => {
                    first_err = ("음원 수신 중 네트워크 연결이 끊겼습니다.".into(), true);
                    continue;
                }
            }
        }
        if let Some(mut resp) = first_resp.take() {
            let base = total_written;
            match copy_response_body(
                &mut resp,
                &mut file,
                &mut buf,
                cancel_flag,
                &stream.video_id,
                base,
                expected_len.unwrap_or(0),
            ) {
                Ok(n) => {
                    total_written = base.saturating_add(n);
                    first_ok = true;
                    break;
                }
                Err((err, fallback, partial)) => {
                    total_written = base.saturating_add(partial);
                    first_err = (err, fallback);
                    if !fallback || cancel_flag.load(Ordering::Relaxed) {
                        break;
                    }
                }
            }
        }
    }
    if !first_ok {
        drop(file);
        let _ = fs::remove_file(part_path);
        return Err(first_err);
    }

    if is_partial {
        while expected_len.is_none_or(|total| total_written < total) {
            if cancel_flag.load(Ordering::Relaxed) {
                drop(file);
                let _ = fs::remove_file(part_path);
                return Err(("다운로드가 취소되었습니다.".into(), false));
            }
            let chunk_end = match expected_len {
                Some(total) => total_written
                    .saturating_add(RANGE_CHUNK_BYTES - 1)
                    .min(total.saturating_sub(1)),
                None => total_written.saturating_add(RANGE_CHUNK_BYTES - 1),
            };
            let mut chunk_ok = false;
            let mut reached_eof = false;
            let mut last_err = ("음원 수신 중 네트워크 연결이 끊겼습니다.".to_owned(), true);

            for attempt in 0..=MAX_CHUNK_RETRIES {
                if cancel_flag.load(Ordering::Relaxed) {
                    drop(file);
                    let _ = fs::remove_file(part_path);
                    return Err(("다운로드가 취소되었습니다.".into(), false));
                }
                if attempt > 0 {
                    let backoff = CHUNK_RETRY_BACKOFF_MS
                        .get(attempt - 1)
                        .copied()
                        .unwrap_or(2200);
                    if !sleep_cancelable(backoff, cancel_flag) {
                        drop(file);
                        let _ = fs::remove_file(part_path);
                        return Err(("다운로드가 취소되었습니다.".into(), false));
                    }
                }
                let resume_start = total_written;
                if resume_start > chunk_end {
                    chunk_ok = true;
                    break;
                }
                if file.seek(SeekFrom::Start(resume_start)).is_err()
                    || file.set_len(resume_start).is_err()
                {
                    last_err = ("음원 임시 파일 복구에 실패했습니다.".into(), false);
                    break;
                }
                let resp = match client
                    .get(&stream.url)
                    .header("User-Agent", &stream.user_agent)
                    .header("Range", format!("bytes={resume_start}-{chunk_end}"))
                    .send()
                {
                    Ok(r) => r,
                    Err(_) => {
                        last_err = ("음원 수신 중 네트워크 연결이 끊겼습니다.".into(), true);
                        continue;
                    }
                };
                let status = resp.status();
                if status == reqwest::StatusCode::RANGE_NOT_SATISFIABLE {
                    reached_eof = true;
                    chunk_ok = true;
                    break;
                }
                if status == reqwest::StatusCode::OK {
                    last_err = (
                        "서버가 부분 이어받기(Range)를 지원하지 않습니다.".into(),
                        true,
                    );
                    break;
                }
                if status != reqwest::StatusCode::PARTIAL_CONTENT {
                    last_err = (format!("음원 다운로드 오류 ({status})"), true);
                    if is_permanent_http_status(status) {
                        break;
                    }
                    continue;
                }
                let mut resp = resp;
                match copy_response_body(
                    &mut resp,
                    &mut file,
                    &mut buf,
                    cancel_flag,
                    &stream.video_id,
                    resume_start,
                    expected_len.unwrap_or(0),
                ) {
                    Ok(0) => {
                        reached_eof = true;
                        chunk_ok = true;
                        break;
                    }
                    Ok(n) => {
                        total_written = resume_start.saturating_add(n);
                        if let Some(total) = expected_len
                            && total_written > total
                        {
                            last_err =
                                ("수신된 음원 크기가 예상 크기를 초과했습니다.".into(), true);
                            break;
                        }
                        chunk_ok = true;
                        break;
                    }
                    Err((err, fallback, partial)) => {
                        total_written = resume_start.saturating_add(partial);
                        last_err = (err, fallback);
                        if !fallback || cancel_flag.load(Ordering::Relaxed) {
                            break;
                        }
                    }
                }
            }
            if !chunk_ok {
                drop(file);
                let _ = fs::remove_file(part_path);
                return Err(last_err);
            }
            if reached_eof {
                break;
            }
        }
    }
    if file.flush().is_err() {
        drop(file);
        let _ = fs::remove_file(part_path);
        return Err(("음원 파일 저장을 완료하지 못했습니다.".into(), false));
    }
    drop(file);

    if total_written == 0 {
        let _ = fs::remove_file(part_path);
        return Err(("다운로드된 음원 크기가 0바이트입니다.".into(), true));
    }
    if let Some(expected) = expected_len
        && expected > 0
        && total_written != expected
    {
        let _ = fs::remove_file(part_path);
        return Err(("다운로드가 중단되어 음원 파일이 불완전합니다.".into(), true));
    }
    if !validate_downloaded_container(part_path, &stream.extension) {
        let _ = fs::remove_file(part_path);
        return Err(("손상되었거나 유효하지 않은 오디오 파일입니다.".into(), true));
    }
    Ok(total_written)
}

pub fn download_track(track: &TrackSummary, storage_dir: &Path) -> Result<DownloadedTrack, String> {
    download_track_with_options(track, storage_dir, &DownloadOptions::default())
        .map_err(|err| err.message)
}

pub fn download_track_with_options(
    track: &TrackSummary,
    storage_dir: &Path,
    options: &DownloadOptions,
) -> Result<DownloadedTrack, DownloadError> {
    if !youtube::valid_video_id(&track.video_id) {
        return Err(DownloadError::plain("올바른 영상 ID가 아닙니다."));
    }
    fs::create_dir_all(storage_dir)
        .map_err(|_| DownloadError::plain("저장 폴더를 생성하지 못했습니다."))?;
    let nomedia_path = storage_dir.join(".nomedia");
    if !nomedia_path.exists() {
        let _ = fs::write(&nomedia_path, b"");
    }
    let hidden_meta_dir = meta_dir(storage_dir);
    fs::create_dir_all(&hidden_meta_dir)
        .map_err(|_| DownloadError::plain("메타데이터 폴더를 생성하지 못했습니다."))?;

    let existing_valid = {
        let _guard = FINALIZE_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(existing) = find_local_audio(&track.video_id, storage_dir) {
            let extension = existing
                .extension()
                .and_then(|e| e.to_str())
                .unwrap_or("m4a")
                .to_owned();
            if validate_audio_header(&existing, &extension) {
                let bytes = fs::metadata(&existing).map(|m| m.len()).unwrap_or(0);
                let record = DownloadedTrack {
                    video_id: track.video_id.clone(),
                    title: track.title.clone(),
                    artist: track.artist.clone(),
                    duration: track.duration.clone(),
                    thumbnail: track.thumbnail.clone(),
                    file_path: existing.to_string_lossy().into_owned(),
                    extension,
                    bytes,
                };
                let existing_meta =
                    read_metadata_record(&meta_file_path(&track.video_id, storage_dir));
                let needs_meta_update = existing_meta.as_ref().is_none_or(|m| {
                    m.file_path != record.file_path
                        || m.bytes != record.bytes
                        || m.title != record.title
                        || m.artist != record.artist
                });
                if needs_meta_update {
                    let _ = write_metadata(&record, storage_dir);
                }
                Some(record)
            } else {
                let _ = fs::remove_file(&existing);
                let _ = fs::remove_file(meta_file_path(&track.video_id, storage_dir));
                let _ = fs::remove_file(legacy_meta_file_path(&track.video_id, storage_dir));
                None
            }
        } else {
            None
        }
    };
    if let Some(record) = existing_valid {
        spawn_cache_thumbnail_async(&track.video_id, &track.thumbnail, storage_dir);
        return Ok(record);
    }

    let cancel_flag = register_download_cancel(&track.video_id);
    set_track_progress(&track.video_id, 0, 0);
    let result = (|| -> Result<DownloadedTrack, DownloadError> {
        let client = youtube::download_http_client().map_err(DownloadError::plain)?;
        let sabr_client = youtube::sabr_http_client().map_err(DownloadError::plain)?;
        let preferred = options.format;
        let fallback_codec = preferred.fallback();
        let mut last_status = String::from("오디오 스트림 다운로드에 실패했습니다.");
        let mut saw_stream_protection = false;
        let mut completed: Option<(PathBuf, String, AudioFormat, u64)> = None;

        let try_download_candidate = |stream: &youtube::AudioStreamInfo,
                                      last_status: &mut String|
         -> Result<
            Option<(PathBuf, String, AudioFormat, u64)>,
            DownloadError,
        > {
            if cancel_flag.load(Ordering::Relaxed) {
                return Err(DownloadError::plain("다운로드가 취소되었습니다."));
            }
            if !stream.mime_type.starts_with("audio/") {
                return Ok(None);
            }
            let first_end = RANGE_CHUNK_BYTES - 1;
            let first_response = match client
                .get(&stream.url)
                .header("User-Agent", &stream.user_agent)
                .header("Range", format!("bytes=0-{first_end}"))
                .send()
            {
                Ok(r)
                    if matches!(
                        r.status(),
                        reqwest::StatusCode::PARTIAL_CONTENT | reqwest::StatusCode::OK
                    ) =>
                {
                    r
                }
                Ok(r) => {
                    *last_status = format!("음원 다운로드 오류 ({})", r.status());
                    return Ok(None);
                }
                Err(_) => {
                    *last_status = "음원 서버에 연결하지 못했습니다.".into();
                    return Ok(None);
                }
            };
            let unique_ts = SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0);
            let part_path = hidden_meta_dir.join(format!(
                "{}.{}.{}.part",
                track.video_id, unique_ts, stream.extension
            ));
            match download_stream_to_part(client, stream, first_response, &part_path, &cancel_flag)
            {
                Ok(total_written) => Ok(Some((
                    part_path,
                    stream.extension.clone(),
                    stream.codec,
                    total_written,
                ))),
                Err((err, true)) => {
                    *last_status = err;
                    Ok(None)
                }
                Err((err, false)) => Err(DownloadError::plain(err)),
            }
        };

        let mut sabr_partials = HashMap::new();
        let mut protected_anonymous_clients = HashSet::new();
        let mut try_download_sabr =
            |spec: &sabr::SabrAudioSpec,
             audio: &sabr::SabrAdaptiveFormat,
             last_status: &mut String,
             saw_protection: &mut bool|
             -> Result<Option<(PathBuf, String, AudioFormat, u64)>, DownloadError> {
                if cancel_flag.load(Ordering::Relaxed) {
                    return Err(DownloadError::plain("다운로드가 취소되었습니다."));
                }
                let client_id = spec.client_info.client_name_id;
                let anonymous = spec.po_token.as_ref().is_none_or(Vec::is_empty);
                if anonymous && protected_anonymous_clients.contains(&client_id) {
                    return Ok(None);
                }
                let key = (
                    audio.format_id(),
                    audio.content_length,
                    audio.audio_track_id.clone(),
                    audio.mime_type.clone(),
                );
                let partial = sabr_partials.entry(key.clone()).or_insert_with(|| {
                    let unique_ts = SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map(|d| d.as_nanos())
                        .unwrap_or(0);
                    SabrPartial::new(hidden_meta_dir.join(format!(
                        "{}.{}.{}.{}.part",
                        track.video_id, audio.itag, unique_ts, audio.extension
                    )))
                });
                let part_path = partial.path.as_deref().expect("SABR partial path");
                let vid = &track.video_id;
                let codec = if audio.is_opus() {
                    AudioFormat::Opus
                } else {
                    AudioFormat::M4a
                };
                match sabr::resume_sabr_audio(
                    sabr_client,
                    spec,
                    audio,
                    part_path,
                    &mut partial.segments,
                    &cancel_flag,
                    |done, total| set_track_progress(vid, done, total),
                ) {
                    Ok(total_written) => {
                        if !validate_downloaded_container(part_path, &audio.extension) {
                            sabr_partials.remove(&key);
                            *last_status =
                                "손상되었거나 유효하지 않은 SABR 오디오 파일입니다.".into();
                            return Ok(None);
                        }
                        Ok(Some((
                            partial.path.take().expect("SABR partial path"),
                            audio.extension.clone(),
                            codec,
                            total_written,
                        )))
                    }
                    Err(err) => {
                        if audio.lmt <= 0 {
                            sabr_partials.remove(&key);
                        }
                        if err.is_stream_protection() {
                            *saw_protection = true;
                            if anonymous {
                                protected_anonymous_clients.insert(client_id);
                            }
                        }
                        if err.is_retryable() {
                            *last_status = err.message;
                            Ok(None)
                        } else {
                            Err(DownloadError::plain(err.message))
                        }
                    }
                }
            };

        if let Some(session_input) = options.sabr_session.as_ref()
            && let Some(spec) =
                youtube::build_web_sabr_spec(&track.video_id, session_input, preferred)
        {
            for audio in &spec.audio_formats {
                if let Some(done) =
                    try_download_sabr(&spec, audio, &mut last_status, &mut saw_stream_protection)?
                {
                    completed = Some(done);
                    break;
                }
            }
        }

        if completed.is_none() {
            for round in 0..MAX_AUDIO_DOWNLOAD_ROUNDS {
                if cancel_flag.load(Ordering::Relaxed) {
                    return Err(DownloadError::plain("다운로드가 취소되었습니다."));
                }
                if round > 0 {
                    youtube::reset_visitor_data();
                    let backoff = AUDIO_ROUND_BACKOFF_MS
                        .get(round - 1)
                        .copied()
                        .unwrap_or(4000);
                    if !sleep_cancelable(backoff, &cancel_flag) {
                        return Err(DownloadError::plain("다운로드가 취소되었습니다."));
                    }
                }
                let mut resolved_profiles = Vec::new();
                for profile_idx in 0..youtube::player_profile_count() {
                    if cancel_flag.load(Ordering::Relaxed) {
                        return Err(DownloadError::plain("다운로드가 취소되었습니다."));
                    }
                    let resolved = match youtube::resolve_player_streams_for_profile_with_format(
                        &track.video_id,
                        profile_idx,
                        preferred,
                        Some(&cancel_flag),
                    ) {
                        Ok(r) => r,
                        Err((err, false)) => return Err(DownloadError::plain(err)),
                        Err((err, true)) => {
                            last_status = err;
                            continue;
                        }
                    };
                    if let Some(spec) = &resolved.sabr {
                        for audio in spec
                            .audio_formats
                            .iter()
                            .filter(|a| preferred.matches_sabr(a))
                        {
                            if let Some(done) = try_download_sabr(
                                spec,
                                audio,
                                &mut last_status,
                                &mut saw_stream_protection,
                            )? {
                                completed = Some(done);
                                break;
                            }
                        }
                    }
                    if completed.is_some() {
                        break;
                    }
                    resolved_profiles.push(resolved);
                }
                if completed.is_some() {
                    break;
                }
                'formats: for codec in [preferred, fallback_codec] {
                    if codec == fallback_codec {
                        for spec in resolved_profiles.iter().filter_map(|r| r.sabr.as_ref()) {
                            for audio in spec.audio_formats.iter().filter(|a| codec.matches_sabr(a))
                            {
                                if let Some(done) = try_download_sabr(
                                    spec,
                                    audio,
                                    &mut last_status,
                                    &mut saw_stream_protection,
                                )? {
                                    completed = Some(done);
                                    break 'formats;
                                }
                            }
                        }
                    }
                    for stream in resolved_profiles
                        .iter()
                        .flat_map(|r| &r.direct_audio)
                        .filter(|s| s.codec == codec)
                    {
                        if let Some(done) = try_download_candidate(stream, &mut last_status)? {
                            completed = Some(done);
                            break 'formats;
                        }
                    }
                }
                if completed.is_some() {
                    break;
                }
            }
        }

        let Some((raw_part_path, raw_extension, codec, raw_written)) = completed else {
            return Err(if saw_stream_protection {
                DownloadError::with_code(
                    "YouTube 스트림 보호(PO 토큰) 검증이 필요해 다운로드를 완료할 수 없습니다.",
                    "stream_protection",
                )
            } else {
                DownloadError::plain(last_status)
            });
        };

        let (final_part_path, final_extension, final_bytes) = if codec == AudioFormat::Opus
            && raw_extension == "webm"
        {
            let unique_ts = SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0);
            let opus_part_path =
                hidden_meta_dir.join(format!("{}.{}.opus.part", track.video_id, unique_ts));
            let cover = read_or_fetch_cover_jpeg(&track.video_id, &track.thumbnail, storage_dir);
            let metadata = OpusMetadata {
                title: &track.title,
                artist: &track.artist,
                cover_jpeg: cover.as_deref(),
            };
            match opus_mux::remux_webm_to_ogg_opus(
                &raw_part_path,
                &opus_part_path,
                &metadata,
                &track.video_id,
            ) {
                Ok(opus_bytes) if validate_downloaded_container(&opus_part_path, "opus") => {
                    let _ = fs::remove_file(&raw_part_path);
                    (opus_part_path, "opus".to_owned(), opus_bytes)
                }
                Ok(_) | Err(_) => {
                    let _ = fs::remove_file(&opus_part_path);
                    if !validate_audio_header(&raw_part_path, "webm") {
                        let _ = fs::remove_file(&raw_part_path);
                        return Err(DownloadError::plain(
                            "Opus 오디오 컨테이너 생성에 실패했습니다.",
                        ));
                    }
                    (raw_part_path, raw_extension, raw_written)
                }
            }
        } else {
            if !validate_downloaded_container(&raw_part_path, &raw_extension) {
                let _ = fs::remove_file(&raw_part_path);
                return Err(DownloadError::plain(
                    "손상되었거나 유효하지 않은 오디오 파일입니다.",
                ));
            }
            (raw_part_path, raw_extension, raw_written)
        };

        let record = {
            let _guard = FINALIZE_LOCK
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            let final_path =
                resolve_audio_path(&track.title, &track.video_id, &final_extension, storage_dir);
            if final_path.exists() {
                let _ = fs::remove_file(&final_path);
            }
            if fs::rename(&final_part_path, &final_path).is_err() {
                let _ = fs::remove_file(&final_part_path);
                return Err(DownloadError::plain("음원 파일 이동에 실패했습니다."));
            }

            let record = DownloadedTrack {
                video_id: track.video_id.clone(),
                title: track.title.clone(),
                artist: track.artist.clone(),
                duration: track.duration.clone(),
                thumbnail: track.thumbnail.clone(),
                file_path: final_path.to_string_lossy().into_owned(),
                extension: final_extension,
                bytes: final_bytes,
            };
            if let Err(err) = write_metadata(&record, storage_dir) {
                let _ = fs::remove_file(&final_path);
                return Err(DownloadError::plain(err));
            }
            record
        };
        spawn_cache_thumbnail_async(&track.video_id, &track.thumbnail, storage_dir);
        Ok(record)
    })();
    clear_track_progress(&track.video_id);
    unregister_download_cancel(&track.video_id, &cancel_flag);
    result
}

fn write_metadata(record: &DownloadedTrack, storage_dir: &Path) -> Result<(), String> {
    let dir = meta_dir(storage_dir);
    fs::create_dir_all(&dir).map_err(|_| "메타데이터 폴더 생성 실패")?;
    let meta_path = meta_file_path(&record.video_id, storage_dir);
    let unique_ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let tmp_path = dir.join(format!(".{}.{}.json.tmp", record.video_id, unique_ts));
    let bytes = serde_json::to_vec_pretty(record).map_err(|_| "메타데이터 직렬화 실패")?;
    fs::write(&tmp_path, bytes).map_err(|_| "메타데이터 임시 저장 실패")?;
    if fs::rename(&tmp_path, &meta_path).is_err() {
        let _ = fs::remove_file(&meta_path);
        if fs::rename(&tmp_path, &meta_path).is_err() {
            let _ = fs::remove_file(&tmp_path);
            return Err("메타데이터 저장 실패".into());
        }
    }
    Ok(())
}

fn collect_metadata_tracks(
    dir: &Path,
    storage_dir: &Path,
    seen: &mut std::collections::HashSet<String>,
    tracks: &mut Vec<DownloadedTrack>,
) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let Some(record) = read_metadata_record(&path) else {
            let _ = fs::remove_file(&path);
            continue;
        };
        if Path::new(&record.file_path).is_file() {
            if seen.insert(record.video_id.clone()) {
                tracks.push(record);
            }
        } else {
            let _ = fs::remove_file(&path);
            let thumb = meta_dir(storage_dir).join(format!("{}.jpg", record.video_id));
            if thumb.is_file() {
                let _ = fs::remove_file(thumb);
            }
        }
    }
}

fn cleanup_stale_temp_files(storage_dir: &Path) {
    let dir = meta_dir(storage_dir);
    let Ok(entries) = fs::read_dir(&dir) else {
        return;
    };
    let now = SystemTime::now();
    for entry in entries.flatten() {
        let path = entry.path();
        let ext = path.extension().and_then(|e| e.to_str());
        if !matches!(ext, Some("part") | Some("tmp")) {
            continue;
        }
        let is_stale = entry
            .metadata()
            .ok()
            .and_then(|m| m.modified().ok())
            .and_then(|modified| now.duration_since(modified).ok())
            .is_some_and(|age| age.as_secs() >= STALE_TEMP_FILE_AGE_SECS);
        if is_stale {
            let _ = fs::remove_file(path);
        }
    }
}

pub fn list_downloaded(storage_dir: &Path) -> Result<Vec<DownloadedTrack>, String> {
    if !storage_dir.exists() {
        return Ok(Vec::new());
    }
    let _guard = FINALIZE_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    cleanup_stale_temp_files(storage_dir);
    let mut seen = std::collections::HashSet::new();
    let mut tracks = Vec::new();
    collect_metadata_tracks(&meta_dir(storage_dir), storage_dir, &mut seen, &mut tracks);
    collect_metadata_tracks(storage_dir, storage_dir, &mut seen, &mut tracks);
    tracks.sort_by(|a, b| a.title.to_lowercase().cmp(&b.title.to_lowercase()));
    Ok(tracks)
}

pub fn delete_downloaded(video_id: &str, storage_dir: &Path) -> Result<bool, String> {
    if !youtube::valid_video_id(video_id) {
        return Err("올바른 영상 ID가 아닙니다.".into());
    }
    let _guard = FINALIZE_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let mut removed = false;
    for meta_path in [
        meta_file_path(video_id, storage_dir),
        legacy_meta_file_path(video_id, storage_dir),
    ] {
        if let Some(record) = read_metadata_record(&meta_path) {
            let audio_path = Path::new(&record.file_path);
            if audio_path.is_file() && fs::remove_file(audio_path).is_ok() {
                removed = true;
            }
        }
        if meta_path.is_file() {
            let _ = fs::remove_file(meta_path);
        }
    }
    for ext in AUDIO_EXTENSIONS {
        let candidate = storage_dir.join(format!("{video_id}.{ext}"));
        if candidate.is_file() && fs::remove_file(candidate).is_ok() {
            removed = true;
        }
    }
    let thumb = meta_dir(storage_dir).join(format!("{video_id}.jpg"));
    if thumb.is_file() {
        let _ = fs::remove_file(thumb);
    }
    Ok(removed)
}

pub fn storage_usage(storage_dir: &Path) -> Result<StorageUsage, String> {
    let tracks = list_downloaded(storage_dir)?;
    let used_bytes = tracks
        .iter()
        .fold(0u64, |acc, item| acc.saturating_add(item.bytes));
    Ok(StorageUsage {
        used_bytes,
        item_count: tracks.len() as u64,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_content_range_total_length() {
        assert_eq!(
            parse_content_range_total("bytes 0-2097151/9876543"),
            Some(9876543)
        );
        assert_eq!(parse_content_range_total("bytes 0-100/*"), None);
        assert_eq!(parse_content_range_total("invalid"), None);
    }

    #[test]
    fn sanitizes_song_title_for_filename() {
        assert_eq!(
            sanitize_filename("  IU: Blueming / Official?  ", "dQw4w9WgXcQ"),
            "IU Blueming Official"
        );
        assert_eq!(sanitize_filename("...:::***", "dQw4w9WgXcQ"), "dQw4w9WgXcQ");
        assert_eq!(sanitize_filename("CON", "dQw4w9WgXcQ"), "dQw4w9WgXcQ");
        assert_eq!(sanitize_filename("nul.txt", "dQw4w9WgXcQ"), "dQw4w9WgXcQ");
        let long_korean = "가".repeat(120);
        let sanitized = sanitize_filename(&long_korean, "dQw4w9WgXcQ");
        assert!(sanitized.len() <= MAX_TITLE_BYTES);
        assert!(!sanitized.is_empty());
    }

    #[test]
    fn pre_cancel_is_applied_when_download_registers_shortly_after() {
        let vid = "zzzzzzzzz01";
        cancel_track_download(vid);
        let flag = register_download_cancel(vid);
        assert!(flag.load(Ordering::Relaxed));
        unregister_download_cancel(vid, &flag);
        let flag2 = register_download_cancel(vid);
        assert!(!flag2.load(Ordering::Relaxed));
        unregister_download_cancel(vid, &flag2);
    }

    #[test]
    fn resolves_title_filename_and_handles_collisions() {
        let temp =
            std::env::temp_dir().join(format!("replica_music_dl_test_{}", std::process::id()));
        let _ = fs::remove_dir_all(&temp);
        fs::create_dir_all(&temp).unwrap();

        let first = resolve_audio_path("Night Drive", "aaaaaaaaaaa", "m4a", &temp);
        assert_eq!(first.file_name().unwrap(), "Night Drive.m4a");
        fs::write(&first, b"audio-1").unwrap();

        let record = DownloadedTrack {
            video_id: "aaaaaaaaaaa".into(),
            title: "Night Drive".into(),
            artist: "Artist".into(),
            duration: "3:00".into(),
            thumbnail: String::new(),
            file_path: first.to_string_lossy().into_owned(),
            extension: "m4a".into(),
            bytes: 7,
        };
        write_metadata(&record, &temp).unwrap();

        let same_track = resolve_audio_path("Night Drive", "aaaaaaaaaaa", "m4a", &temp);
        assert_eq!(same_track, first);

        let collision = resolve_audio_path("Night Drive", "bbbbbbbbbbb", "m4a", &temp);
        assert_eq!(
            collision.file_name().unwrap(),
            "Night Drive (bbbbbbbbbbb).m4a"
        );

        let listed = list_downloaded(&temp).unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].video_id, "aaaaaaaaaaa");

        let thumb = meta_dir(&temp).join("aaaaaaaaaaa.jpg");
        fs::write(&thumb, vec![1u8; 64]).unwrap();

        assert!(delete_downloaded("aaaaaaaaaaa", &temp).unwrap());
        assert!(!first.exists());
        assert!(!thumb.exists());
        assert!(list_downloaded(&temp).unwrap().is_empty());

        let _ = fs::remove_dir_all(&temp);
    }

    #[test]
    fn validates_audio_container_headers_and_rejects_corrupt_files() {
        let temp =
            std::env::temp_dir().join(format!("replica_music_hdr_test_{}", std::process::id()));
        let _ = fs::remove_dir_all(&temp);
        fs::create_dir_all(&temp).unwrap();

        let valid_m4a = temp.join("valid.m4a");
        let mut m4a_bytes = vec![0u8; 2048];
        m4a_bytes[4..8].copy_from_slice(b"ftyp");
        fs::write(&valid_m4a, &m4a_bytes).unwrap();
        assert!(validate_audio_header(&valid_m4a, "m4a"));

        let valid_webm = temp.join("valid.webm");
        let mut webm_bytes = vec![0u8; 2048];
        webm_bytes[0..4].copy_from_slice(&[0x1A, 0x45, 0xDF, 0xA3]);
        fs::write(&valid_webm, &webm_bytes).unwrap();
        assert!(validate_audio_header(&valid_webm, "webm"));

        let valid_opus = temp.join("valid.opus");
        let mut opus_bytes = vec![0u8; 2048];
        opus_bytes[0..4].copy_from_slice(b"OggS");
        fs::write(&valid_opus, &opus_bytes).unwrap();
        assert!(validate_audio_header(&valid_opus, "opus"));

        let corrupt_m4a = temp.join("corrupt.m4a");
        fs::write(&corrupt_m4a, vec![0xFFu8; 2048]).unwrap();
        assert!(!validate_audio_header(&corrupt_m4a, "m4a"));

        let corrupt_opus = temp.join("corrupt.opus");
        fs::write(&corrupt_opus, vec![0xFFu8; 2048]).unwrap();
        assert!(!validate_audio_header(&corrupt_opus, "opus"));

        let tiny_m4a = temp.join("tiny.m4a");
        fs::write(&tiny_m4a, b"\x00\x00\x00\x20ftypM4A ").unwrap();
        assert!(!validate_audio_header(&tiny_m4a, "m4a"));

        let _ = fs::remove_dir_all(&temp);
    }

    #[test]
    fn cleans_up_orphaned_metadata_when_audio_deleted_externally() {
        let temp =
            std::env::temp_dir().join(format!("replica_music_orphan_test_{}", std::process::id()));
        let _ = fs::remove_dir_all(&temp);
        fs::create_dir_all(&temp).unwrap();

        let audio = temp.join("External Song.m4a");
        fs::write(&audio, vec![0u8; 2048]).unwrap();
        let record = DownloadedTrack {
            video_id: "ccccccccccc".into(),
            title: "External Song".into(),
            artist: "Artist".into(),
            duration: "2:30".into(),
            thumbnail: String::new(),
            file_path: audio.to_string_lossy().into_owned(),
            extension: "m4a".into(),
            bytes: 2048,
        };
        write_metadata(&record, &temp).unwrap();
        let thumb = meta_dir(&temp).join("ccccccccccc.jpg");
        fs::write(&thumb, vec![1u8; 512]).unwrap();

        assert_eq!(list_downloaded(&temp).unwrap().len(), 1);
        fs::remove_file(&audio).unwrap();

        assert!(list_downloaded(&temp).unwrap().is_empty());
        assert!(!meta_file_path("ccccccccccc", &temp).exists());
        assert!(!thumb.exists());

        let _ = fs::remove_dir_all(&temp);
    }

    #[test]
    #[ignore]
    fn live_downloads_real_youtube_audio_via_sabr_and_direct() {
        let temp_opus =
            std::env::temp_dir().join(format!("replica_music_live_opus_{}", std::process::id()));
        let temp_m4a =
            std::env::temp_dir().join(format!("replica_music_live_m4a_{}", std::process::id()));
        let _ = fs::remove_dir_all(&temp_opus);
        let _ = fs::remove_dir_all(&temp_m4a);
        fs::create_dir_all(&temp_opus).unwrap();
        fs::create_dir_all(&temp_m4a).unwrap();

        let track = TrackSummary {
            video_id: "dQw4w9WgXcQ".into(),
            title: "Never Gonna Give You Up".into(),
            artist: "Rick Astley".into(),
            duration: "3:33".into(),
            thumbnail: "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg".into(),
            set_video_id: None,
        };

        let opus_dl = download_track_with_options(
            &track,
            &temp_opus,
            &DownloadOptions {
                format: AudioFormat::Opus,
                sabr_session: None,
            },
        )
        .expect("Opus download_track failed");
        eprintln!(
            "OPUS OK: ext={} bytes={} path={}",
            opus_dl.extension, opus_dl.bytes, opus_dl.file_path
        );
        assert_eq!(opus_dl.extension, "opus");
        assert!(opus_dl.bytes > 1_000_000);
        assert!(opus_mux::validate_ogg_opus_file(Path::new(
            &opus_dl.file_path
        )));

        let m4a_dl = download_track_with_options(
            &track,
            &temp_m4a,
            &DownloadOptions {
                format: AudioFormat::M4a,
                sabr_session: None,
            },
        )
        .expect("M4A download_track failed");
        eprintln!(
            "M4A OK: ext={} bytes={} path={}",
            m4a_dl.extension, m4a_dl.bytes, m4a_dl.file_path
        );
        assert_eq!(m4a_dl.extension, "m4a");
        assert!(m4a_dl.bytes > 1_000_000);
        assert!(sabr::validate_mp4_file(Path::new(&m4a_dl.file_path)));
        assert!(temp_m4a.join(".nomedia").exists());

        let android_resolved = youtube::resolve_player_streams_for_profile_with_format(
            "dQw4w9WgXcQ",
            1,
            AudioFormat::Opus,
            None,
        )
        .expect("ANDROID resolve failed");
        let spec = android_resolved.sabr.expect("ANDROID missing SABR spec");
        let cancel = AtomicBool::new(false);
        for codec in [AudioFormat::Opus, AudioFormat::M4a] {
            let stream = spec
                .audio_formats
                .iter()
                .find(|format| codec.matches_sabr(format))
                .expect("ANDROID missing requested SABR format");
            let sabr_part = temp_opus.join(format!("sabr_android.{}", stream.extension));
            let mut last_done = 0;
            let sabr_bytes = sabr::download_sabr_audio(
                youtube::sabr_http_client().unwrap(),
                &spec,
                stream,
                &sabr_part,
                &cancel,
                |done, _total| last_done = done,
            )
            .expect("ANDROID SABR download failed");
            assert_eq!(last_done, sabr_bytes);
            assert!(validate_downloaded_container(&sabr_part, &stream.extension));
        }

        let _ = fs::remove_dir_all(&temp_opus);
        let _ = fs::remove_dir_all(&temp_m4a);
    }
}
