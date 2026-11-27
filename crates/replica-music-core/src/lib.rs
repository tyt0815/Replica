pub mod auth;
pub mod download;
pub mod error_report;
pub mod opus_mux;
pub mod playlist;
pub mod sabr;
pub mod update;
pub mod youtube;

use auth::WebSession;
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    ffi::{CStr, CString, c_char},
    path::Path,
};
use youtube::TrackSummary;

pub const CORE_VERSION: &str = env!("CARGO_PKG_VERSION");

fn into_c_string(value: impl Into<String>) -> *mut c_char {
    let sanitized = value.into().replace('\0', "");
    CString::new(sanitized)
        .map(CString::into_raw)
        .unwrap_or(std::ptr::null_mut())
}

fn read_c_str(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    let c_str = unsafe { CStr::from_ptr(ptr) };
    c_str.to_str().ok().map(ToOwned::to_owned)
}

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
enum CoreRequest {
    Search {
        query: String,
        session: Option<WebSession>,
    },
    ListPlaylists {
        session: WebSession,
    },
    AccountProfile {
        session: WebSession,
    },
    PlaylistTracks {
        playlist_id: String,
        session: Option<WebSession>,
    },
    CreatePlaylist {
        title: String,
        #[serde(default)]
        remote_title: Option<String>,
        session: WebSession,
    },
    RenamePlaylist {
        playlist_id: String,
        new_remote_title: String,
        session: WebSession,
    },
    AddToPlaylist {
        playlist_id: String,
        video_id: String,
        #[serde(default)]
        new_remote_title: Option<String>,
        session: WebSession,
    },
    RemoveFromPlaylist {
        playlist_id: String,
        video_id: String,
        set_video_id: Option<String>,
        #[serde(default)]
        new_remote_title: Option<String>,
        session: WebSession,
    },
    DeletePlaylist {
        playlist_id: String,
        session: WebSession,
    },
    SyncPlaylistTracks {
        playlist_id: String,
        video_ids: Vec<String>,
        #[serde(default)]
        new_remote_title: Option<String>,
        session: WebSession,
    },
    RecordHistoryTrack {
        playlist_id: String,
        video_id: String,
        #[serde(default)]
        track: Option<TrackSummary>,
        #[serde(default)]
        existing_set_video_id: Option<String>,
        #[serde(default)]
        playlist_loaded: bool,
        #[serde(default)]
        max_tracks: Option<usize>,
        #[serde(default)]
        trim_targets: Vec<youtube::HistoryTrimTarget>,
        session: WebSession,
    },
    TrimHistoryPlaylist {
        playlist_id: String,
        max_tracks: usize,
        session: WebSession,
    },
    DownloadTrack {
        track: TrackSummary,
        storage_dir: String,
        #[serde(default)]
        format: Option<youtube::AudioFormat>,
        #[serde(default)]
        sabr_session: Option<sabr::WebSabrSessionInput>,
    },
    CancelTrackDownload {
        video_id: String,
    },
    TrackDownloadProgress,
    ListDownloaded {
        storage_dir: String,
    },
    DeleteDownloaded {
        video_id: String,
        storage_dir: String,
    },
    StorageUsage {
        storage_dir: String,
    },
    CheckUpdate {
        current_version: String,
    },
    DownloadUpdate {
        asset_url: String,
        sha256: Option<String>,
        cache_dir: String,
    },
    UpdateDownloadProgress,
    CancelUpdateDownload,
    EnqueueErrorReport {
        data_dir: String,
        title: String,
        body: String,
        fingerprint: String,
    },
    ListErrorReports {
        data_dir: String,
    },
    ClearErrorReports {
        data_dir: String,
    },
}

struct DispatchError {
    message: String,
    code: Option<&'static str>,
}

impl From<String> for DispatchError {
    fn from(message: String) -> Self {
        Self {
            message,
            code: None,
        }
    }
}

impl From<download::DownloadError> for DispatchError {
    fn from(err: download::DownloadError) -> Self {
        Self {
            message: err.message,
            code: err.code,
        }
    }
}

