use crate::{
    auth::{self, WebSession},
    playlist,
    sabr::{self, SabrAdaptiveFormat, SabrAudioSpec, SabrClientInfo},
};
use reqwest::blocking::Client;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::HashSet,
    sync::{
        LazyLock, Mutex, RwLock,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};

const INNERTUBE_BASE: &str = "https://www.youtube.com/youtubei/v1";
const WEB_CLIENT_VERSION: &str = "2.20261020.01.00";

static HTTP_CLIENT: LazyLock<Result<Client, String>> = LazyLock::new(|| {
    Client::builder()
        .tcp_nodelay(true)
        .pool_idle_timeout(Duration::from_secs(90))
        .tcp_keepalive(Duration::from_secs(30))
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(30))
        .build()
        .map_err(|_| "HTTP 클라이언트 초기화에 실패했습니다.".into())
});

static DOWNLOAD_HTTP_CLIENT: LazyLock<Result<Client, String>> = LazyLock::new(|| {
    Client::builder()
        .tcp_nodelay(true)
        .pool_idle_timeout(Duration::from_secs(90))
        .tcp_keepalive(Duration::from_secs(30))
        .connect_timeout(Duration::from_secs(12))
        .timeout(Duration::from_secs(45))
        .build()
        .map_err(|_| "다운로드 HTTP 클라이언트 초기화에 실패했습니다.".into())
});

static SABR_HTTP_CLIENT: LazyLock<Result<Client, String>> = LazyLock::new(|| {
    Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .tcp_nodelay(true)
        .pool_idle_timeout(Duration::from_secs(90))
        .tcp_keepalive(Duration::from_secs(30))
        .connect_timeout(Duration::from_secs(12))
        .timeout(Duration::from_secs(45))
        .build()
        .map_err(|_| "SABR HTTP 클라이언트 초기화에 실패했습니다.".into())
});

pub fn http_client() -> Result<&'static Client, String> {
    HTTP_CLIENT.as_ref().map_err(Clone::clone)
}

pub fn download_http_client() -> Result<&'static Client, String> {
    DOWNLOAD_HTTP_CLIENT.as_ref().map_err(Clone::clone)
}

