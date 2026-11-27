pub const PLAYLIST_SUFFIX: &str = ".rm";
pub const HISTORY_PREFIX: &str = "history.";
pub const LEGACY_HISTORY_TITLE: &str = "history.rm";

pub fn is_replica_playlist(raw_title: &str) -> bool {
    let trimmed = raw_title.trim();
    trimmed.ends_with(PLAYLIST_SUFFIX) && trimmed.len() > PLAYLIST_SUFFIX.len()
}

pub fn sanitize_device_name(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    let mut prev_space = false;
    for ch in raw.trim().chars() {
        if ch == '.' || ch.is_control() {
            if !prev_space && !out.is_empty() {
                out.push(' ');
                prev_space = true;
            }
            continue;
        }
        if ch.is_whitespace() {
            if !prev_space && !out.is_empty() {
                out.push(' ');
                prev_space = true;
            }
            continue;
        }
        out.push(ch);
        prev_space = false;
        if out.chars().count() >= 40 {
            break;
        }
    }
    let cleaned = out.trim().to_owned();
    if cleaned.is_empty() {
        "Device".to_owned()
    } else {
        cleaned
    }
}

pub fn is_history_playlist(raw_title: &str) -> bool {
    let trimmed = raw_title.trim();
    if !is_replica_playlist(trimmed) {
        return false;
    }
    let lower = trimmed.to_lowercase();
    if lower == LEGACY_HISTORY_TITLE {
        return true;
    }
    if let Some(rest) = lower.strip_prefix(HISTORY_PREFIX)
        && let Some(device) = rest.strip_suffix(PLAYLIST_SUFFIX)
    {
        return !device.trim().is_empty();
    }
    false
}

pub fn history_device_name(raw_title: &str) -> Option<String> {
    let trimmed = raw_title.trim();
    if !is_replica_playlist(trimmed) {
        return None;
    }
    let stem = strip_suffix(trimmed);
    if stem.len() > HISTORY_PREFIX.len()
        && stem[..HISTORY_PREFIX.len()].eq_ignore_ascii_case(HISTORY_PREFIX)
    {
        let device = stem[HISTORY_PREFIX.len()..].trim();
        if !device.is_empty() {
            return Some(device.to_owned());
        }
    }
    None
}

pub fn to_history_remote_title(device_name: &str) -> String {
    let clean = sanitize_device_name(device_name);
    format!("History.{clean}{PLAYLIST_SUFFIX}")
}

pub fn parse_playlist_timestamp(raw_title: &str) -> u64 {
    let trimmed = raw_title.trim();
    if !is_replica_playlist(trimmed) || is_history_playlist(trimmed) {
        return 0;
    }
    let stem = strip_suffix(trimmed);
    if let Some((base, ts_str)) = stem.rsplit_once('.') {
        let ts_trimmed = ts_str.trim();
        if !base.trim().is_empty()
            && (10..=13).contains(&ts_trimmed.len())
            && ts_trimmed.bytes().all(|b| b.is_ascii_digit())
            && let Ok(ts) = ts_trimmed.parse::<u64>()
        {
            return ts;
        }
    }
    0
}

pub fn to_remote_title(display_title: &str) -> Option<String> {
    let clean = to_display_title(display_title);
    if clean.is_empty() {
        return None;
    }
    Some(format!("{clean}{PLAYLIST_SUFFIX}"))
}

pub fn to_versioned_remote_title(display_title: &str, unix_seconds: u64) -> Option<String> {
    let clean = to_display_title(display_title);
    if clean.is_empty() {
        return None;
    }
    if unix_seconds > 0 {
        Some(format!("{clean}.{unix_seconds}{PLAYLIST_SUFFIX}"))
    } else {
        Some(format!("{clean}{PLAYLIST_SUFFIX}"))
    }
}

pub fn to_display_title(raw_title: &str) -> String {
    let trimmed = raw_title.trim();
    if let Some(device) = history_device_name(trimmed) {
        return device;
    }
    let stem = strip_suffix(trimmed);
    if let Some((base, ts_str)) = stem.rsplit_once('.') {
        let ts_trimmed = ts_str.trim();
        if !base.trim().is_empty()
            && (10..=13).contains(&ts_trimmed.len())
            && ts_trimmed.bytes().all(|b| b.is_ascii_digit())
        {
            return base.trim().to_owned();
        }
    }
    stem.to_owned()
}

fn strip_suffix(title: &str) -> &str {
    title
        .strip_suffix(PLAYLIST_SUFFIX)
        .unwrap_or(title)
        .trim_end()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn filters_only_valid_replica_playlists() {
        assert!(is_replica_playlist("Chill Mix.rm"));
        assert!(is_replica_playlist("Chill Mix.1795747025.rm"));
        assert!(is_replica_playlist("  Workout.rm  "));
        assert!(!is_replica_playlist("Workout"));
        assert!(!is_replica_playlist(".rm"));
        assert!(!is_replica_playlist("   .rm   "));
    }

    #[test]
    fn formats_remote_title_with_single_suffix() {
        assert_eq!(
            to_remote_title("Night Drive").as_deref(),
            Some("Night Drive.rm")
        );
        assert_eq!(
            to_remote_title("Night Drive.rm").as_deref(),
            Some("Night Drive.rm")
        );
        assert_eq!(
            to_versioned_remote_title("Night Drive.1700000000.rm", 1795747025).as_deref(),
            Some("Night Drive.1795747025.rm")
        );
        assert_eq!(to_remote_title("   "), None);
        assert_eq!(to_remote_title(".rm"), None);
    }

    #[test]
    fn hides_suffix_and_timestamp_for_display() {
        assert_eq!(to_display_title("Night Drive.rm"), "Night Drive");
        assert_eq!(to_display_title("Night Drive.1795747025.rm"), "Night Drive");
        assert_eq!(to_display_title("Ver 2.0.1795747025.rm"), "Ver 2.0");
        assert_eq!(to_display_title("Ver 2.0.rm"), "Ver 2.0");
        assert_eq!(
            parse_playlist_timestamp("Night Drive.1795747025.rm"),
            1795747025
        );
        assert_eq!(parse_playlist_timestamp("Ver 2.0.rm"), 0);
        assert_eq!(to_display_title("Night Drive"), "Night Drive");
    }

    #[test]
    fn handles_device_history_titles() {
        assert!(is_history_playlist("History.rm"));
        assert!(is_history_playlist("History.OO의 폴드8.rm"));
        assert!(!is_history_playlist("My History.rm"));
        assert_eq!(
            history_device_name("History.OO의 폴드8.rm").as_deref(),
            Some("OO의 폴드8")
        );
        assert_eq!(history_device_name("History.rm"), None);
        assert_eq!(
            to_history_remote_title("  OO의.폴드8  "),
            "History.OO의 폴드8.rm"
        );
        assert_eq!(parse_playlist_timestamp("History.1795747025.rm"), 0);
    }
}
