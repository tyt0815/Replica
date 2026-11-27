use reqwest::blocking::RequestBuilder;
use serde::Deserialize;
use sha1::{Digest, Sha1};

pub const ORIGIN: &str = "https://www.youtube.com";
pub const USER_AGENT: &str = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36";

#[derive(Clone, Deserialize)]
pub struct WebSession {
    pub cookie: String,
    pub client_version: String,
    pub visitor_data: String,
    #[serde(default)]
    pub auth_user: u32,
    pub delegated_session_id: Option<String>,
}

fn cookie_value<'a>(cookie: &'a str, name: &str) -> Option<&'a str> {
    cookie
        .split(';')
        .filter_map(|p| p.trim().split_once('='))
        .find_map(|(k, v)| (k == name && !v.is_empty()).then_some(v))
}

impl WebSession {
    pub fn delegated_id(&self) -> Option<&str> {
        self.delegated_session_id
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty() && !s.eq_ignore_ascii_case("null"))
    }

    pub fn validate(&self) -> Result<(), String> {
        let header_safe = |s: &str, max: usize| {
            !s.is_empty() && s.len() <= max && s.bytes().all(|b| (32..127).contains(&b))
        };
        if !header_safe(&self.cookie, 32768)
            || !header_safe(&self.client_version, 128)
            || !header_safe(&self.visitor_data, 4096)
            || self.auth_user > 99
            || self.delegated_id().is_some_and(|s| !header_safe(s, 256))
            || self.sapisid().is_none()
        {
            return Err(
                "웹 로그인 세션이 올바르지 않습니다. Google 계정을 다시 연결하세요.".into(),
            );
        }
        Ok(())
    }

    fn sapisid(&self) -> Option<&str> {
        cookie_value(&self.cookie, "SAPISID")
            .or_else(|| cookie_value(&self.cookie, "__Secure-3PAPISID"))
    }

    fn authorization_at(&self, seconds: u64) -> Result<String, String> {
        self.validate()?;
        let sapisid = self.sapisid().ok_or("SAPISID 쿠키가 없습니다.")?;
        let digest = Sha1::digest(format!("{seconds} {sapisid} {ORIGIN}").as_bytes());
        Ok(format!("SAPISIDHASH {seconds}_{digest:x}"))
    }
}

pub fn authorize(request: RequestBuilder, session: &WebSession) -> Result<RequestBuilder, String> {
    let target = request
        .try_clone()
        .and_then(|r| r.build().ok())
        .ok_or("인증 요청을 확인할 수 없습니다.")?;
    let url = target.url();
    if url.scheme() != "https"
        || url.host_str() != Some("www.youtube.com")
        || !url.username().is_empty()
        || url.password().is_some()
        || url.port().is_some_and(|p| p != 443)
    {
        return Err("허용되지 않은 인증 대상 주소입니다.".into());
    }
    let seconds = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|_| "기기 시각을 확인하세요.")?
        .as_secs();
    let request = request
        .header("Cookie", &session.cookie)
        .header("Authorization", session.authorization_at(seconds)?)
        .header("Origin", ORIGIN)
        .header("X-Origin", ORIGIN)
        .header("Referer", format!("{ORIGIN}/"))
        .header("X-Goog-AuthUser", session.auth_user.to_string())
        .header("X-Goog-Visitor-Id", &session.visitor_data)
        .header("User-Agent", USER_AGENT);
    Ok(if let Some(id) = session.delegated_id() {
        request.header("X-Goog-PageId", id)
    } else {
        request
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ignores_literal_null_delegated_session_id() {
        let session = WebSession {
            cookie: "SID=a; SAPISID=secret-token".into(),
            client_version: "2.20261020.01.00".into(),
            visitor_data: "visitor".into(),
            auth_user: 0,
            delegated_session_id: Some("null".into()),
        };
        assert_eq!(session.delegated_id(), None);
        assert!(session.validate().is_ok());
    }

    #[test]
    fn generates_sapisidhash_from_cookie() {
        let session = WebSession {
            cookie: "SID=a; SAPISID=secret-token".into(),
            client_version: "2.20261020.01.00".into(),
            visitor_data: "visitor".into(),
            auth_user: 0,
            delegated_session_id: None,
        };
        let hash = session.authorization_at(1700000000).unwrap();
        let expected = format!(
            "SAPISIDHASH 1700000000_{:x}",
            Sha1::digest(b"1700000000 secret-token https://www.youtube.com")
        );
        assert_eq!(hash, expected);
    }
}