pub fn sabr_http_client() -> Result<&'static Client, String> {
    SABR_HTTP_CLIENT.as_ref().map_err(Clone::clone)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TrackSummary {
    pub video_id: String,
    pub title: String,
    pub artist: String,
    pub duration: String,
    pub thumbnail: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub set_video_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlaylistSummary {
    pub id: String,
    pub remote_title: String,
    pub display_title: String,
    pub subtitle: String,
    pub thumbnail: String,
    #[serde(default)]
    pub updated_at: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccountProfile {
    pub name: String,
    pub handle: String,
    pub avatar_url: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AudioFormat {
    #[default]
    Opus,
    M4a,
}

impl AudioFormat {
    pub fn output_extension(self) -> &'static str {
        match self {
            Self::Opus => "opus",
            Self::M4a => "m4a",
        }
    }

    pub fn fallback(self) -> Self {
        match self {
            Self::Opus => Self::M4a,
            Self::M4a => Self::Opus,
        }
    }

    pub fn matches_sabr(self, format: &SabrAdaptiveFormat) -> bool {
        match self {
            Self::Opus => format.is_opus(),
            Self::M4a => format.is_aac(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AudioStreamInfo {
    pub video_id: String,
    pub url: String,
    pub mime_type: String,
    pub extension: String,
    #[serde(default)]
    pub codec: AudioFormat,
    pub bitrate: u64,
    pub content_length: Option<u64>,
    pub user_agent: String,
}

pub fn valid_video_id(id: &str) -> bool {
    id.len() == 11
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

fn post_web_with_timeout(
    endpoint: &str,
    mut body: Value,
    session: Option<&WebSession>,
    timeout_override: Option<Duration>,
) -> Result<Value, String> {
    let client = http_client()?;
    let mut client_ctx = json!({
        "clientName": "WEB",
        "clientVersion": session.map(|s| s.client_version.as_str()).unwrap_or(WEB_CLIENT_VERSION),
        "hl": "ko",
        "gl": "KR"
    });
    if let Some(web) = session {
        client_ctx["visitorData"] = json!(web.visitor_data);
    }
    body["context"] = json!({"client": client_ctx});
    if let Some(web) = session {
        body["context"]["user"]["lockedSafetyMode"] = json!(false);
        if let Some(id) = web.delegated_id() {
            body["context"]["user"]["onBehalfOfUser"] = json!(id);
        }
    }

    let url = format!("{INNERTUBE_BASE}/{endpoint}?prettyPrint=false");
    let mut request = client
        .post(&url)
        .header("Content-Type", "application/json")
        .header("X-YouTube-Client-Name", "1")
        .header(
            "X-YouTube-Client-Version",
            session
                .map(|s| s.client_version.as_str())
                .unwrap_or(WEB_CLIENT_VERSION),
        )
        .header("X-Goog-Api-Format-Version", "1")
        .json(&body);
    if let Some(timeout) = timeout_override {
        request = request.timeout(timeout);
    }

    if let Some(web) = session {
        request = auth::authorize(request, web)?;
    } else {
        request = request.header("User-Agent", auth::USER_AGENT);
    }

    let response = request
        .send()
        .map_err(|_| "YouTube 서버에 연결하지 못했습니다.")?;
    let status = response.status();
    let payload: Value = response
        .json()
        .map_err(|_| "YouTube 응답을 해석하지 못했습니다.")?;
    if !status.is_success() {
        let detail = payload
            .pointer("/error/message")
            .and_then(Value::as_str)
            .unwrap_or("");
        return if detail.is_empty() {
            Err(format!("YouTube 요청 오류 ({status})"))
        } else {
            Err(format!("YouTube 요청 오류 ({status}): {detail}"))
        };
    }
    if session.is_some()
        && payload
            .pointer("/responseContext/mainAppWebResponseContext/loggedOut")
            .and_then(Value::as_bool)
            == Some(true)
    {
        return Err("Google 로그인 세션이 만료되었습니다. 다시 로그인하세요.".into());
    }
    Ok(payload)
}

fn post_web(endpoint: &str, body: Value, session: Option<&WebSession>) -> Result<Value, String> {
    post_web_with_timeout(endpoint, body, session, None)
}

pub fn display_text(value: &Value) -> String {
    if let Some(simple) = value.get("simpleText").and_then(Value::as_str) {
        return simple.trim().to_owned();
    }
    if let Some(runs) = value.get("runs").and_then(Value::as_array) {
        let joined: String = runs
            .iter()
            .filter_map(|r| r.get("text").and_then(Value::as_str))
            .collect();
        return joined.trim().to_owned();
    }
    if let Some(content) = value.get("content").and_then(Value::as_str) {
        return content.trim().to_owned();
    }
    String::new()
}

fn best_thumbnail(value: &Value) -> String {
    let url = value
        .pointer("/thumbnails")
        .and_then(Value::as_array)
        .and_then(|arr| arr.last())
        .and_then(|item| item.get("url"))
        .and_then(Value::as_str)
        .unwrap_or("");
    if url.starts_with("//") {
        format!("https:{url}")
    } else {
        url.to_owned()
    }
}

pub fn search_tracks(
    query: &str,
    session: Option<&WebSession>,
) -> Result<Vec<TrackSummary>, String> {
    let trimmed = query.trim();
    if trimmed.is_empty() {
        return Ok(Vec::new());
    }
    let response = post_web("search", json!({"query": trimmed}), session)?;
    let mut tracks = Vec::new();
    let mut seen = HashSet::new();
    collect_video_renderers(&response, &mut tracks, &mut seen);
    Ok(tracks)
}

fn collect_video_renderers(value: &Value, out: &mut Vec<TrackSummary>, seen: &mut HashSet<String>) {
    match value {
        Value::Object(map) => {
            if let Some(renderer) = map.get("videoRenderer") {
                if let Some(video_id) = renderer.get("videoId").and_then(Value::as_str)
                    && valid_video_id(video_id)
                    && seen.insert(video_id.to_owned())
                {
                    let title = display_text(&renderer["title"]);
                    let artist = display_text(&renderer["ownerText"]);
                    let duration = display_text(&renderer["lengthText"]);
                    let thumbnail = best_thumbnail(&renderer["thumbnail"]);
                    if !title.is_empty() {
                        out.push(TrackSummary {
                            video_id: video_id.to_owned(),
                            title,
                            artist: if artist.is_empty() {
                                "YouTube".into()
                            } else {
                                artist
                            },
                            duration: if duration.is_empty() {
                                "LIVE".into()
                            } else {
                                duration
                            },
                            thumbnail,
                            set_video_id: None,
                        });
                    }
                }
            }
            for child in map.values() {
                collect_video_renderers(child, out, seen);
            }
        }
        Value::Array(items) => {
            for item in items {
                collect_video_renderers(item, out, seen);
            }
        }
        _ => {}
    }
}

fn collect_replica_playlists_paged<F>(
    initial: Value,
    mut fetch_next: F,
) -> Result<Vec<PlaylistSummary>, String>
where
    F: FnMut(&str) -> Result<Value, String>,
{
    let mut response = initial;
    let mut playlists = Vec::new();
    let mut seen = HashSet::new();
    let mut seen_tokens = HashSet::new();
    collect_playlists(&response, &mut playlists, &mut seen);

    for _ in 1..MAX_PLAYLIST_PAGES {
        let Some(token) = extract_continuation_token(&response) else {
            break;
        };
        if !seen_tokens.insert(token.clone()) {
            break;
        }
        let next_resp = fetch_next(&token)?;
        collect_playlists(&next_resp, &mut playlists, &mut seen);
        response = next_resp;
    }
    Ok(playlists)
}

pub fn list_replica_playlists(session: &WebSession) -> Result<Vec<PlaylistSummary>, String> {
    session.validate()?;
    let initial = post_web(
        "browse",
        json!({"browseId": "FEplaylist_aggregation"}),
        Some(session),
    )?;
    collect_replica_playlists_paged(initial, |token| {
        post_web("browse", json!({"continuation": token}), Some(session))
    })
}

pub fn fetch_account_profile(session: &WebSession) -> Result<AccountProfile, String> {
    session.validate()?;
    let response = post_web("account/account_menu", json!({}), Some(session))?;
    fn find_header(v: &Value) -> Option<&Value> {
        match v {
            Value::Object(map) => map
                .get("activeAccountHeaderRenderer")
                .or_else(|| map.values().find_map(find_header)),
            Value::Array(items) => items.iter().find_map(find_header),
            _ => None,
        }
    }
    let header = find_header(&response).ok_or("활성 Google 계정 프로필 정보를 찾지 못했습니다.")?;
    let name = display_text(&header["accountName"]);
    let handle = display_text(&header["channelHandle"]);
    let avatar_url = best_thumbnail(&header["accountPhoto"]);
    Ok(AccountProfile {
        name: if name.is_empty() {
            "Google 계정".into()
        } else {
            name
        },
        handle,
        avatar_url,
    })
}

fn collect_playlists(value: &Value, out: &mut Vec<PlaylistSummary>, seen: &mut HashSet<String>) {
    match value {
        Value::Object(map) => {
            if let Some(lockup) = map.get("lockupViewModel") {
                if lockup.get("contentType").and_then(Value::as_str)
                    == Some("LOCKUP_CONTENT_TYPE_PLAYLIST")
                {
                    let id = lockup
                        .get("contentId")
                        .and_then(Value::as_str)
                        .unwrap_or("");
                    let title = display_text(
                        lockup
                            .pointer("/metadata/lockupMetadataViewModel/title")
                            .unwrap_or(&Value::Null),
                    );
                    if !id.is_empty()
                        && playlist::is_replica_playlist(&title)
                        && seen.insert(id.to_owned())
                    {
                        let thumb = lockup
                            .pointer("/contentImage/collectionThumbnailViewModel/primaryThumbnail/thumbnailViewModel/image/sources")
                            .and_then(Value::as_array)
                            .and_then(|s| s.last())
                            .and_then(|s| s.get("url"))
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_owned();
                        out.push(PlaylistSummary {
                            id: id.to_owned(),
                            display_title: playlist::to_display_title(&title),
                            updated_at: playlist::parse_playlist_timestamp(&title),
                            remote_title: title,
                            subtitle: "YouTube 재생목록".into(),
                            thumbnail: thumb,
                        });
                    }
                }
            }
            if let Some(renderer) = map
                .get("gridPlaylistRenderer")
                .or_else(|| map.get("playlistRenderer"))
            {
                let id = renderer
                    .get("playlistId")
                    .and_then(Value::as_str)
                    .unwrap_or("");
                let title = display_text(&renderer["title"]);
                if !id.is_empty()
                    && playlist::is_replica_playlist(&title)
                    && seen.insert(id.to_owned())
                {
                    let count = display_text(&renderer["videoCountShortText"]);
                    let thumb = best_thumbnail(&renderer["thumbnail"]);
                    out.push(PlaylistSummary {
                        id: id.to_owned(),
                        display_title: playlist::to_display_title(&title),
                        updated_at: playlist::parse_playlist_timestamp(&title),
                        remote_title: title,
                        subtitle: if count.is_empty() {
                            "YouTube 재생목록".into()
                        } else {
                            format!("{count}곡")
                        },
                        thumbnail: thumb,
                    });
                }
            }
            for child in map.values() {
                collect_playlists(child, out, seen);
            }
        }
        Value::Array(items) => {
            for item in items {
                collect_playlists(item, out, seen);
            }
        }
        _ => {}
    }
}

const MAX_PLAYLIST_PAGES: usize = 20;

fn extract_continuation_token_from_items(items: &[Value]) -> Option<String> {
    for item in items {
        if let Some(token) = item
            .pointer("/continuationItemRenderer/continuationEndpoint/continuationCommand/token")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
        {
            return Some(token.to_owned());
        }
    }
    None
}

fn extract_continuation_token(value: &Value) -> Option<String> {
    match value {
        Value::Object(map) => {
            if let Some(items) = map
                .get("gridRenderer")
                .and_then(|v| v.get("items"))
                .and_then(Value::as_array)
                && let Some(token) = extract_continuation_token_from_items(items)
            {
                return Some(token);
            }
            if let Some(items) = map
                .get("richGridRenderer")
                .and_then(|v| v.get("contents"))
                .and_then(Value::as_array)
                && let Some(token) = extract_continuation_token_from_items(items)
            {
                return Some(token);
            }
            if let Some(items) = map
                .get("appendContinuationItemsAction")
                .and_then(|v| v.get("continuationItems"))
                .and_then(Value::as_array)
                && let Some(token) = extract_continuation_token_from_items(items)
            {
                return Some(token);
            }
            for child in map.values() {
                if let Some(found) = extract_continuation_token(child) {
                    return Some(found);
                }
            }
            None
        }
        Value::Array(items) => {
            for item in items {
                if let Some(found) = extract_continuation_token(item) {
                    return Some(found);
                }
            }
            None
        }
        _ => None,
    }
}

fn find_playlist_video_list_contents(value: &Value) -> Option<&Vec<Value>> {
    match value {
        Value::Object(map) => {
            if let Some(contents) = map
                .get("playlistVideoListRenderer")
                .and_then(|r| r.get("contents"))
                .and_then(Value::as_array)
            {
                return Some(contents);
            }
            for child in map.values() {
                if let Some(found) = find_playlist_video_list_contents(child) {
                    return Some(found);
                }
            }
            None
        }
        Value::Array(items) => {
            for item in items {
                if let Some(found) = find_playlist_video_list_contents(item) {
                    return Some(found);
                }
            }
            None
        }
        _ => None,
    }
}

fn find_playlist_continuation_items(response: &Value) -> Option<&Vec<Value>> {
    let actions = response
        .get("onResponseReceivedActions")
        .and_then(Value::as_array)?;
    for action in actions {
        let Some(append) = action.get("appendContinuationItemsAction") else {
            continue;
        };
        let target_ok = append
            .get("targetId")
            .and_then(Value::as_str)
            .is_none_or(|t| t == "playlist-video-list" || t.is_empty());
        if !target_ok {
            continue;
        }
        if let Some(items) = append.get("continuationItems").and_then(Value::as_array) {
            return Some(items);
        }
    }
    None
}

fn collect_playlist_tracks_from_items(
    items: &[Value],
    out: &mut Vec<TrackSummary>,
    seen: &mut HashSet<String>,
) -> Option<String> {
    let mut next_token = None;
    for item in items {
        if let Some(renderer) = item.get("playlistVideoRenderer") {
            if let Some(video_id) = renderer.get("videoId").and_then(Value::as_str)
                && valid_video_id(video_id)
                && seen.insert(video_id.to_owned())
            {
                let title = display_text(&renderer["title"]);
                let artist = display_text(&renderer["shortBylineText"]);
                let duration = display_text(&renderer["lengthText"]);
                let thumbnail = best_thumbnail(&renderer["thumbnail"]);
                let set_video_id = renderer
                    .get("setVideoId")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned);
                if !title.is_empty() {
                    out.push(TrackSummary {
                        video_id: video_id.to_owned(),
                        title,
                        artist: if artist.is_empty() {
                            "YouTube".into()
                        } else {
                            artist
                        },
                        duration,
                        thumbnail,
                        set_video_id,
                    });
                }
            }
        } else if next_token.is_none()
            && let Some(token) = item
                .pointer("/continuationItemRenderer/continuationEndpoint/continuationCommand/token")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
        {
            next_token = Some(token.to_owned());
        }
    }
    next_token
}

fn parse_initial_playlist_page(
    response: &Value,
    out: &mut Vec<TrackSummary>,
    seen: &mut HashSet<String>,
) -> Option<String> {
    let items = find_playlist_video_list_contents(response)?;
    collect_playlist_tracks_from_items(items, out, seen)
}

pub fn get_playlist_tracks(
    playlist_id: &str,
    session: Option<&WebSession>,
) -> Result<Vec<TrackSummary>, String> {
    let trimmed = playlist_id.trim();
    if trimmed.is_empty() {
        return Err("재생목록 ID가 없습니다.".into());
    }
    let browse_id = if trimmed.starts_with("VL") {
        trimmed.to_owned()
    } else {
        format!("VL{trimmed}")
    };
    let response = post_web("browse", json!({"browseId": browse_id}), session)?;
    let mut tracks = Vec::new();
    let mut seen = HashSet::new();
    let mut seen_tokens = HashSet::new();
    let mut next_token = parse_initial_playlist_page(&response, &mut tracks, &mut seen);

    for _ in 1..MAX_PLAYLIST_PAGES {
        let Some(token) = next_token.take() else {
            break;
        };
        if !seen_tokens.insert(token.clone()) {
            break;
        }
        let next_resp = post_web("browse", json!({"continuation": token}), session)?;
        if let Some(items) = find_playlist_continuation_items(&next_resp) {
            next_token = collect_playlist_tracks_from_items(items, &mut tracks, &mut seen);
        }
    }

    Ok(tracks)
}

fn now_unix_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

pub fn create_replica_playlist(
    display_title: &str,
    remote_title_override: Option<&str>,
    session: &WebSession,
) -> Result<PlaylistSummary, String> {
    session.validate()?;
    let remote_title = if let Some(raw) = remote_title_override
        .map(str::trim)
        .filter(|s| playlist::is_replica_playlist(s))
    {
        raw.to_owned()
    } else if playlist::is_history_playlist(display_title) {
        display_title.trim().to_owned()
    } else {
        playlist::to_versioned_remote_title(display_title, now_unix_secs())
            .ok_or("재생목록 이름을 입력하세요.")?
    };
    let response = post_web(
        "playlist/create",
        json!({
            "title": remote_title,
            "privacyStatus": "PRIVATE"
        }),
        Some(session),
    )?;
    let id = response
        .get("playlistId")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .ok_or("재생목록 생성 응답에 ID가 없습니다.")?;
    Ok(PlaylistSummary {
        id: id.to_owned(),
        display_title: playlist::to_display_title(&remote_title),
        updated_at: playlist::parse_playlist_timestamp(&remote_title),
        remote_title,
        subtitle: "0곡".into(),
        thumbnail: String::new(),
    })
}

pub fn rename_playlist(
    playlist_id: &str,
    new_remote_title: &str,
    session: &WebSession,
) -> Result<(), String> {
    session.validate()?;
    let pid = playlist_id.trim();
    let title = new_remote_title.trim();
    if pid.is_empty() || !playlist::is_replica_playlist(title) {
        return Err("재생목록 ID 또는 이름이 올바르지 않습니다.".into());
    }
    let response = post_web(
        "browse/edit_playlist",
        json!({
            "playlistId": pid,
            "actions": [{
                "action": "ACTION_SET_PLAYLIST_NAME",
                "playlistName": title
            }]
        }),
        Some(session),
    )?;
    if response.get("error").is_some()
        || response["status"]
            .as_str()
            .is_some_and(|s| s != "STATUS_SUCCEEDED")
    {
        return Err("YouTube 재생목록 이름을 변경하지 못했습니다.".into());
    }
    Ok(())
}

pub fn add_track_to_playlist(
    playlist_id: &str,
    video_id: &str,
    new_remote_title: Option<&str>,
    session: &WebSession,
) -> Result<Option<String>, String> {
    session.validate()?;
    if playlist_id.trim().is_empty() || !valid_video_id(video_id) {
        return Err("재생목록 또는 영상 ID가 올바르지 않습니다.".into());
    }
    let mut actions = vec![json!({
        "action": "ACTION_ADD_VIDEO",
        "addedVideoId": video_id
    })];
    if let Some(title) = new_remote_title
        .map(str::trim)
        .filter(|s| playlist::is_replica_playlist(s))
    {
        actions.push(json!({
            "action": "ACTION_SET_PLAYLIST_NAME",
            "playlistName": title
        }));
    }
    let response = post_web(
        "browse/edit_playlist",
        json!({
            "playlistId": playlist_id.trim(),
            "actions": actions
        }),
        Some(session),
    )?;
    if response.get("error").is_some()
        || response["status"]
            .as_str()
            .is_some_and(|s| s != "STATUS_SUCCEEDED")
    {
        return Err("재생목록에 곡을 추가하지 못했습니다.".into());
    }
    let set_video_id = response
        .pointer("/playlistEditResults/0/playlistEditVideoAddedResultData/setVideoId")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(ToOwned::to_owned);
    Ok(set_video_id)
}

pub fn remove_track_from_playlist(
    playlist_id: &str,
    video_id: &str,
    set_video_id: Option<&str>,
    new_remote_title: Option<&str>,
    session: &WebSession,
) -> Result<(), String> {
    session.validate()?;
    let pid = playlist_id.trim();
    if pid.is_empty() || !valid_video_id(video_id) {
        return Err("재생목록 또는 영상 ID가 올바르지 않습니다.".into());
    }
    let resolved_set_id = match set_video_id.map(str::trim).filter(|s| !s.is_empty()) {
        Some(id) => Some(id.to_owned()),
        None => get_playlist_tracks(pid, Some(session))
            .ok()
            .and_then(|tracks| {
                tracks
                    .into_iter()
                    .find(|t| t.video_id == video_id)
                    .and_then(|t| t.set_video_id)
            }),
    };
    let action = if let Some(svid) = resolved_set_id {
        json!({
            "action": "ACTION_REMOVE_VIDEO",
            "setVideoId": svid,
            "removedVideoId": video_id
        })
    } else {
        json!({
            "action": "ACTION_REMOVE_VIDEO_BY_VIDEO_ID",
            "removedVideoId": video_id
        })
    };
    let mut actions = vec![action];
    if let Some(title) = new_remote_title
        .map(str::trim)
        .filter(|s| playlist::is_replica_playlist(s))
    {
        actions.push(json!({
            "action": "ACTION_SET_PLAYLIST_NAME",
            "playlistName": title
        }));
    }
    let response = post_web(
        "browse/edit_playlist",
        json!({
            "playlistId": pid,
            "actions": actions
        }),
        Some(session),
    )?;
    if response.get("error").is_some()
        || response["status"]
            .as_str()
            .is_some_and(|s| s != "STATUS_SUCCEEDED")
    {
        return Err("YouTube 재생목록에서 곡을 삭제하지 못했습니다.".into());
    }
    Ok(())
}

pub fn delete_playlist(playlist_id: &str, session: &WebSession) -> Result<(), String> {
    session.validate()?;
    let pid = playlist_id.trim();
    if pid.is_empty() {
        return Err("재생목록 ID가 올바르지 않습니다.".into());
    }
    let response = post_web(
        "playlist/delete",
        json!({
            "playlistId": pid
        }),
        Some(session),
    )?;
    if response.get("error").is_some() {
        return Err("YouTube 재생목록을 삭제하지 못했습니다.".into());
    }
    Ok(())
}

fn minimal_move_indices(current: &[&str], desired: &[&str]) -> Vec<usize> {
    let pos_in_desired: std::collections::HashMap<&str, usize> = desired
        .iter()
        .enumerate()
        .map(|(idx, &vid)| (vid, idx))
        .collect();
    let seq: Vec<usize> = current
        .iter()
        .filter_map(|vid| pos_in_desired.get(vid).copied())
        .collect();
    let m = seq.len();
    if m <= 1 {
        return Vec::new();
    }
    let mut tails: Vec<usize> = Vec::with_capacity(m);
    let mut tail_indices: Vec<usize> = Vec::with_capacity(m);
    let mut prev: Vec<Option<usize>> = vec![None; m];

    for (i, &val) in seq.iter().enumerate() {
        let pos = tails.partition_point(|&x| x < val);
        if pos > 0 {
            prev[i] = Some(tail_indices[pos - 1]);
        }
        if pos == tails.len() {
            tails.push(val);
            tail_indices.push(i);
        } else {
            tails[pos] = val;
            tail_indices[pos] = i;
        }
    }

    let mut fixed = HashSet::with_capacity(tails.len());
    let mut cur = tail_indices.last().copied();
    while let Some(idx) = cur {
        fixed.insert(seq[idx]);
        cur = prev[idx];
    }

    (0..desired.len())
        .filter(|idx| !fixed.contains(idx))
        .collect()
}

const EDIT_PLAYLIST_BATCH_SIZE: usize = 50;

fn edit_playlist_batched(
    pid: &str,
    actions: &[Value],
    session: &WebSession,
    err_msg: &str,
) -> Result<(), String> {
    for chunk in actions.chunks(EDIT_PLAYLIST_BATCH_SIZE) {
        let resp = post_web(
            "browse/edit_playlist",
            json!({
                "playlistId": pid,
                "actions": chunk
            }),
            Some(session),
        )?;
        if resp.get("error").is_some()
            || resp["status"]
                .as_str()
                .is_some_and(|s| s != "STATUS_SUCCEEDED")
        {
            return Err(err_msg.into());
        }
    }
    Ok(())
}

pub fn sync_playlist_tracks(
    playlist_id: &str,
    desired_video_ids: &[String],
    new_remote_title: Option<&str>,
    session: &WebSession,
) -> Result<Vec<TrackSummary>, String> {
    session.validate()?;
    let pid = playlist_id.trim();
    if pid.is_empty() {
        return Err("재생목록 ID가 올바르지 않습니다.".into());
    }
    let mut deduped_desired: Vec<&str> = Vec::with_capacity(desired_video_ids.len());
    let mut desired_seen: HashSet<&str> = HashSet::with_capacity(desired_video_ids.len());
    for vid in desired_video_ids {
        if valid_video_id(vid) && desired_seen.insert(vid.as_str()) {
            deduped_desired.push(vid.as_str());
        }
    }
    let remote_tracks = get_playlist_tracks(pid, Some(session))?;

    let mut actions: Vec<Value> = Vec::new();
    let mut surviving: Vec<TrackSummary> = Vec::new();

    for rt in &remote_tracks {
        if !desired_seen.contains(rt.video_id.as_str()) {
            if let Some(svid) = rt.set_video_id.as_deref().filter(|s| !s.is_empty()) {
                actions.push(json!({
                    "action": "ACTION_REMOVE_VIDEO",
                    "setVideoId": svid,
                    "removedVideoId": rt.video_id
                }));
            } else {
                actions.push(json!({
                    "action": "ACTION_REMOVE_VIDEO_BY_VIDEO_ID",
                    "removedVideoId": rt.video_id
                }));
            }
        } else {
            surviving.push(rt.clone());
        }
    }

    let remote_ids: HashSet<&str> = surviving.iter().map(|t| t.video_id.as_str()).collect();
    for &vid in &deduped_desired {
        if !remote_ids.contains(vid) {
            actions.push(json!({
                "action": "ACTION_ADD_VIDEO",
                "addedVideoId": vid
            }));
        }
    }

    let refreshed = if !actions.is_empty() {
        edit_playlist_batched(
            pid,
            &actions,
            session,
            "YouTube 재생목록 변경사항을 적용하지 못했습니다.",
        )?;
        get_playlist_tracks(pid, Some(session))?
    } else {
        remote_tracks
    };
    let current_order: Vec<&str> = refreshed.iter().map(|t| t.video_id.as_str()).collect();
    let current_set: HashSet<&str> = current_order.iter().copied().collect();
    let desired_existing: Vec<&str> = deduped_desired
        .into_iter()
        .filter(|id| current_set.contains(id))
        .collect();

    if current_order != desired_existing && desired_existing.len() > 1 {
        let set_id_by_vid: std::collections::HashMap<&str, &str> = refreshed
            .iter()
            .filter_map(|t| {
                t.set_video_id
                    .as_deref()
                    .filter(|s| !s.is_empty())
                    .map(|svid| (t.video_id.as_str(), svid))
            })
            .collect();

        let move_indices = minimal_move_indices(&current_order, &desired_existing);
        let mut move_actions: Vec<Value> = Vec::with_capacity(move_indices.len());
        for idx in move_indices {
            let vid = desired_existing[idx];
            let Some(&svid) = set_id_by_vid.get(vid) else {
                continue;
            };
            if idx == 0 {
                move_actions.push(json!({
                    "action": "ACTION_MOVE_VIDEO_AFTER",
                    "setVideoId": svid
                }));
            } else if let Some(&prev_svid) = set_id_by_vid.get(desired_existing[idx - 1]) {
                move_actions.push(json!({
                    "action": "ACTION_MOVE_VIDEO_AFTER",
                    "setVideoId": svid,
                    "movedSetVideoIdPredecessor": prev_svid
                }));
            }
        }

        if !move_actions.is_empty() {
            if let Some(title) = new_remote_title
                .map(str::trim)
                .filter(|s| playlist::is_replica_playlist(s))
            {
                move_actions.push(json!({
                    "action": "ACTION_SET_PLAYLIST_NAME",
                    "playlistName": title
                }));
            }
            edit_playlist_batched(
                pid,
                &move_actions,
                session,
                "YouTube 재생목록 순서 변경을 적용하지 못했습니다.",
            )?;
            return get_playlist_tracks(pid, Some(session));
        }
    }

    if let Some(title) = new_remote_title
        .map(str::trim)
        .filter(|s| playlist::is_replica_playlist(s))
    {
        let _ = rename_playlist(pid, title, session);
    }

    Ok(refreshed)
}

pub struct RecordHistoryResult {
    pub tracks: Option<Vec<TrackSummary>>,
    pub set_video_id: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct HistoryTrimTarget {
    pub video_id: String,
    #[serde(default)]
    pub set_video_id: Option<String>,
}

fn build_remove_playlist_action(video_id: &str, set_video_id: Option<&str>) -> Value {
    if let Some(svid) = set_video_id.map(str::trim).filter(|s| !s.is_empty()) {
        json!({
            "action": "ACTION_REMOVE_VIDEO",
            "setVideoId": svid,
            "removedVideoId": video_id
        })
    } else {
        json!({
            "action": "ACTION_REMOVE_VIDEO_BY_VIDEO_ID",
            "removedVideoId": video_id
        })
    }
}

fn build_trim_actions_from_targets(
    targets: &[HistoryTrimTarget],
    keep_video_id: &str,
) -> Vec<Value> {
    targets
        .iter()
        .filter(|t| valid_video_id(&t.video_id) && t.video_id != keep_video_id)
        .map(|t| build_remove_playlist_action(&t.video_id, t.set_video_id.as_deref()))
        .collect()
}

fn try_move_video_to_top_and_trim(
    pid: &str,
    svid: &str,
    trim_actions: &[Value],
    session: &WebSession,
) -> Result<(), String> {
    let mut actions = Vec::with_capacity(1 + trim_actions.len());
    actions.push(json!({
        "action": "ACTION_MOVE_VIDEO_AFTER",
        "setVideoId": svid
    }));
    actions.extend(trim_actions.iter().cloned());
    edit_playlist_batched(
        pid,
        &actions,
        session,
        "기록 재생목록 최상단 이동에 실패했습니다.",
    )
}

pub fn trim_history_playlist(
    playlist_id: &str,
    max_tracks: usize,
    session: &WebSession,
) -> Result<Vec<TrackSummary>, String> {
    session.validate()?;
    let pid = playlist_id.trim();
    if pid.is_empty() {
        return Err("올바른 기록 재생목록 ID가 아닙니다.".into());
    }
    let mut current = get_playlist_tracks(pid, Some(session))?;
    if max_tracks > 0 && current.len() > max_tracks {
        let overflow = current.split_off(max_tracks);
        let remove_actions: Vec<Value> = overflow
            .iter()
            .filter(|t| valid_video_id(&t.video_id))
            .map(|t| build_remove_playlist_action(&t.video_id, t.set_video_id.as_deref()))
            .collect();
        if !remove_actions.is_empty() {
            edit_playlist_batched(
                pid,
                &remove_actions,
                session,
                "오래된 기록을 정리하지 못했습니다.",
            )?;
        }
    }
    Ok(current)
}

pub fn record_history_track(
    playlist_id: &str,
    video_id: &str,
    track_hint: Option<TrackSummary>,
    existing_set_video_id: Option<&str>,
    playlist_loaded: bool,
    max_tracks: Option<usize>,
    trim_targets: &[HistoryTrimTarget],
    session: &WebSession,
) -> Result<RecordHistoryResult, String> {
    session.validate()?;
    let pid = playlist_id.trim();
    if pid.is_empty() || !valid_video_id(video_id) {
        return Err("올바른 기록 재생목록 또는 영상 ID가 아닙니다.".into());
    }

    let limit = max_tracks.filter(|&n| n > 0);
    let fast_trim_actions = if limit.is_some() {
        build_trim_actions_from_targets(trim_targets, video_id)
    } else {
        Vec::new()
    };

    if let Some(svid) = existing_set_video_id
        .map(str::trim)
        .filter(|s| !s.is_empty())
        && try_move_video_to_top_and_trim(pid, svid, &fast_trim_actions, session).is_ok()
    {
        return Ok(RecordHistoryResult {
            tracks: None,
            set_video_id: Some(svid.to_owned()),
        });
    }

    if playlist_loaded && existing_set_video_id.is_none() {
        if let Ok(Some(new_svid)) = add_track_to_playlist(pid, video_id, None, session)
            && try_move_video_to_top_and_trim(pid, &new_svid, &fast_trim_actions, session).is_ok()
        {
            return Ok(RecordHistoryResult {
                tracks: None,
                set_video_id: Some(new_svid),
            });
        }
    }

    let mut current = get_playlist_tracks(pid, Some(session))?;
    if current.first().is_some_and(|t| t.video_id == video_id) {
        let mut cleanup_actions: Vec<Value> = Vec::new();
        let mut seen_ids: HashSet<String> = HashSet::with_capacity(current.len());
        let mut deduped: Vec<TrackSummary> = Vec::with_capacity(current.len());
        for t in current {
            if seen_ids.insert(t.video_id.clone()) {
                deduped.push(t);
            } else if valid_video_id(&t.video_id) {
                cleanup_actions.push(build_remove_playlist_action(
                    &t.video_id,
                    t.set_video_id.as_deref(),
                ));
            }
        }
        current = deduped;
        if let Some(max_len) = limit
            && current.len() > max_len
        {
            for t in current.split_off(max_len) {
                if valid_video_id(&t.video_id) {
                    cleanup_actions.push(build_remove_playlist_action(
                        &t.video_id,
                        t.set_video_id.as_deref(),
                    ));
                }
            }
        }
        if !cleanup_actions.is_empty() {
            let _ = edit_playlist_batched(
                pid,
                &cleanup_actions,
                session,
                "오래된 기록을 정리하지 못했습니다.",
            );
        }
        let svid = current.first().and_then(|t| t.set_video_id.clone());
        return Ok(RecordHistoryResult {
            tracks: Some(current),
            set_video_id: svid,
        });
    }

    let existing_idx = current.iter().position(|t| t.video_id == video_id);
    let existing_svid = existing_idx
        .and_then(|idx| current[idx].set_video_id.as_deref())
        .filter(|s| !s.is_empty())
        .map(ToOwned::to_owned);

    let target_svid = if let Some(svid) = existing_svid {
        Some(svid)
    } else {
        let from_resp = add_track_to_playlist(pid, video_id, None, session)
            .map_err(|_| "기록 재생목록에 곡을 추가하지 못했습니다.".to_owned())?;
        if from_resp.is_some() {
            from_resp
        } else {
            let after_add = get_playlist_tracks(pid, Some(session))?;
            current = after_add;
            current
                .iter()
                .rev()
                .find(|t| t.video_id == video_id)
                .and_then(|t| t.set_video_id.as_deref())
                .filter(|s| !s.is_empty())
                .map(ToOwned::to_owned)
        }
    };

    if let Some(pos) = current.iter().position(|t| t.video_id == video_id) {
        let mut item = current.remove(pos);
        if target_svid.is_some() {
            item.set_video_id = target_svid.clone();
        }
        current.insert(0, item);
    } else if let Some(mut hint) = track_hint {
        hint.video_id = video_id.to_owned();
        hint.set_video_id = target_svid.clone();
        current.insert(0, hint);
    } else {
        if current.len() > 1
            && let Some(ref svid) = target_svid
        {
            try_move_video_to_top_and_trim(pid, svid, &[], session)?;
        }
        let mut tracks = get_playlist_tracks(pid, Some(session))?;
        if let Some(max_len) = limit
            && tracks.len() > max_len
        {
            let overflow = tracks.split_off(max_len);
            let remove_actions: Vec<Value> = overflow
                .iter()
                .filter(|t| valid_video_id(&t.video_id))
                .map(|t| build_remove_playlist_action(&t.video_id, t.set_video_id.as_deref()))
                .collect();
            if !remove_actions.is_empty() {
                let _ = edit_playlist_batched(
                    pid,
                    &remove_actions,
                    session,
                    "오래된 기록을 정리하지 못했습니다.",
                );
            }
        }
        return Ok(RecordHistoryResult {
            tracks: Some(tracks),
            set_video_id: target_svid,
        });
    }

    let mut cleanup_actions: Vec<Value> = Vec::new();
    let mut seen_ids: HashSet<String> = HashSet::with_capacity(current.len());
    let mut deduped: Vec<TrackSummary> = Vec::with_capacity(current.len());
    for t in current {
        if seen_ids.insert(t.video_id.clone()) {
            deduped.push(t);
        } else if valid_video_id(&t.video_id) {
            cleanup_actions.push(build_remove_playlist_action(
                &t.video_id,
                t.set_video_id.as_deref(),
            ));
        }
    }
    current = deduped;

    if let Some(max_len) = limit
        && current.len() > max_len
    {
        for t in current.split_off(max_len) {
            if valid_video_id(&t.video_id) {
                cleanup_actions.push(build_remove_playlist_action(
                    &t.video_id,
                    t.set_video_id.as_deref(),
                ));
            }
        }
    }

    if current.len() > 1
        && let Some(ref svid) = target_svid
    {
        if try_move_video_to_top_and_trim(pid, svid, &cleanup_actions, session).is_err() {
            try_move_video_to_top_and_trim(pid, svid, &[], session)?;
        }
    } else if !cleanup_actions.is_empty() {
        let _ = edit_playlist_batched(
            pid,
            &cleanup_actions,
            session,
            "오래된 기록을 정리하지 못했습니다.",
        );
    }

    Ok(RecordHistoryResult {
        tracks: Some(current),
        set_video_id: target_svid,
    })
}

struct PlayerProfile {
    client_name: &'static str,
    client_version: &'static str,
    client_id: &'static str,
    client_id_num: i64,
    os_name: &'static str,
    os_version: &'static str,
    user_agent: &'static str,
    extra: fn() -> Value,
}

const PLAYER_PROFILES: &[PlayerProfile] = &[
    PlayerProfile {
        client_name: "IOS",
        client_version: "20.10.4",
        client_id: "5",
        client_id_num: 5,
        os_name: "iPhone",
        os_version: "18.3.2.22D82",
        user_agent: "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
        extra: || {
            json!({
                "deviceMake": "Apple",
                "deviceModel": "iPhone16,2",
                "osName": "iPhone",
                "osVersion": "18.3.2.22D82"
            })
        },
    },
    PlayerProfile {
        client_name: "ANDROID",
        client_version: "21.14.484",
        client_id: "3",
        client_id_num: 3,
        os_name: "Android",
        os_version: "15",
        user_agent: "com.google.android.youtube/21.14.484 (Linux; U; Android 15) gzip",
        extra: || {
            json!({
                "androidSdkVersion": 35,
                "osName": "Android",
                "osVersion": "15"
            })
        },
    },
    PlayerProfile {
        client_name: "ANDROID_VR",
        client_version: "1.71.26",
        client_id: "28",
        client_id_num: 28,
        os_name: "Android",
        os_version: "12L",
        user_agent: "com.google.android.apps.youtube.vr.oculus/1.71.26 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
        extra: || {
            json!({
                "deviceMake": "Oculus",
                "deviceModel": "Quest 3",
                "androidSdkVersion": 32,
                "osName": "Android",
                "osVersion": "12L"
            })
        },
    },
];

const PLAYER_GATE_INTERVAL: Duration = Duration::from_millis(1200);
static LAST_PLAYER_FETCH: LazyLock<Mutex<Option<Instant>>> = LazyLock::new(|| Mutex::new(None));

fn wait_player_gate(cancel: Option<&AtomicBool>) -> Result<(), String> {
    let wait_duration = {
        let mut guard = LAST_PLAYER_FETCH
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let now = Instant::now();
        let wait = guard
            .and_then(|last| PLAYER_GATE_INTERVAL.checked_sub(now.saturating_duration_since(last)))
            .unwrap_or(Duration::ZERO);
        *guard = Some(now + wait);
        wait
    };
    if wait_duration.is_zero() {
        return Ok(());
    }
    let mut remaining_ms = wait_duration.as_millis() as u64;
    while remaining_ms > 0 {
        if cancel.is_some_and(|c| c.load(Ordering::Relaxed)) {
            return Err("다운로드가 취소되었습니다.".into());
        }
        let step = remaining_ms.min(50);
        std::thread::sleep(Duration::from_millis(step));
        remaining_ms -= step;
    }
    Ok(())
}

#[derive(Debug, Clone)]
pub struct ResolvedPlayerStreams {
    pub direct_audio: Vec<AudioStreamInfo>,
    pub sabr: Option<SabrAudioSpec>,
}

struct VisitorDataState {
    value: Option<String>,
    fetched_at: Option<Instant>,
    last_attempt_at: Option<Instant>,
}

const VISITOR_DATA_TTL: Duration = Duration::from_secs(6 * 3600);
const VISITOR_DATA_RETRY_COOLDOWN: Duration = Duration::from_secs(30);

static VISITOR_DATA_STATE: LazyLock<RwLock<VisitorDataState>> = LazyLock::new(|| {
    RwLock::new(VisitorDataState {
        value: None,
        fetched_at: None,
        last_attempt_at: None,
    })
});
static VISITOR_DATA_FETCH_LOCK: LazyLock<Mutex<()>> = LazyLock::new(|| Mutex::new(()));

fn current_visitor_data() -> Option<String> {
    let now = Instant::now();
    {
        let guard = VISITOR_DATA_STATE
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let fresh = guard
            .fetched_at
            .is_some_and(|t| now.saturating_duration_since(t) < VISITOR_DATA_TTL);
        if fresh && guard.value.is_some() {
            return guard.value.clone();
        }
        let cooling_down = guard
            .last_attempt_at
            .is_some_and(|t| now.saturating_duration_since(t) < VISITOR_DATA_RETRY_COOLDOWN);
        if cooling_down {
            return guard.value.clone();
        }
    }

    let Ok(_fetch_guard) = VISITOR_DATA_FETCH_LOCK.try_lock() else {
        return VISITOR_DATA_STATE
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .value
            .clone();
    };

    {
        let mut guard = VISITOR_DATA_STATE
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let now2 = Instant::now();
        let fresh = guard
            .fetched_at
            .is_some_and(|t| now2.saturating_duration_since(t) < VISITOR_DATA_TTL);
        if fresh && guard.value.is_some() {
            return guard.value.clone();
        }
        guard.last_attempt_at = Some(now2);
    }

    let fetched = post_web_with_timeout(
        "browse",
        json!({"browseId": "FEwhat_to_watch"}),
        None,
        Some(Duration::from_secs(6)),
    )
    .ok()
    .and_then(|payload| {
        payload
            .pointer("/responseContext/visitorData")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty() && s.len() <= 4096)
            .map(ToOwned::to_owned)
    });

    let mut guard = VISITOR_DATA_STATE
        .write()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if let Some(val) = fetched {
        guard.value = Some(val.clone());
        guard.fetched_at = Some(Instant::now());
        return Some(val);
    }
    guard.value.clone()
}

pub fn reset_visitor_data() {
    let mut guard = VISITOR_DATA_STATE
        .write()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    guard.value = None;
    guard.fetched_at = None;
    guard.last_attempt_at = None;
}

pub fn player_profile_count() -> usize {
    PLAYER_PROFILES.len()
}

pub fn resolve_player_streams_for_profile(
    video_id: &str,
    profile_index: usize,
    cancel: Option<&AtomicBool>,
) -> Result<ResolvedPlayerStreams, (String, bool)> {
    resolve_player_streams_for_profile_with_format(
        video_id,
        profile_index,
        AudioFormat::M4a,
        cancel,
    )
}

pub fn resolve_player_streams_for_profile_with_format(
    video_id: &str,
    profile_index: usize,
    preferred: AudioFormat,
    cancel: Option<&AtomicBool>,
) -> Result<ResolvedPlayerStreams, (String, bool)> {
    if !valid_video_id(video_id) {
        return Err(("올바른 YouTube 영상 ID가 아닙니다.".into(), false));
    }
    let Some(profile) = PLAYER_PROFILES.get(profile_index) else {
        return Err(("오디오 스트림을 찾지 못했습니다.".into(), true));
    };
    wait_player_gate(cancel).map_err(|e| (e, false))?;
    let client = http_client().map_err(|e| (e, false))?;
    let visitor = current_visitor_data();

    let mut client_obj = (profile.extra)();
    client_obj["clientName"] = json!(profile.client_name);
    client_obj["clientVersion"] = json!(profile.client_version);
    client_obj["hl"] = json!("ko");
    client_obj["gl"] = json!("KR");
    if let Some(v) = visitor.as_deref() {
        client_obj["visitorData"] = json!(v);
    }

    let body = json!({
        "videoId": video_id,
        "contentCheckOk": true,
        "racyCheckOk": true,
        "context": {
            "client": client_obj
        }
    });

    let mut req = client
        .post(format!("{INNERTUBE_BASE}/player?prettyPrint=false"))
        .header("Content-Type", "application/json")
        .header("User-Agent", profile.user_agent)
        .header("X-YouTube-Client-Name", profile.client_id)
        .header("X-YouTube-Client-Version", profile.client_version);
    if let Some(v) = visitor.as_deref() {
        req = req.header("X-Goog-Visitor-Id", v);
    }

    let response = req
        .json(&body)
        .send()
        .map_err(|_| ("오디오 정보 서버 연결에 실패했습니다.".to_owned(), true))?;
    let status = response.status();
    if !status.is_success() {
        return Err((format!("오디오 정보 요청 오류 ({status})"), true));
    }

    let payload: Value = response
        .json()
        .map_err(|_| ("오디오 정보 응답을 해석하지 못했습니다.".to_owned(), true))?;

    if payload
        .pointer("/videoDetails/isLive")
        .and_then(Value::as_bool)
        == Some(true)
    {
        return Err((
            "실시간 라이브 스트림은 다운로드할 수 없습니다.".into(),
            false,
        ));
    }

    let mut direct_audio = Vec::new();
    collect_audio_candidates_for_format(
        video_id,
        &payload,
        profile.user_agent,
        preferred,
        &mut direct_audio,
    );
    let sabr = build_sabr_spec(video_id, &payload, profile, preferred);

    if direct_audio.is_empty() && sabr.is_none() {
        let reason = payload
            .pointer("/playabilityStatus/reason")
            .and_then(Value::as_str)
            .unwrap_or("오디오 스트림을 찾지 못했습니다.")
            .to_owned();
        return Err((reason, true));
    }

    Ok(ResolvedPlayerStreams { direct_audio, sabr })
}

pub fn resolve_audio_streams_for_profile(
    video_id: &str,
    profile_index: usize,
) -> Result<Vec<AudioStreamInfo>, String> {
    resolve_player_streams_for_profile(video_id, profile_index, None)
        .map(|resolved| resolved.direct_audio)
        .map_err(|(err, _)| err)
}

pub fn resolve_audio_streams(video_id: &str) -> Result<Vec<AudioStreamInfo>, String> {
    if !valid_video_id(video_id) {
        return Err("올바른 YouTube 영상 ID가 아닙니다.".into());
    }
    let mut last_error = "오디오 스트림을 찾지 못했습니다.".to_owned();
    for idx in 0..PLAYER_PROFILES.len() {
        match resolve_audio_streams_for_profile(video_id, idx) {
            Ok(streams) if !streams.is_empty() => return Ok(streams),
            Ok(_) => {}
            Err(err) => last_error = err,
        }
    }
    Err(last_error)
}

pub fn resolve_audio_stream(video_id: &str) -> Result<AudioStreamInfo, String> {
    resolve_audio_streams(video_id)?
        .into_iter()
        .next()
        .ok_or_else(|| "오디오 스트림을 찾지 못했습니다.".into())
}

fn select_sorted_sabr_audio(
    formats: &[SabrAdaptiveFormat],
    preferred: AudioFormat,
) -> Vec<SabrAdaptiveFormat> {
    let pick_best = |codec: AudioFormat, allow_drc: bool| -> Option<SabrAdaptiveFormat> {
        formats
            .iter()
            .filter(|f| {
                f.is_audio()
                    && codec.matches_sabr(f)
                    && f.content_length > 0
                    && !f.is_vb
                    && (allow_drc || !f.is_drc)
            })
            .rev()
            .max_by_key(|f| {
                (
                    f.audio_track_is_default != Some(false),
                    f.content_length,
                    f.bitrate,
                )
            })
            .cloned()
    };
    let mut selected = Vec::new();
    if let Some(primary) = pick_best(preferred, false).or_else(|| pick_best(preferred, true)) {
        selected.push(primary);
    }
    let alt = preferred.fallback();
    if let Some(secondary) = pick_best(alt, false).or_else(|| pick_best(alt, true)) {
        selected.push(secondary);
    }
    selected
}

fn build_sabr_spec_from_payload(
    video_id: &str,
    payload: &Value,
    sabr_url: &str,
    po_token: Option<Vec<u8>>,
    cookie: Option<String>,
    origin: Option<String>,
    client_info: SabrClientInfo,
    user_agent: String,
    preferred: AudioFormat,
) -> Option<SabrAudioSpec> {
    if !sabr_url.starts_with("https://") {
        return None;
    }
    let ustreamer_b64 = payload
        .pointer("/playerConfig/mediaCommonConfig/mediaUstreamerRequestConfig/videoPlaybackUstreamerConfig")
        .and_then(Value::as_str)?;
    let ustreamer_config = sabr::decode_base64_lenient(ustreamer_b64)?;
    let adaptive = payload
        .pointer("/streamingData/adaptiveFormats")
        .and_then(Value::as_array)?;
    let parsed: Vec<SabrAdaptiveFormat> = adaptive
        .iter()
        .filter_map(SabrAdaptiveFormat::from_json)
        .collect();
    let audio_formats = select_sorted_sabr_audio(&parsed, preferred);
    if audio_formats.is_empty() {
        return None;
    }
    let fallback_video = parsed.iter().rev().find(|f| f.is_video()).cloned();

    Some(SabrAudioSpec {
        video_id: video_id.to_owned(),
        sabr_url: sabr_url.to_owned(),
        ustreamer_config,
        po_token,
        cookie,
        origin,
        client_info,
        user_agent,
        audio_formats,
        fallback_video,
    })
}

pub fn build_web_sabr_spec(
    video_id: &str,
    input: &sabr::WebSabrSessionInput,
    preferred: AudioFormat,
) -> Option<SabrAudioSpec> {
    if input
        .player_response
        .pointer("/videoDetails/isLive")
        .and_then(Value::as_bool)
        == Some(true)
    {
        return None;
    }
    let po_token = input
        .po_token
        .as_deref()
        .filter(|s| !s.trim().is_empty())
        .and_then(sabr::decode_base64_lenient);
    let client_info = SabrClientInfo {
        client_name_id: input.client_name_id.unwrap_or(1),
        client_version: input
            .client_version
            .clone()
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| WEB_CLIENT_VERSION.to_owned()),
        os_name: input.os_name.clone().unwrap_or_default(),
        os_version: input.os_version.clone().unwrap_or_default(),
    };
    let user_agent = input
        .user_agent
        .clone()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| auth::USER_AGENT.to_owned());
    let origin = input
        .origin
        .clone()
        .filter(|s| !s.trim().is_empty())
        .or_else(|| Some(auth::ORIGIN.to_owned()));
    build_sabr_spec_from_payload(
        video_id,
        &input.player_response,
        &input.sabr_url,
        po_token,
        input.cookie.clone(),
        origin,
        client_info,
        user_agent,
        preferred,
    )
}

fn build_sabr_spec(
    video_id: &str,
    payload: &Value,
    profile: &PlayerProfile,
    preferred: AudioFormat,
) -> Option<SabrAudioSpec> {
    let sabr_url = payload
        .pointer("/streamingData/serverAbrStreamingUrl")
        .and_then(Value::as_str)?;
    build_sabr_spec_from_payload(
        video_id,
        payload,
        sabr_url,
        None,
        None,
        None,
        SabrClientInfo {
            client_name_id: profile.client_id_num,
            client_version: profile.client_version.to_owned(),
            os_name: profile.os_name.to_owned(),
            os_version: profile.os_version.to_owned(),
        },
        profile.user_agent.to_owned(),
        preferred,
    )
}

#[cfg(test)]
fn collect_audio_candidates(
    video_id: &str,
    payload: &Value,
    user_agent: &str,
    out: &mut Vec<AudioStreamInfo>,
) {
    collect_audio_candidates_for_format(video_id, payload, user_agent, AudioFormat::M4a, out);
}

fn collect_audio_candidates_for_format(
    video_id: &str,
    payload: &Value,
    user_agent: &str,
    preferred: AudioFormat,
    out: &mut Vec<AudioStreamInfo>,
) {
    let Some(adaptive) = payload
        .pointer("/streamingData/adaptiveFormats")
        .and_then(Value::as_array)
    else {
        return;
    };

    let mut m4a_candidates: Vec<((bool, bool, u64, u64), AudioStreamInfo)> = Vec::new();
    let mut opus_candidates: Vec<((bool, bool, u64, u64), AudioStreamInfo)> = Vec::new();
    for fmt in adaptive {
        let mime = fmt.get("mimeType").and_then(Value::as_str).unwrap_or("");
        if !mime.starts_with("audio/") {
            continue;
        }
        if fmt.get("isVb").and_then(Value::as_bool) == Some(true) {
            continue;
        }
        let Some(url) = fmt.get("url").and_then(Value::as_str) else {
            continue;
        };
        if !url.starts_with("https://") {
            continue;
        }
        let codecs = sabr::mime_codecs(mime);
        let (codec, extension) =
            if codecs.starts_with("mp4a") || (codecs.is_empty() && mime.starts_with("audio/mp4")) {
                (AudioFormat::M4a, "m4a")
            } else if codecs.starts_with("opus")
                || (codecs.is_empty() && mime.starts_with("audio/webm"))
            {
                (AudioFormat::Opus, "webm")
            } else {
                continue;
            };
        let is_non_drc = fmt.get("isDrc").and_then(Value::as_bool) != Some(true);
        let is_default_track = fmt
            .pointer("/audioTrack/audioIsDefault")
            .and_then(Value::as_bool)
            != Some(false);
        let bitrate = fmt
            .get("averageBitrate")
            .or_else(|| fmt.get("bitrate"))
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let content_length = fmt.get("contentLength").and_then(|v| {
            v.as_u64()
                .or_else(|| v.as_str().and_then(|s| s.parse::<u64>().ok()))
        });

        let candidate = AudioStreamInfo {
            video_id: video_id.to_owned(),
            url: url.to_owned(),
            mime_type: mime.to_owned(),
            extension: extension.to_owned(),
            codec,
            bitrate,
            content_length,
            user_agent: user_agent.to_owned(),
        };
        let score = (
            is_non_drc,
            is_default_track,
            content_length.unwrap_or(0),
            bitrate,
        );
        match codec {
            AudioFormat::M4a => m4a_candidates.push((score, candidate)),
            AudioFormat::Opus => opus_candidates.push((score, candidate)),
        }
    }

    let best_m4a = m4a_candidates
        .into_iter()
        .rev()
        .max_by_key(|(s, _)| *s)
        .map(|(_, c)| c);
    let best_opus = opus_candidates
        .into_iter()
        .rev()
        .max_by_key(|(s, _)| *s)
        .map(|(_, c)| c);

    match preferred {
        AudioFormat::Opus => {
            if let Some(best) = best_opus {
                out.push(best);
            }
            if let Some(best) = best_m4a {
                out.push(best);
            }
        }
        AudioFormat::M4a => {
            if let Some(best) = best_m4a {
                out.push(best);
            }
            if let Some(best) = best_opus {
                out.push(best);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn computes_minimal_moves_using_lis() {
        let current = ["a", "b", "c", "d", "e"];
        let desired = ["e", "a", "b", "c", "d"];
        assert_eq!(minimal_move_indices(&current, &desired), vec![0]);

        let same = ["a", "b", "c"];
        assert!(minimal_move_indices(&same, &same).is_empty());
    }

    #[test]
    fn extracts_continuation_token_from_browse_payload() {
        let payload = json!({
            "gridRenderer": {
                "items": [{
                    "continuationItemRenderer": {
                        "continuationEndpoint": {
                            "continuationCommand": {
                                "token": "next-page-token-123"
                            }
                        }
                    }
                }]
            }
        });
        assert_eq!(
            extract_continuation_token(&payload).as_deref(),
            Some("next-page-token-123")
        );
    }

    #[test]
    fn ignores_recommended_videos_and_sibling_continuations() {
        let payload = json!({
            "contents": {
                "twoColumnBrowseResultsRenderer": {
                    "tabs": [{
                        "tabRenderer": {
                            "content": {
                                "sectionListRenderer": {
                                    "contents": [
                                        {
                                            "itemSectionRenderer": {
                                                "contents": [{
                                                    "playlistVideoListRenderer": {
                                                        "contents": [{
                                                            "playlistVideoRenderer": {
                                                                "videoId": "aaaaaaaaaaa",
                                                                "setVideoId": "svid-1",
                                                                "title": {"runs": [{"text": "My Real Song"}]},
                                                                "shortBylineText": {"runs": [{"text": "Artist"}]},
                                                                "lengthText": {"simpleText": "3:00"}
                                                            }
                                                        }]
                                                    }
                                                }]
                                            }
                                        },
                                        {
                                            "itemSectionRenderer": {
                                                "contents": [
                                                    {
                                                        "playlistVideoRenderer": {
                                                            "videoId": "bbbbbbbbbbb",
                                                            "title": {"runs": [{"text": "Recommended Junk"}]}
                                                        }
                                                    },
                                                    {
                                                        "continuationItemRenderer": {
                                                            "continuationEndpoint": {
                                                                "continuationCommand": {
                                                                    "token": "evil-recommended-token"
                                                                }
                                                            }
                                                        }
                                                    }
                                                ]
                                            }
                                        }
                                    ]
                                }
                            }
                        }
                    }]
                }
            }
        });
        let mut tracks = Vec::new();
        let mut seen = HashSet::new();
        let next_token = parse_initial_playlist_page(&payload, &mut tracks, &mut seen);
        assert_eq!(tracks.len(), 1);
        assert_eq!(tracks[0].video_id, "aaaaaaaaaaa");
        assert_eq!(next_token, None);
    }

    #[test]
    fn continues_playlist_pagination_across_pages_without_rm_playlists() {
        let page1 = json!({
            "gridRenderer": {
                "items": [
                    {
                        "gridPlaylistRenderer": {
                            "playlistId": "PL_RM_1",
                            "title": {"simpleText": "First.rm"}
                        }
                    },
                    {
                        "continuationItemRenderer": {
                            "continuationEndpoint": {
                                "continuationCommand": {"token": "tok-page-2"}
                            }
                        }
                    }
                ]
            }
        });
        let page2 = json!({
            "onResponseReceivedActions": [{
                "appendContinuationItemsAction": {
                    "continuationItems": [
                        {
                            "gridPlaylistRenderer": {
                                "playlistId": "PL_NORMAL",
                                "title": {"simpleText": "Regular YouTube Playlist"}
                            }
                        },
                        {
                            "continuationItemRenderer": {
                                "continuationEndpoint": {
                                    "continuationCommand": {"token": "tok-page-3"}
                                }
                            }
                        }
                    ]
                }
            }]
        });
        let page3 = json!({
            "onResponseReceivedActions": [{
                "appendContinuationItemsAction": {
                    "continuationItems": [{
                        "gridPlaylistRenderer": {
                            "playlistId": "PL_RM_2",
                            "title": {"simpleText": "ThirdPage.rm"}
                        }
                    }]
                }
            }]
        });

        let list = collect_replica_playlists_paged(page1, |token| match token {
            "tok-page-2" => Ok(page2.clone()),
            "tok-page-3" => Ok(page3.clone()),
            _ => Err("unexpected token".into()),
        })
        .unwrap();
        assert_eq!(list.len(), 2);
        assert_eq!(list[0].id, "PL_RM_1");
        assert_eq!(list[1].id, "PL_RM_2");
    }

    #[test]
    fn selects_audio_only_formats_and_excludes_video() {
        let payload = json!({
            "streamingData": {
                "adaptiveFormats": [
                    {
                        "mimeType": "audio/webm; codecs=\"opus\"",
                        "url": "https://example.com/audio.webm",
                        "averageBitrate": 160000
                    },
                    {
                        "mimeType": "audio/mp4; codecs=\"mp4a.40.2\"",
                        "url": "https://example.com/audio-drc.m4a",
                        "averageBitrate": 160000,
                        "isDrc": true
                    },
                    {
                        "mimeType": "audio/mp4; codecs=\"mp4a.40.2\"",
                        "url": "https://example.com/audio.m4a",
                        "averageBitrate": 128000,
                        "audioTrack": {"audioIsDefault": true}
                    },
                    {
                        "mimeType": "audio/mp4; codecs=\"mp4a.40.2\"",
                        "url": "https://example.com/audio-dub.m4a",
                        "averageBitrate": 128000,
                        "contentLength": "9999999",
                        "audioTrack": {"audioIsDefault": false}
                    }
                ],
                "formats": [
                    {
                        "mimeType": "video/mp4; codecs=\"avc1\"",
                        "url": "https://example.com/video.mp4",
                        "bitrate": 800000
                    }
                ]
            }
        });
        let mut out = Vec::new();
        collect_audio_candidates("aaaaaaaaaaa", &payload, "UA", &mut out);
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].extension, "m4a");
        assert_eq!(out[0].codec, AudioFormat::M4a);
        assert_eq!(out[0].url, "https://example.com/audio.m4a");
        assert_eq!(out[1].extension, "webm");
        assert_eq!(out[1].codec, AudioFormat::Opus);
        assert!(out.iter().all(|s| s.mime_type.starts_with("audio/")));

        let mut opus_first = Vec::new();
        collect_audio_candidates_for_format(
            "aaaaaaaaaaa",
            &payload,
            "UA",
            AudioFormat::Opus,
            &mut opus_first,
        );
        assert_eq!(opus_first.len(), 2);
        assert_eq!(opus_first[0].codec, AudioFormat::Opus);
        assert_eq!(opus_first[0].url, "https://example.com/audio.webm");
        assert_eq!(opus_first[1].codec, AudioFormat::M4a);
    }

    #[test]
    fn selects_sabr_audio_by_preferred_codec_with_fallback() {
        let formats = vec![
            SabrAdaptiveFormat::from_json(&json!({
                "itag": 251,
                "lastModified": "100",
                "mimeType": "audio/webm; codecs=\"opus\"",
                "contentLength": "3000000",
                "averageBitrate": 160000
            }))
            .unwrap(),
            SabrAdaptiveFormat::from_json(&json!({
                "itag": 250,
                "lastModified": "100",
                "mimeType": "audio/webm; codecs=\"opus\"",
                "contentLength": "1500000",
                "averageBitrate": 70000
            }))
            .unwrap(),
            SabrAdaptiveFormat::from_json(&json!({
                "itag": 140,
                "lastModified": "100",
                "mimeType": "audio/mp4; codecs=\"mp4a.40.2\"",
                "contentLength": "2500000",
                "averageBitrate": 128000
            }))
            .unwrap(),
        ];

        let opus_order = select_sorted_sabr_audio(&formats, AudioFormat::Opus);
        assert_eq!(opus_order.len(), 2);
        assert_eq!(opus_order[0].itag, 251);
        assert_eq!(opus_order[1].itag, 140);

        let m4a_order = select_sorted_sabr_audio(&formats, AudioFormat::M4a);
        assert_eq!(m4a_order.len(), 2);
        assert_eq!(m4a_order[0].itag, 140);
        assert_eq!(m4a_order[1].itag, 251);

        let aac_only = select_sorted_sabr_audio(&formats[2..], AudioFormat::Opus);
        assert_eq!(aac_only.len(), 1);
        assert_eq!(aac_only[0].itag, 140);
    }

    #[test]
    fn builds_history_trim_actions_and_skips_kept_or_invalid_tracks() {
        let targets = vec![
            HistoryTrimTarget {
                video_id: "aaaaaaaaaaa".into(),
                set_video_id: Some("svid-keep".into()),
            },
            HistoryTrimTarget {
                video_id: "bbbbbbbbbbb".into(),
                set_video_id: Some("svid-old-1".into()),
            },
            HistoryTrimTarget {
                video_id: "ccccccccccc".into(),
                set_video_id: None,
            },
            HistoryTrimTarget {
                video_id: "bad".into(),
                set_video_id: Some("svid-bad".into()),
            },
        ];
        let actions = build_trim_actions_from_targets(&targets, "aaaaaaaaaaa");
        assert_eq!(actions.len(), 2);
        assert_eq!(actions[0]["action"], "ACTION_REMOVE_VIDEO");
        assert_eq!(actions[0]["setVideoId"], "svid-old-1");
        assert_eq!(actions[0]["removedVideoId"], "bbbbbbbbbbb");
        assert_eq!(actions[1]["action"], "ACTION_REMOVE_VIDEO_BY_VIDEO_ID");
        assert_eq!(actions[1]["removedVideoId"], "ccccccccccc");
    }
}
