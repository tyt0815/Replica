use serde::{Deserialize, Serialize};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::{LazyLock, Mutex},
    time::{SystemTime, UNIX_EPOCH},
};

const MAX_ERROR_LOGS: usize = 50;
const QUEUE_FILE_NAME: &str = "pending_error_reports.json";
static ERROR_REPORT_LOCK: LazyLock<Mutex<()>> = LazyLock::new(|| Mutex::new(()));

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PendingErrorReport {
    pub id: String,
    pub fingerprint: String,
    pub title: String,
    pub body: String,
    pub created_at_ms: u64,
    #[serde(default)]
    pub attempts: u32,
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn queue_path(data_dir: &Path) -> PathBuf {
    data_dir.join(QUEUE_FILE_NAME)
}

pub fn load_queue(data_dir: &Path) -> Vec<PendingErrorReport> {
    let path = queue_path(data_dir);
    let Ok(raw) = fs::read_to_string(path) else {
        return Vec::new();
    };
    let mut items: Vec<PendingErrorReport> = serde_json::from_str(&raw).unwrap_or_default();
    items.sort_by(|a, b| b.created_at_ms.cmp(&a.created_at_ms));
    items
}

fn save_queue(data_dir: &Path, queue: &[PendingErrorReport]) -> Result<(), String> {
    fs::create_dir_all(data_dir).map_err(|e| format!("오류 로그 디렉터리 생성 실패: {e}"))?;
    let serialized =
        serde_json::to_string_pretty(queue).map_err(|e| format!("오류 로그 직렬화 실패: {e}"))?;
    let target = queue_path(data_dir);
    let tmp = data_dir.join(format!(".{QUEUE_FILE_NAME}.{}.tmp", now_ms()));
    fs::write(&tmp, serialized).map_err(|e| format!("오류 로그 임시 저장 실패: {e}"))?;
    if fs::rename(&tmp, &target).is_err() {
        let _ = fs::remove_file(&target);
        if fs::rename(&tmp, &target).is_err() {
            let _ = fs::remove_file(&tmp);
            return Err("오류 로그 저장 실패".into());
        }
    }
    Ok(())
}

pub fn enqueue_error_report(
    data_dir: &Path,
    title: &str,
    body: &str,
    fingerprint: &str,
) -> Result<usize, String> {
    let trimmed_title = title.trim();
    let trimmed_body = body.trim();
    if trimmed_title.is_empty() || trimmed_body.is_empty() {
        return Err("오류 제목과 내용이 비어 있습니다.".into());
    }
    let fp = if fingerprint.trim().is_empty() {
        trimmed_title.to_string()
    } else {
        fingerprint.trim().to_string()
    };

    let _guard = ERROR_REPORT_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let mut queue = load_queue(data_dir);
    queue.retain(|item| item.fingerprint != fp);

    let ts = now_ms();
    queue.insert(
        0,
        PendingErrorReport {
            id: format!("err-{ts}-{}", queue.len()),
            fingerprint: fp,
            title: trimmed_title.chars().take(160).collect(),
            body: trimmed_body.chars().take(12000).collect(),
            created_at_ms: ts,
            attempts: 0,
        },
    );

    if queue.len() > MAX_ERROR_LOGS {
        queue.truncate(MAX_ERROR_LOGS);
    }

    save_queue(data_dir, &queue)?;
    Ok(queue.len())
}

pub fn clear_error_reports(data_dir: &Path) -> Result<(), String> {
    let _guard = ERROR_REPORT_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let path = queue_path(data_dir);
    if path.exists() {
        fs::remove_file(path).map_err(|e| format!("오류 로그 삭제 실패: {e}"))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn enqueues_deduplicates_and_persists_error_reports() {
        let dir = std::env::temp_dir().join(format!("replica_music_err_test_{}", now_ms()));
        let _ = fs::remove_dir_all(&dir);

        let count1 = enqueue_error_report(&dir, "Playback failed", "stack trace", "fp-1").unwrap();
        assert_eq!(count1, 1);

        let count2 =
            enqueue_error_report(&dir, "Playback failed", "stack trace 2", "fp-1").unwrap();
        assert_eq!(count2, 1);

        std::thread::sleep(std::time::Duration::from_millis(5));
        let count3 = enqueue_error_report(&dir, "Another error", "details", "fp-2").unwrap();
        assert_eq!(count3, 2);

        let loaded = load_queue(&dir);
        assert_eq!(loaded.len(), 2);
        assert_eq!(loaded[0].fingerprint, "fp-2");
        assert_eq!(loaded[1].fingerprint, "fp-1");

        clear_error_reports(&dir).unwrap();
        assert!(load_queue(&dir).is_empty());
        let _ = fs::remove_dir_all(&dir);
    }
}