fn dispatch(raw: &str) -> Result<Value, DispatchError> {
    let request: CoreRequest =
        serde_json::from_str(raw).map_err(|e| format!("요청 JSON 해석 실패: {e}"))?;
    match request {
        CoreRequest::Search { query, session } => {
            let tracks = youtube::search_tracks(&query, session.as_ref())?;
            Ok(json!({"tracks": tracks}))
        }
        CoreRequest::ListPlaylists { session } => {
            let playlists = youtube::list_replica_playlists(&session)?;
            Ok(json!({"playlists": playlists}))
        }
        CoreRequest::AccountProfile { session } => {
            let profile = youtube::fetch_account_profile(&session)?;
            Ok(json!({"profile": profile}))
        }
        CoreRequest::PlaylistTracks {
            playlist_id,
            session,
        } => {
            let tracks = youtube::get_playlist_tracks(&playlist_id, session.as_ref())?;
            Ok(json!({"tracks": tracks}))
        }
        CoreRequest::CreatePlaylist {
            title,
            remote_title,
            session,
        } => {
            let created =
                youtube::create_replica_playlist(&title, remote_title.as_deref(), &session)?;
            Ok(json!({"playlist": created}))
        }
        CoreRequest::RenamePlaylist {
            playlist_id,
            new_remote_title,
            session,
        } => {
            youtube::rename_playlist(&playlist_id, &new_remote_title, &session)?;
            Ok(json!({"renamed": true}))
        }
        CoreRequest::AddToPlaylist {
            playlist_id,
            video_id,
            new_remote_title,
            session,
        } => {
            let set_video_id = youtube::add_track_to_playlist(
                &playlist_id,
                &video_id,
                new_remote_title.as_deref(),
                &session,
            )?;
            Ok(json!({"added": true, "set_video_id": set_video_id}))
        }
        CoreRequest::RemoveFromPlaylist {
            playlist_id,
            video_id,
            set_video_id,
            new_remote_title,
            session,
        } => {
            youtube::remove_track_from_playlist(
                &playlist_id,
                &video_id,
                set_video_id.as_deref(),
                new_remote_title.as_deref(),
                &session,
            )?;
            Ok(json!({"removed": true}))
        }
        CoreRequest::DeletePlaylist {
            playlist_id,
            session,
        } => {
            youtube::delete_playlist(&playlist_id, &session)?;
            Ok(json!({"deleted": true}))
        }
        CoreRequest::SyncPlaylistTracks {
            playlist_id,
            video_ids,
            new_remote_title,
            session,
        } => {
            let tracks = youtube::sync_playlist_tracks(
                &playlist_id,
                &video_ids,
                new_remote_title.as_deref(),
                &session,
            )?;
            Ok(json!({"tracks": tracks}))
        }
        CoreRequest::RecordHistoryTrack {
            playlist_id,
            video_id,
            track,
            existing_set_video_id,
            playlist_loaded,
            max_tracks,
            trim_targets,
            session,
        } => {
            let res = youtube::record_history_track(
                &playlist_id,
                &video_id,
                track,
                existing_set_video_id.as_deref(),
                playlist_loaded,
                max_tracks,
                &trim_targets,
                &session,
            )?;
            Ok(json!({
                "tracks": res.tracks,
                "set_video_id": res.set_video_id
            }))
        }
        CoreRequest::TrimHistoryPlaylist {
            playlist_id,
            max_tracks,
            session,
        } => {
            let tracks = youtube::trim_history_playlist(&playlist_id, max_tracks, &session)?;
            Ok(json!({"tracks": tracks}))
        }
        CoreRequest::DownloadTrack {
            track,
            storage_dir,
            format,
            sabr_session,
        } => {
            let options = download::DownloadOptions {
                format: format.unwrap_or_default(),
                sabr_session,
            };
            let downloaded =
                download::download_track_with_options(&track, Path::new(&storage_dir), &options)?;
            Ok(json!({"downloaded": downloaded}))
        }
        CoreRequest::CancelTrackDownload { video_id } => {
            download::cancel_track_download(&video_id);
            Ok(json!({"cancelled": true}))
        }
        CoreRequest::TrackDownloadProgress => {
            let progress = download::read_all_track_progress();
            Ok(json!({"progress": progress}))
        }
        CoreRequest::ListDownloaded { storage_dir } => {
            let tracks = download::list_downloaded(Path::new(&storage_dir))?;
            Ok(json!({"tracks": tracks}))
        }
        CoreRequest::DeleteDownloaded {
            video_id,
            storage_dir,
        } => {
            let removed = download::delete_downloaded(&video_id, Path::new(&storage_dir))?;
            Ok(json!({"removed": removed}))
        }
        CoreRequest::StorageUsage { storage_dir } => {
            let usage = download::storage_usage(Path::new(&storage_dir))?;
            Ok(json!({"usage": usage}))
        }
        CoreRequest::CheckUpdate { current_version } => {
            let result = update::check_latest_release(&current_version)?;
            Ok(json!({"update": result}))
        }
        CoreRequest::DownloadUpdate {
            asset_url,
            sha256,
            cache_dir,
        } => {
            let downloaded =
                update::download_update_apk(&asset_url, sha256.as_deref(), Path::new(&cache_dir))?;
            Ok(json!({"downloaded": downloaded}))
        }
        CoreRequest::UpdateDownloadProgress => {
            let progress = update::update_download_progress();
            Ok(json!({"progress": progress}))
        }
        CoreRequest::CancelUpdateDownload => {
            update::cancel_update_download();
            Ok(json!({"cancelled": true}))
        }
        CoreRequest::EnqueueErrorReport {
            data_dir,
            title,
            body,
            fingerprint,
        } => {
            let pending = error_report::enqueue_error_report(
                Path::new(&data_dir),
                &title,
                &body,
                &fingerprint,
            )?;
            Ok(json!({"pending": pending}))
        }
        CoreRequest::ListErrorReports { data_dir } => {
            let reports = error_report::load_queue(Path::new(&data_dir));
            Ok(json!({"reports": reports}))
        }
        CoreRequest::ClearErrorReports { data_dir } => {
            error_report::clear_error_reports(Path::new(&data_dir))?;
            Ok(json!({"cleared": true}))
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn replica_music_invoke(request_json: *const c_char) -> *mut c_char {
    let response = match read_c_str(request_json) {
        Some(raw) => match dispatch(&raw) {
            Ok(data) => json!({"ok": true, "data": data}),
            Err(err) => {
                if let Some(code) = err.code {
                    json!({"ok": false, "error": err.message, "code": code})
                } else {
                    json!({"ok": false, "error": err.message})
                }
            }
        },
        None => json!({"ok": false, "error": "유효하지 않은 요청입니다."}),
    };
    into_c_string(response.to_string())
}

#[unsafe(no_mangle)]
pub extern "C" fn replica_music_core_version() -> *mut c_char {
    into_c_string(CORE_VERSION)
}

#[unsafe(no_mangle)]
pub extern "C" fn replica_music_is_playlist(raw_title: *const c_char) -> bool {
    read_c_str(raw_title)
        .map(|s| playlist::is_replica_playlist(&s))
        .unwrap_or(false)
}

#[unsafe(no_mangle)]
pub extern "C" fn replica_music_to_remote_playlist_title(
    display_title: *const c_char,
) -> *mut c_char {
    read_c_str(display_title)
        .and_then(|s| playlist::to_remote_title(&s))
        .map(into_c_string)
        .unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub extern "C" fn replica_music_to_display_playlist_title(raw_title: *const c_char) -> *mut c_char {
    read_c_str(raw_title)
        .map(|s| into_c_string(playlist::to_display_title(&s)))
        .unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub extern "C" fn replica_music_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe {
            let _ = CString::from_raw(ptr);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_round_trip_handles_playlist_titles() {
        let input = CString::new("Driving").unwrap();
        let remote_ptr = replica_music_to_remote_playlist_title(input.as_ptr());
        assert!(!remote_ptr.is_null());
        assert!(replica_music_is_playlist(remote_ptr));

        let display_ptr = replica_music_to_display_playlist_title(remote_ptr);
        assert!(!display_ptr.is_null());
        let display = unsafe { CStr::from_ptr(display_ptr) }.to_str().unwrap();
        assert_eq!(display, "Driving");

        replica_music_free(remote_ptr);
        replica_music_free(display_ptr);
    }

    #[test]
    fn ffi_returns_core_version() {
        let ptr = replica_music_core_version();
        assert!(!ptr.is_null());
        let version = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap();
        assert_eq!(version, "0.3.0");
        replica_music_free(ptr);
    }

    #[test]
    fn invoke_handles_storage_usage_for_missing_dir() {
        let req = CString::new(
            json!({"op": "storage_usage", "storage_dir": "nonexistent_replica_music_test_dir"})
                .to_string(),
        )
        .unwrap();
        let res_ptr = replica_music_invoke(req.as_ptr());
        assert!(!res_ptr.is_null());
        let res_str = unsafe { CStr::from_ptr(res_ptr) }.to_str().unwrap();
        let parsed: Value = serde_json::from_str(res_str).unwrap();
        assert_eq!(parsed["ok"], true);
        assert_eq!(parsed["data"]["usage"]["item_count"], 0);
        replica_music_free(res_ptr);
    }
}
