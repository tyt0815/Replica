use reqwest::blocking::Client;
use serde::Deserialize;
use serde_json::Value;
use std::{
    collections::{BTreeMap, BTreeSet, HashMap},
    fs::{File, OpenOptions},
    io::{self, Read, Seek, SeekFrom, Write},
    path::Path,
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

const VIEWPORT_WIDTH: i64 = 640;
const VIEWPORT_HEIGHT: i64 = 360;
const MAX_CONSECUTIVE_EMPTY_ROUNDS: u32 = 3;
const MAX_TOTAL_ROUNDS: u32 = 400;
const MIN_EMPTY_ROUND_BACKOFF_MS: u64 = 2000;
const MAX_TRANSIENT_ROUND_RETRIES: u32 = 3;
const TRANSIENT_RETRY_BACKOFF_MS: [u64; 3] = [800, 2000, 4000];

const ID_EBML: u64 = 0x1A45_DFA3;
const ID_SEGMENT: u64 = 0x1853_8067;
const ID_CLUSTER: u64 = 0x1F43_B675;
const SEGMENT_CHILDREN: [u64; 10] = [
    0x114D_9B74,
    0x1549_A966,
    0x1654_AE6B,
    ID_CLUSTER,
    0x1C53_BB6B,
    0x1941_A469,
    0x1043_A770,
    0x1254_C367,
    0xEC,
    0xBF,
];
const CLUSTER_CHILDREN: [u64; 9] = [0xE7, 0x5854, 0xA7, 0xAB, 0xA3, 0xA0, 0xAF, 0xEC, 0xBF];

const fn fourcc(name: &[u8; 4]) -> u32 {
    u32::from_be_bytes(*name)
}

const BOX_FTYP: u32 = fourcc(b"ftyp");
const BOX_MOOV: u32 = fourcc(b"moov");
const BOX_MOOF: u32 = fourcc(b"moof");
const BOX_MDAT: u32 = fourcc(b"mdat");
const MP4_SHARED: [u32; 7] = [
    fourcc(b"sidx"),
    fourcc(b"free"),
    fourcc(b"skip"),
    fourcc(b"uuid"),
    fourcc(b"styp"),
    fourcc(b"emsg"),
    fourcc(b"prft"),
];
const MP4_INIT_ONLY: [u32; 4] = [BOX_FTYP, BOX_MOOV, fourcc(b"pdin"), fourcc(b"meta")];
const MP4_MEDIA_ONLY: [u32; 4] = [BOX_MOOF, BOX_MDAT, fourcc(b"ssix"), fourcc(b"mfra")];

mod ump_part {
    pub const MEDIA_HEADER: u64 = 20;
    pub const MEDIA_DATA: u64 = 21;
    pub const MEDIA_END: u64 = 22;
    pub const NEXT_REQUEST_POLICY: u64 = 35;
    pub const SABR_REDIRECT: u64 = 43;
    pub const SABR_ERROR: u64 = 44;
    pub const SABR_CONTEXT_UPDATE: u64 = 57;
    pub const STREAM_PROTECTION_STATUS: u64 = 58;
    pub const SABR_CONTEXT_SENDING_POLICY: u64 = 59;
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SabrErrorKind {
    PoTokenInvalid,
    AttestationPending,
    Retryable,
    Cancelled,
    Fatal,
}

#[derive(Clone, Debug)]
pub struct SabrError {
    pub kind: SabrErrorKind,
    pub message: String,
}

impl SabrError {
    pub fn new(kind: SabrErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
        }
    }

    pub fn is_stream_protection(&self) -> bool {
        matches!(
            self.kind,
            SabrErrorKind::PoTokenInvalid | SabrErrorKind::AttestationPending
        )
    }

    pub fn is_retryable(&self) -> bool {
        matches!(
            self.kind,
            SabrErrorKind::Retryable
                | SabrErrorKind::PoTokenInvalid
                | SabrErrorKind::AttestationPending
        )
    }
}

#[derive(Clone, Debug, Deserialize)]
pub struct WebSabrSessionInput {
    pub player_response: Value,
    pub sabr_url: String,
    #[serde(default)]
    pub po_token: Option<String>,
    #[serde(default)]
    pub client_version: Option<String>,
    #[serde(default)]
    pub client_name_id: Option<i64>,
    #[serde(default)]
    pub os_name: Option<String>,
    #[serde(default)]
    pub os_version: Option<String>,
    #[serde(default)]
    pub user_agent: Option<String>,
    #[serde(default)]
    pub cookie: Option<String>,
    #[serde(default)]
    pub origin: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct FormatId {
    pub itag: i32,
    pub lmt: i64,
    pub xtag: String,
}

impl FormatId {
    fn encode(&self) -> ProtoWriter {
        ProtoWriter::new()
            .varint(1, Some(i64::from(self.itag)))
            .varint(2, Some(self.lmt))
            .string(3, Some(&self.xtag))
    }

    fn matches(&self, itag: i32, lmt: i64, xtag: Option<&str>) -> bool {
        if self.itag != itag {
            return false;
        }
        if self.lmt != 0 && lmt != 0 && self.lmt != lmt {
            return false;
        }
        if !self.xtag.is_empty()
            && let Some(other) = xtag.filter(|s| !s.is_empty())
            && self.xtag != other
        {
            return false;
        }
        true
    }
}

pub fn mime_codecs(mime_type: &str) -> &str {
    mime_type.split_once("codecs=").map_or("", |(_, codecs)| {
        codecs.trim_matches(|c| c == '"' || c == ' ')
    })
}

#[derive(Clone, Debug)]
pub struct SabrAdaptiveFormat {
    pub itag: i32,
    pub lmt: i64,
    pub xtag: Option<String>,
    pub mime_type: String,
    pub extension: String,
    pub content_length: u64,
    pub bitrate: u64,
    pub approx_duration_ms: i64,
    pub audio_track_is_default: Option<bool>,
    pub audio_track_id: Option<String>,
    pub is_drc: bool,
    pub is_vb: bool,
}

impl SabrAdaptiveFormat {
    pub fn from_json(json: &Value) -> Option<Self> {
        let parse_i64 = |key: &str| {
            json.get(key).and_then(|v| {
                v.as_i64()
                    .or_else(|| v.as_str().and_then(|s| s.parse::<i64>().ok()))
            })
        };
        let itag = i32::try_from(parse_i64("itag")?).ok()?;
        let mime_type = json
            .get("mimeType")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned();
        let codecs = mime_codecs(&mime_type);
        let extension = if mime_type.starts_with("audio/mp4") || codecs.starts_with("mp4a") {
            "m4a".to_owned()
        } else if mime_type.starts_with("audio/webm") || codecs.starts_with("opus") {
            "webm".to_owned()
        } else if mime_type.starts_with("video/mp4") {
            "mp4".to_owned()
        } else if mime_type.starts_with("video/webm") {
            "webm".to_owned()
        } else {
            String::new()
        };
        let audio_track_is_default = json
            .pointer("/audioTrack/audioIsDefault")
            .and_then(Value::as_bool);
        let audio_track_id = json
            .pointer("/audioTrack/id")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned);
        let content_length = parse_i64("contentLength").unwrap_or(0).max(0) as u64;
        let bitrate = parse_i64("averageBitrate")
            .or_else(|| parse_i64("bitrate"))
            .unwrap_or(0)
            .max(0) as u64;

        Some(Self {
            itag,
            lmt: parse_i64("lastModified").unwrap_or(0),
            xtag: json
                .get("xtags")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned),
            mime_type,
            extension,
            content_length,
            bitrate,
            approx_duration_ms: parse_i64("approxDurationMs").unwrap_or(0),
            audio_track_is_default,
            audio_track_id,
            is_drc: json.get("isDrc").and_then(Value::as_bool).unwrap_or(false),
            is_vb: json.get("isVb").and_then(Value::as_bool).unwrap_or(false),
        })
    }

    pub fn is_audio(&self) -> bool {
        self.mime_type.starts_with("audio/") && !self.extension.is_empty()
    }

    pub fn is_opus(&self) -> bool {
        let codecs = mime_codecs(&self.mime_type);
        self.mime_type.starts_with("audio/")
            && (codecs.starts_with("opus") || (codecs.is_empty() && self.extension == "webm"))
    }

    pub fn is_aac(&self) -> bool {
        let codecs = mime_codecs(&self.mime_type);
        self.mime_type.starts_with("audio/")
            && (codecs.starts_with("mp4a") || (codecs.is_empty() && self.extension == "m4a"))
    }

    pub fn is_video(&self) -> bool {
        self.mime_type.starts_with("video/")
    }

    pub fn format_id(&self) -> FormatId {
        FormatId {
            itag: self.itag,
            lmt: self.lmt,
            xtag: self.xtag.clone().unwrap_or_default(),
        }
    }
}

#[derive(Clone, Debug)]
pub struct SabrClientInfo {
    pub client_name_id: i64,
    pub client_version: String,
    pub os_name: String,
    pub os_version: String,
}

impl SabrClientInfo {
    fn encode(&self) -> ProtoWriter {
        ProtoWriter::new()
            .varint(16, Some(self.client_name_id))
            .string(17, Some(&self.client_version))
            .string(
                18,
                (!self.os_name.is_empty()).then_some(self.os_name.as_str()),
            )
            .string(
                19,
                (!self.os_version.is_empty()).then_some(self.os_version.as_str()),
            )
    }
}

#[derive(Clone, Debug)]
pub struct SabrAudioSpec {
    pub video_id: String,
    pub sabr_url: String,
    pub ustreamer_config: Vec<u8>,
    pub po_token: Option<Vec<u8>>,
    pub cookie: Option<String>,
    pub origin: Option<String>,
    pub client_info: SabrClientInfo,
    pub user_agent: String,
    pub audio_formats: Vec<SabrAdaptiveFormat>,
    pub fallback_video: Option<SabrAdaptiveFormat>,
}

#[derive(Clone, Copy, Debug)]
enum ProtoValue<'a> {
    Varint(u64),
    Fixed64,
    Fixed32,
    Len(&'a [u8]),
}

#[derive(Clone, Debug, Default)]
struct ProtoMessage<'a> {
    fields: Vec<(u32, ProtoValue<'a>)>,
}

impl<'a> ProtoMessage<'a> {
    fn parse(mut bytes: &'a [u8]) -> Result<Self, String> {
        let mut fields = Vec::new();
        while !bytes.is_empty() {
            let tag = read_proto_varint(&mut bytes)?;
            let field = (tag >> 3) as u32;
            let value = match tag & 7 {
                0 => ProtoValue::Varint(read_proto_varint(&mut bytes)?),
                1 => {
                    let _ = take_slice(&mut bytes, 8)?;
                    ProtoValue::Fixed64
                }
                5 => {
                    let _ = take_slice(&mut bytes, 4)?;
                    ProtoValue::Fixed32
                }
                2 => {
                    let len = read_proto_varint(&mut bytes)?;
                    let len = usize::try_from(len).map_err(|_| "protobuf 길이 초과".to_owned())?;
                    ProtoValue::Len(take_slice(&mut bytes, len)?)
                }
                other => return Err(format!("지원하지 않는 protobuf wire type ({other})")),
            };
            fields.push((field, value));
        }
        Ok(Self { fields })
    }

    fn first(&self, field: u32) -> Option<ProtoValue<'a>> {
        self.fields
            .iter()
            .find(|(num, _)| *num == field)
            .map(|(_, val)| *val)
    }

    fn varint(&self, field: u32) -> Option<u64> {
        match self.first(field)? {
            ProtoValue::Varint(v) => Some(v),
            _ => None,
        }
    }

    fn repeated_varints(&self, field: u32) -> Vec<i64> {
        let mut out = Vec::new();
        for &(num, val) in &self.fields {
            if num != field {
                continue;
            }
            match val {
                ProtoValue::Varint(v) => out.push(v as i64),
                ProtoValue::Len(mut packed) => {
                    while !packed.is_empty() {
                        match read_proto_varint(&mut packed) {
                            Ok(v) => out.push(v as i64),
                            Err(_) => break,
                        }
                    }
                }
                _ => {}
            }
        }
        out
    }

    fn bytes(&self, field: u32) -> Option<&'a [u8]> {
        match self.first(field)? {
            ProtoValue::Len(b) => Some(b),
            _ => None,
        }
    }

    fn string(&self, field: u32) -> Option<String> {
        self.bytes(field)
            .and_then(|b| std::str::from_utf8(b).ok())
            .map(ToOwned::to_owned)
    }
}

fn take_slice<'a>(bytes: &mut &'a [u8], count: usize) -> Result<&'a [u8], String> {
    if bytes.len() < count {
        return Err("protobuf 메시지가 잘렸습니다.".into());
    }
    let (head, rest) = bytes.split_at(count);
    *bytes = rest;
    Ok(head)
}

fn read_proto_varint(bytes: &mut &[u8]) -> Result<u64, String> {
    let mut result = 0u64;
    let mut shift = 0u32;
    loop {
        let byte = take_slice(bytes, 1)?[0];
        result |= u64::from(byte & 0x7F) << shift;
        if byte & 0x80 == 0 {
            return Ok(result);
        }
        shift += 7;
        if shift >= 64 {
            return Err("protobuf varint가 64비트를 초과했습니다.".into());
        }
    }
}

#[derive(Clone, Debug, Default)]
struct ProtoWriter {
    buf: Vec<u8>,
}

impl ProtoWriter {
    fn new() -> Self {
        Self::default()
    }

    fn into_bytes(self) -> Vec<u8> {
        self.buf
    }

    fn write_varint(&mut self, mut value: u64) {
        while value >= 0x80 {
            self.buf.push((value as u8 & 0x7F) | 0x80);
            value >>= 7;
        }
        self.buf.push(value as u8);
    }

    fn tag(&mut self, field: u32, wire_type: u8) {
        self.write_varint((u64::from(field) << 3) | u64::from(wire_type));
    }

    fn varint(mut self, field: u32, value: Option<i64>) -> Self {
        if let Some(v) = value {
            self.tag(field, 0);
            self.write_varint(v as u64);
        }
        self
    }

    fn bytes(mut self, field: u32, value: Option<&[u8]>) -> Self {
        if let Some(b) = value {
            self.tag(field, 2);
            self.write_varint(b.len() as u64);
            self.buf.extend_from_slice(b);
        }
        self
    }

    fn string(self, field: u32, value: Option<&str>) -> Self {
        self.bytes(field, value.map(str::as_bytes))
    }

    fn message(self, field: u32, value: Option<ProtoWriter>) -> Self {
        match value {
            Some(child) => self.bytes(field, Some(&child.buf)),
            None => self,
        }
    }

    fn messages(self, field: u32, values: impl IntoIterator<Item = ProtoWriter>) -> Self {
        values
            .into_iter()
            .fold(self, |writer, child| writer.message(field, Some(child)))
    }
}

pub fn decode_base64_lenient(input: &str) -> Option<Vec<u8>> {
    fn decode_char(b: u8) -> Option<u8> {
        match b {
            b'A'..=b'Z' => Some(b - b'A'),
            b'a'..=b'z' => Some(b - b'a' + 26),
            b'0'..=b'9' => Some(b - b'0' + 52),
            b'+' | b'-' => Some(62),
            b'/' | b'_' => Some(63),
            _ => None,
        }
    }

    let cleaned: Vec<u8> = input
        .bytes()
        .filter(|b| !b.is_ascii_whitespace() && *b != b'=')
        .collect();
    if cleaned.len() % 4 == 1 {
        return None;
    }
    let mut out = Vec::with_capacity((cleaned.len() * 3) / 4);
    let mut chunks = cleaned.chunks_exact(4);
    for chunk in &mut chunks {
        let a = decode_char(chunk[0])?;
        let b = decode_char(chunk[1])?;
        let c = decode_char(chunk[2])?;
        let d = decode_char(chunk[3])?;
        out.push((a << 2) | (b >> 4));
        out.push((b << 4) | (c >> 2));
        out.push((c << 6) | d);
    }
    let rem = chunks.remainder();
    match rem.len() {
        0 => {}
        2 => {
            let a = decode_char(rem[0])?;
            let b = decode_char(rem[1])?;
            out.push((a << 2) | (b >> 4));
        }
        3 => {
            let a = decode_char(rem[0])?;
            let b = decode_char(rem[1])?;
            let c = decode_char(rem[2])?;
            out.push((a << 2) | (b >> 4));
            out.push((b << 4) | (c >> 2));
        }
        _ => return None,
    }
    Some(out)
}

fn ump_varint_size(prefix: u8) -> usize {
    match prefix {
        0x00..=0x7F => 1,
        0x80..=0xBF => 2,
        0xC0..=0xDF => 3,
        0xE0..=0xEF => 4,
        _ => 5,
    }
}

fn decode_ump_varint(bytes: &[u8]) -> u64 {
    let b = |idx: usize| u64::from(bytes[idx]);
    match bytes.len() {
        1 => b(0),
        2 => (b(0) & 0x3F) + 64 * b(1),
        3 => (b(0) & 0x1F) + 32 * (b(1) + 256 * b(2)),
        4 => (b(0) & 0x0F) + 16 * (b(1) + 256 * (b(2) + 256 * b(3))),
        _ => b(1) + 256 * (b(2) + 256 * (b(3) + 256 * b(4))),
    }
}

struct UmpStreamReader<R> {
    reader: R,
}

impl<R: Read> UmpStreamReader<R> {
    fn new(reader: R) -> Self {
        Self { reader }
    }

    fn read_varint_opt(&mut self) -> io::Result<Option<u64>> {
        let mut first = [0u8; 1];
        if self.reader.read(&mut first)? == 0 {
            return Ok(None);
        }
        let size = ump_varint_size(first[0]);
        let mut buf = [0u8; 5];
        buf[0] = first[0];
        if size > 1 {
            self.reader.read_exact(&mut buf[1..size])?;
        }
        Ok(Some(decode_ump_varint(&buf[..size])))
    }

    fn read_varint(&mut self) -> io::Result<u64> {
        self.read_varint_opt()?.ok_or_else(|| {
            io::Error::new(io::ErrorKind::UnexpectedEof, "UMP 스트림이 중단되었습니다.")
        })
    }

    fn next_part(&mut self) -> io::Result<Option<(u64, u64)>> {
        let Some(part_id) = self.read_varint_opt()? else {
            return Ok(None);
        };
        let size = self.read_varint()?;
        Ok(Some((part_id, size)))
    }

    fn read_byte(&mut self) -> io::Result<u8> {
        let mut b = [0u8; 1];
        self.reader.read_exact(&mut b)?;
        Ok(b[0])
    }

    fn read_exact_vec(&mut self, size: u64) -> io::Result<Vec<u8>> {
        let len = usize::try_from(size)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "UMP 파트 크기 초과"))?;
        let mut buf = vec![0u8; len];
        self.reader.read_exact(&mut buf)?;
        Ok(buf)
    }

    fn skip(&mut self, mut count: u64, scratch: &mut [u8]) -> io::Result<()> {
        while count > 0 {
            let step = (count as usize).min(scratch.len());
            let n = self.reader.read(&mut scratch[..step])?;
            if n == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "UMP 스킵 중 스트림이 끝났습니다.",
                ));
            }
            count -= n as u64;
        }
        Ok(())
    }
}

struct WebmElemHeader {
    id: u64,
    size: i64,
    unknown_size: bool,
    header_len: i64,
}

fn ebml_vint_len(first: u8) -> usize {
    (first.leading_zeros() as usize + 1).min(9)
}

fn parse_webm_header(head: &[u8]) -> Option<WebmElemHeader> {
    if head.len() < 2 {
        return None;
    }
    let id_len = ebml_vint_len(head[0]);
    if !(1..=4).contains(&id_len) || head.len() <= id_len {
        return None;
    }
    let id = head[..id_len]
        .iter()
        .fold(0u64, |acc, &b| (acc << 8) | u64::from(b));
    let first = head[id_len];
    let size_len = ebml_vint_len(first);
    if !(1..=8).contains(&size_len) || head.len() < id_len + size_len {
        return None;
    }
    let mask = 0xFFu32 >> size_len;
    let mut size = u64::from(u32::from(first) & mask);
    let mut all_ones = size == u64::from(mask);
    for &b in &head[id_len + 1..id_len + size_len] {
        if b != 0xFF {
            all_ones = false;
        }
        size = (size << 8) | u64::from(b);
    }
    Some(WebmElemHeader {
        id,
        size: size as i64,
        unknown_size: all_ones,
        header_len: (id_len + size_len) as i64,
    })
}

struct SegmentStructureCheck {
    length: i64,
    is_init: bool,
    next: i64,
    failed: bool,
    mp4: Option<bool>,
    cluster_end: i64,
    saw_moov: bool,
    saw_moof: bool,
    saw_mdat: bool,
}

impl SegmentStructureCheck {
    fn new(length: i64, is_init: bool) -> Self {
        Self {
            length,
            is_init,
            next: 0,
            failed: length <= 0,
            mp4: None,
            cluster_end: -1,
            saw_moov: false,
            saw_moof: false,
            saw_mdat: false,
        }
    }

    fn done(&self) -> bool {
        self.failed || self.next >= self.length
    }

    fn head_bytes(&self) -> usize {
        16i64.min(self.length - self.next).max(0) as usize
    }

    fn step(&mut self, head: &[u8]) {
        if self.done() {
            return;
        }
        let is_mp4 = *self.mp4.get_or_insert_with(|| {
            head.len() >= 8 && {
                let kind = u32::from_be_bytes([head[4], head[5], head[6], head[7]]);
                MP4_SHARED.contains(&kind)
                    || MP4_INIT_ONLY.contains(&kind)
                    || MP4_MEDIA_ONLY.contains(&kind)
            }
        });
        if is_mp4 {
            self.step_mp4(head);
        } else {
            self.step_webm(head);
        }
    }

    fn step_webm(&mut self, head: &[u8]) {
        let Some(header) = parse_webm_header(head) else {
            self.failed = true;
            return;
        };
        let header_end = self.next + header.header_len;
        let end = if header.unknown_size {
            i64::MAX
        } else {
            header_end.saturating_add(header.size)
        };
        if self.cluster_end != -1 {
            if CLUSTER_CHILDREN.contains(&header.id) {
                if header.unknown_size || end > self.cluster_end.min(self.length) {
                    self.failed = true;
                    return;
                }
                self.next = end;
                if self.next == self.cluster_end {
                    self.cluster_end = -1;
                }
                return;
            }
            if self.cluster_end != i64::MAX || !SEGMENT_CHILDREN.contains(&header.id) {
                self.failed = true;
                return;
            }
            self.cluster_end = -1;
        }
        if self.next == 0 && self.is_init && header.id != ID_EBML {
            self.failed = true;
        } else if header.id == ID_SEGMENT && self.is_init {
            self.next = header_end;
        } else if header.id == ID_CLUSTER && !self.is_init && header.unknown_size {
            self.next = header_end;
            self.cluster_end = i64::MAX;
        } else if header.unknown_size || end > self.length {
            self.failed = true;
        } else if header.id == ID_EBML && self.next == 0 && self.is_init {
            self.next = end;
        } else if header.id == ID_CLUSTER && !self.is_init {
            self.next = header_end;
            if self.next != end {
                self.cluster_end = end;
            }
        } else if SEGMENT_CHILDREN.contains(&header.id) && header.id != ID_CLUSTER {
            self.next = end;
        } else {
            self.failed = true;
        }
    }

    fn step_mp4(&mut self, head: &[u8]) {
        if head.len() < 8 {
            self.failed = true;
            return;
        }
        let size32 = i64::from(u32::from_be_bytes([head[0], head[1], head[2], head[3]]));
        let kind = u32::from_be_bytes([head[4], head[5], head[6], head[7]]);
        let size = match size32 {
            0 => self.length - self.next,
            1 => {
                if head.len() < 16 {
                    self.failed = true;
                    return;
                }
                i64::from_be_bytes([
                    head[8], head[9], head[10], head[11], head[12], head[13], head[14], head[15],
                ])
            }
            other => other,
        };
        if size < 8 || (size32 == 1 && size < 16) || size > (self.length - self.next) {
            self.failed = true;
            return;
        }
        let allowed = MP4_SHARED.contains(&kind)
            || if self.is_init {
                MP4_INIT_ONLY.contains(&kind)
            } else {
                MP4_MEDIA_ONLY.contains(&kind)
            };
        if !allowed || (self.next == 0 && self.is_init && kind != BOX_FTYP) {
            self.failed = true;
            return;
        }
        match kind {
            BOX_MOOV => self.saw_moov = true,
            BOX_MOOF => self.saw_moof = true,
            BOX_MDAT => self.saw_mdat = true,
            _ => {}
        }
        self.next += size;
    }

    fn is_valid(&self) -> bool {
        if self.failed || self.next != self.length {
            return false;
        }
        if self.mp4 == Some(true) {
            if self.is_init && !self.saw_moov {
                return false;
            }
            if !self.is_init && !(self.saw_moof && self.saw_mdat) {
                return false;
            }
        }
        true
    }
}

struct StreamingSegmentCheck {
    check: SegmentStructureCheck,
    length: i64,
    position: i64,
    head: Vec<u8>,
    head_at: i64,
}

impl StreamingSegmentCheck {
    fn new(length: i64, is_init: bool) -> Self {
        Self {
            check: SegmentStructureCheck::new(length, is_init),
            length,
            position: 0,
            head: Vec::with_capacity(16),
            head_at: 0,
        }
    }

    fn write(&mut self, bytes: &[u8]) {
        let count = bytes.len() as i64;
        let mut offset = 0i64;
        while offset < count && !self.check.done() {
            let at = self.position + offset;
            if self.head.is_empty() {
                if at < self.check.next {
                    offset += (self.check.next - at).min(count - offset);
                    continue;
                }
                self.head_at = at;
            }
            let take =
                (self.check.head_bytes() as i64 - self.head.len() as i64).min(count - offset);
            if take <= 0 {
                break;
            }
            self.head
                .extend_from_slice(&bytes[offset as usize..(offset + take) as usize]);
            offset += take;
            self.step_held();
        }
        self.position += count;
    }

    fn step_held(&mut self) {
        while !self.check.done() && !self.head.is_empty() {
            if self.check.next >= self.head_at + self.head.len() as i64 {
                self.head.clear();
                return;
            }
            if self.check.next > self.head_at {
                self.head.drain(..(self.check.next - self.head_at) as usize);
                self.head_at = self.check.next;
            }
            let need = self.check.head_bytes();
            if self.head.len() < need {
                return;
            }
            let window = self.head[..need].to_vec();
            self.check.step(&window);
        }
    }

    fn is_valid(&self) -> bool {
        self.position == self.length && self.check.is_valid()
    }
}

pub fn validate_mp4_file(path: &Path) -> bool {
    let Ok(mut file) = File::open(path) else {
        return false;
    };
    let Ok(len) = file.metadata().map(|m| m.len()) else {
        return false;
    };
    if len < 32 {
        return false;
    }
    let mut pos = 0u64;
    let mut saw_ftyp = false;
    let mut saw_moov = false;
    let mut hdr = [0u8; 16];
    for _ in 0..64 {
        if pos + 8 > len {
            break;
        }
        if file.seek(SeekFrom::Start(pos)).is_err() {
            return false;
        }
        let to_read = (len - pos).min(16) as usize;
        if file.read_exact(&mut hdr[..to_read]).is_err() {
            return false;
        }
        let size32 = u32::from_be_bytes([hdr[0], hdr[1], hdr[2], hdr[3]]) as u64;
        let kind = u32::from_be_bytes([hdr[4], hdr[5], hdr[6], hdr[7]]);
        let box_size = match size32 {
            0 => len - pos,
            1 if to_read >= 16 => u64::from_be_bytes([
                hdr[8], hdr[9], hdr[10], hdr[11], hdr[12], hdr[13], hdr[14], hdr[15],
            ]),
            1 => return false,
            other => other,
        };
        if box_size < 8 || pos.saturating_add(box_size) > len {
            return false;
        }
        if pos == 0 && kind != BOX_FTYP {
            return false;
        }
        if kind == BOX_FTYP {
            saw_ftyp = true;
        } else if kind == BOX_MOOV {
            saw_moov = true;
        }
        if saw_ftyp && saw_moov {
            return true;
        }
        pos = pos.saturating_add(box_size);
    }
    saw_ftyp && saw_moov
}

#[derive(Clone, Debug)]
struct MediaHeader {
    header_id: u8,
    itag: i32,
    lmt: i64,
    xtag: Option<String>,
    start_range: i64,
    is_init_segment: bool,
    segment_index: i64,
    start_ms: Option<i64>,
    duration_ms: Option<i64>,
    content_length: i64,
    data_offset: i64,
}

impl MediaHeader {
    fn parse(payload: &[u8]) -> Result<Self, String> {
        let msg = ProtoMessage::parse(payload)?;
        let header_id = msg.varint(1).ok_or("MEDIA_HEADER에 header_id 없음")? as u8;
        let itag = msg.varint(3).ok_or("MEDIA_HEADER에 itag 없음")? as i32;
        let is_init_segment = msg.varint(8) == Some(1);
        let time_range = msg.bytes(15).and_then(|b| ProtoMessage::parse(b).ok());
        let tr_timescale = time_range
            .as_ref()
            .and_then(|tr| tr.varint(3))
            .filter(|&ts| ts > 0);
        let tr_start_ms = match (&time_range, tr_timescale) {
            (Some(tr), Some(ts)) => {
                let ticks = tr.varint(1).unwrap_or(0);
                Some(((ticks as u128 * 1000) / ts as u128) as i64)
            }
            _ => None,
        };
        let tr_duration_ms = match (&time_range, tr_timescale) {
            (Some(tr), Some(ts)) => tr
                .varint(2)
                .map(|ticks| ((ticks as u128 * 1000) / ts as u128) as i64),
            _ => None,
        };
        let start_ms = msg
            .varint(11)
            .map(|v| v as i64)
            .or(tr_start_ms)
            .or((!is_init_segment).then_some(0));
        let duration_ms = msg.varint(12).map(|v| v as i64).or(tr_duration_ms);
        Ok(Self {
            header_id,
            itag,
            lmt: msg.varint(4).unwrap_or(0) as i64,
            xtag: msg.string(5),
            start_range: msg.varint(6).unwrap_or(0) as i64,
            is_init_segment,
            segment_index: msg.varint(9).unwrap_or(0) as i64,
            start_ms,
            duration_ms,
            content_length: msg.varint(14).unwrap_or(0) as i64,
            data_offset: msg.varint(17).unwrap_or(0) as i64,
        })
    }

    fn effective_length(&self, total_read: i64) -> i64 {
        if self.content_length > 0 {
            self.content_length
        } else {
            self.data_offset + total_read
        }
    }
}

#[derive(Default)]
pub(crate) struct SegmentIndex {
    segments: BTreeMap<i64, MediaHeader>,
}

impl SegmentIndex {
    fn last(&self) -> Option<MediaHeader> {
        self.segments
            .last_key_value()
            .map(|(_, header)| header.clone())
    }

    fn save(&mut self, header: &MediaHeader, actual_length: i64) {
        let mut stored = header.clone();
        if stored.content_length <= 0 && actual_length > 0 {
            stored.content_length = actual_length;
        }
        stored.data_offset = 0;
        self.segments.insert(stored.segment_index, stored);
    }

    fn find_by_byte_offset(&self, offset: i64) -> Option<MediaHeader> {
        if offset < 0 {
            return None;
        }
        self.segments
            .values()
            .rev()
            .find(|seg| {
                seg.content_length > 0
                    && offset >= seg.start_range
                    && offset < seg.start_range.saturating_add(seg.content_length)
            })
            .cloned()
    }
}

struct PartState {
    header: MediaHeader,
    total_read: i64,
    writing: bool,
    beyond_file_end: bool,
    relevant: bool,
    checker: Option<StreamingSegmentCheck>,
}

struct SabrContextUpdate {
    context_type: i64,
    value: Vec<u8>,
}

impl SabrContextUpdate {
    fn encode(&self) -> ProtoWriter {
        ProtoWriter::new()
            .varint(1, Some(self.context_type))
            .bytes(2, Some(&self.value))
    }
}

struct RoundOutcome {
    completed_segments: u32,
    redirect: Option<String>,
    backoff_ms: u64,
    protection_status: Option<u64>,
    reseeded_cursor: bool,
}

fn set_query_param(url: &str, key: &str, value: &str) -> String {
    let encoded = format!("{key}={value}");
    let Some((prefix, query)) = url.split_once('?') else {
        return format!("{url}?{encoded}");
    };
    let mut kept: Vec<&str> = query
        .split('&')
        .filter(|pair| !pair.is_empty() && pair.split('=').next() != Some(key))
        .collect();
    kept.push(&encoded);
    format!("{prefix}?{}", kept.join("&"))
}

fn ensure_https(url: &str) -> String {
    if let Some(rest) = url.strip_prefix("http://") {
        format!("https://{rest}")
    } else {
        url.to_owned()
    }
}

fn generate_cpn() -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut seed = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0x9E37_79B9_7F4A_7C15);
    seed ^= (&seed as *const u64 as u64).rotate_left(17);
    let mut out = String::with_capacity(16);
    for _ in 0..16 {
        seed = seed
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        let idx = ((seed >> 33) as usize) % ALPHABET.len();
        out.push(ALPHABET[idx] as char);
    }
    out
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

fn build_abr_request(
    spec: &SabrAudioSpec,
    audio: &SabrAdaptiveFormat,
    audio_segment: Option<&MediaHeader>,
    playback_cookie: &[u8],
    contexts: &BTreeMap<i64, SabrContextUpdate>,
    active_contexts: &BTreeSet<i64>,
    elapsed_ms: i64,
    rn: u32,
) -> Vec<u8> {
    let player_time_ms = match audio_segment {
        Some(h) if !h.is_init_segment => h.start_ms.unwrap_or(0) + h.duration_ms.unwrap_or(0),
        _ => 0,
    };
    let time_since_last_seek = ((rn as i64 % 45) + 5).max(1);
    let client_abr_state = ProtoWriter::new()
        .varint(28, Some(player_time_ms))
        .varint(40, Some(1))
        .varint(46, audio.is_drc.then_some(1))
        .string(69, audio.audio_track_id.as_deref())
        .varint(18, Some(VIEWPORT_WIDTH))
        .varint(19, Some(VIEWPORT_HEIGHT))
        .varint(29, Some(time_since_last_seek))
        .varint(34, Some(0))
        .varint(36, Some(elapsed_ms))
        .varint(39, Some((time_since_last_seek / 2).max(0)));

    let selected_formats = if audio_segment.is_some() {
        vec![audio.format_id().encode()]
    } else {
        Vec::new()
    };

    let mut buffered_ranges = Vec::new();
    if let Some(h) = audio_segment.filter(|h| !h.is_init_segment)
        && let (Some(start_ms), Some(duration_ms)) = (h.start_ms, h.duration_ms)
    {
        let format_id = FormatId {
            itag: h.itag,
            lmt: h.lmt,
            xtag: h.xtag.clone().unwrap_or_default(),
        };
        buffered_ranges.push(
            ProtoWriter::new()
                .message(1, Some(format_id.encode()))
                .varint(2, Some(0))
                .varint(3, Some(start_ms + duration_ms))
                .varint(4, Some(1))
                .varint(5, Some(h.segment_index)),
        );
    }

    let selected_audio = vec![audio.format_id().encode()];
    let selected_video: Vec<ProtoWriter> = spec
        .fallback_video
        .as_ref()
        .map(|v| v.format_id().encode())
        .into_iter()
        .collect();

    let encoded_contexts = contexts
        .iter()
        .filter(|(ctx_type, _)| active_contexts.contains(ctx_type))
        .map(|(_, update)| update.encode());

    let streamer_context = ProtoWriter::new()
        .message(1, Some(spec.client_info.encode()))
        .bytes(2, spec.po_token.as_deref())
        .bytes(3, Some(playback_cookie))
        .messages(5, encoded_contexts);

    ProtoWriter::new()
        .message(1, Some(client_abr_state))
        .messages(2, selected_formats)
        .messages(3, buffered_ranges)
        .bytes(5, Some(&spec.ustreamer_config))
        .messages(16, selected_audio)
        .messages(17, selected_video)
        .message(19, Some(streamer_context))
        .into_bytes()
}

#[allow(clippy::too_many_arguments)]
fn process_ump_response<R: Read, F: FnMut(u64, u64)>(
    reader: R,
    target_format: &FormatId,
    expected_total: u64,
    file: &mut File,
    file_len: &mut u64,
    audio_segment: &mut Option<MediaHeader>,
    segment_index: &mut SegmentIndex,
    playback_cookie: &mut Vec<u8>,
    contexts: &mut BTreeMap<i64, SabrContextUpdate>,
    active_contexts: &mut BTreeSet<i64>,
    po_token_valid: &mut bool,
    cancel: &AtomicBool,
    on_progress: &mut F,
) -> Result<RoundOutcome, SabrError> {
    let mut ump = UmpStreamReader::new(reader);
    let mut open: HashMap<u8, PartState> = HashMap::new();
    let mut scratch = [0u8; 64 * 1024];
    let mut outcome = RoundOutcome {
        completed_segments: 0,
        redirect: None,
        backoff_ms: 0,
        protection_status: None,
        reseeded_cursor: false,
    };

    while let Some((part_id, size)) = ump.next_part().map_err(|_| {
        SabrError::new(
            SabrErrorKind::Retryable,
            "SABR 응답 수신 중 연결이 끊겼습니다.",
        )
    })? {
        if cancel.load(Ordering::Relaxed) {
            return Err(SabrError::new(
                SabrErrorKind::Cancelled,
                "다운로드가 취소되었습니다.",
            ));
        }
        match part_id {
            ump_part::SABR_ERROR => {
                let payload = ump.read_exact_vec(size).map_err(|_| {
                    SabrError::new(SabrErrorKind::Retryable, "SABR 오류 응답 수신 실패")
                })?;
                let detail = ProtoMessage::parse(&payload)
                    .ok()
                    .and_then(|m| m.string(1))
                    .unwrap_or_else(|| "서버 오류".into());
                return Err(SabrError::new(
                    SabrErrorKind::Retryable,
                    format!("SABR 서버 오류: {detail}"),
                ));
            }
            ump_part::SABR_REDIRECT => {
                let payload = ump.read_exact_vec(size).map_err(|_| {
                    SabrError::new(SabrErrorKind::Retryable, "SABR 리다이렉트 수신 실패")
                })?;
                if let Some(redirect) = ProtoMessage::parse(&payload).ok().and_then(|m| m.string(1))
                    && redirect.contains("/videoplayback")
                {
                    outcome.redirect = Some(ensure_https(&redirect));
                    break;
                }
            }
            ump_part::MEDIA_HEADER => {
                let payload = ump.read_exact_vec(size).map_err(|_| {
                    SabrError::new(SabrErrorKind::Retryable, "SABR 미디어 헤더 수신 실패")
                })?;
                let header = MediaHeader::parse(&payload)
                    .map_err(|e| SabrError::new(SabrErrorKind::Retryable, e))?;
                let relevant =
                    target_format.matches(header.itag, header.lmt, header.xtag.as_deref());
                let checker = (relevant && header.content_length > 0 && header.data_offset == 0)
                    .then(|| {
                        StreamingSegmentCheck::new(header.content_length, header.is_init_segment)
                    });
                open.insert(
                    header.header_id,
                    PartState {
                        header,
                        total_read: 0,
                        writing: false,
                        beyond_file_end: false,
                        relevant,
                        checker,
                    },
                );
            }
            ump_part::MEDIA_DATA => {
                if size == 0 {
                    continue;
                }
                let header_id = ump.read_byte().map_err(|_| {
                    SabrError::new(SabrErrorKind::Retryable, "SABR 데이터 헤더 수신 실패")
                })?;
                let mut remaining = size.saturating_sub(1);
                let Some(state) = open.get_mut(&header_id) else {
                    ump.skip(remaining, &mut scratch).map_err(|_| {
                        SabrError::new(SabrErrorKind::Retryable, "SABR 데이터 스킵 실패")
                    })?;
                    continue;
                };
                if !state.relevant || state.beyond_file_end {
                    ump.skip(remaining, &mut scratch).map_err(|_| {
                        SabrError::new(SabrErrorKind::Retryable, "SABR 데이터 스킵 실패")
                    })?;
                    state.total_read += remaining as i64;
                    continue;
                }
                let data_size = remaining;
                if !state.writing {
                    let file_end = *file_len as i64;
                    let part_start =
                        state.header.start_range + state.header.data_offset + state.total_read;
                    let part_end = part_start + remaining as i64;
                    if !(part_start..part_end).contains(&file_end) {
                        if file_end < part_start && !state.beyond_file_end {
                            state.beyond_file_end = true;
                            *audio_segment = if *file_len > 0 {
                                segment_index.find_by_byte_offset((*file_len as i64) - 1)
                            } else {
                                None
                            };
                            outcome.reseeded_cursor = true;
                        }
                        ump.skip(remaining, &mut scratch).map_err(|_| {
                            SabrError::new(SabrErrorKind::Retryable, "SABR 중복 구간 스킵 실패")
                        })?;
                        state.total_read += data_size as i64;
                        continue;
                    }
                    let skip = (file_end - part_start) as u64;
                    if skip > 0 {
                        state.checker = None;
                        ump.skip(skip, &mut scratch).map_err(|_| {
                            SabrError::new(SabrErrorKind::Retryable, "SABR 이어받기 구간 스킵 실패")
                        })?;
                        remaining -= skip;
                    }
                    state.writing = true;
                }
                while remaining > 0 {
                    if cancel.load(Ordering::Relaxed) {
                        return Err(SabrError::new(
                            SabrErrorKind::Cancelled,
                            "다운로드가 취소되었습니다.",
                        ));
                    }
                    let step = (remaining as usize).min(scratch.len());
                    let n = ump.reader.read(&mut scratch[..step]).map_err(|_| {
                        SabrError::new(
                            SabrErrorKind::Retryable,
                            "SABR 음원 수신 중 연결이 끊겼습니다.",
                        )
                    })?;
                    if n == 0 {
                        return Err(SabrError::new(
                            SabrErrorKind::Retryable,
                            "SABR 음원 스트림이 예기치 않게 종료되었습니다.",
                        ));
                    }
                    if let Some(checker) = state.checker.as_mut() {
                        checker.write(&scratch[..n]);
                    }
                    file.write_all(&scratch[..n]).map_err(|_| {
                        SabrError::new(SabrErrorKind::Fatal, "음원 파일 쓰기에 실패했습니다.")
                    })?;
                    *file_len = file_len.saturating_add(n as u64);
                    remaining -= n as u64;
                    on_progress(*file_len, expected_total);
                }
                state.total_read += data_size as i64;
            }
            ump_part::MEDIA_END => {
                if size == 0 {
                    continue;
                }
                let header_id = ump.read_byte().map_err(|_| {
                    SabrError::new(SabrErrorKind::Retryable, "SABR 종료 헤더 수신 실패")
                })?;
                if size > 1 {
                    ump.skip(size - 1, &mut scratch).map_err(|_| {
                        SabrError::new(SabrErrorKind::Retryable, "SABR 종료 패딩 스킵 실패")
                    })?;
                }
                if let Some(state) = open.remove(&header_id)
                    && state.relevant
                {
                    let length = state.header.effective_length(state.total_read);
                    let structure_ok = !state.writing
                        || state.beyond_file_end
                        || state
                            .checker
                            .as_ref()
                            .is_none_or(StreamingSegmentCheck::is_valid);
                    if !structure_ok {
                        return Err(SabrError::new(
                            SabrErrorKind::Retryable,
                            "SABR 오디오 세그먼트 구조 검증에 실패했습니다.",
                        ));
                    }
                    let reached_end = state.writing
                        && length > 0
                        && state.header.start_range.checked_add(length) == Some(*file_len as i64);
                    let expected_seq = audio_segment
                        .as_ref()
                        .map_or(0, |seg| seg.segment_index + 1);
                    if reached_end && state.header.segment_index == expected_seq {
                        segment_index.save(&state.header, length);
                        *audio_segment = segment_index.last();
                        outcome.completed_segments += 1;
                    }
                }
            }
            ump_part::NEXT_REQUEST_POLICY => {
                let payload = ump.read_exact_vec(size).map_err(|_| {
                    SabrError::new(SabrErrorKind::Retryable, "SABR 정책 파트 수신 실패")
                })?;
                if let Ok(msg) = ProtoMessage::parse(&payload) {
                    if let Some(cookie) = msg.bytes(7) {
                        *playback_cookie = cookie.to_vec();
                    }
                    outcome.backoff_ms = msg.varint(4).unwrap_or(0);
                }
            }
            ump_part::STREAM_PROTECTION_STATUS => {
                let payload = ump.read_exact_vec(size).map_err(|_| {
                    SabrError::new(SabrErrorKind::Retryable, "SABR 보호 상태 수신 실패")
                })?;
                if let Ok(msg) = ProtoMessage::parse(&payload) {
                    let status = msg.varint(1);
                    outcome.protection_status = status;
                    if let Some(s) = status.filter(|&v| v != 2) {
                        *po_token_valid = s != 3;
                    }
                }
            }
            ump_part::SABR_CONTEXT_UPDATE => {
                let payload = ump.read_exact_vec(size).map_err(|_| {
                    SabrError::new(SabrErrorKind::Retryable, "SABR 컨텍스트 수신 실패")
                })?;
                if let Ok(msg) = ProtoMessage::parse(&payload)
                    && let (Some(ctx_type), Some(val)) = (msg.varint(1), msg.bytes(3))
                {
                    let key = ctx_type as i64;
                    let send_by_default = msg.varint(5).unwrap_or(1) != 0;
                    contexts.insert(
                        key,
                        SabrContextUpdate {
                            context_type: key,
                            value: val.to_vec(),
                        },
                    );
                    if send_by_default {
                        active_contexts.insert(key);
                    }
                }
            }
            ump_part::SABR_CONTEXT_SENDING_POLICY => {
                let payload = ump.read_exact_vec(size).map_err(|_| {
                    SabrError::new(SabrErrorKind::Retryable, "SABR 컨텍스트 정책 수신 실패")
                })?;
                if let Ok(msg) = ProtoMessage::parse(&payload) {
                    for ctx in msg.repeated_varints(1) {
                        active_contexts.insert(ctx);
                    }
                    for ctx in msg.repeated_varints(2) {
                        active_contexts.remove(&ctx);
                    }
                    for ctx in msg.repeated_varints(3) {
                        active_contexts.remove(&ctx);
                        contexts.remove(&ctx);
                    }
                }
            }
            _ => {
                ump.skip(size, &mut scratch).map_err(|_| {
                    SabrError::new(SabrErrorKind::Retryable, "SABR 기타 파트 스킵 실패")
                })?;
            }
        }
    }

    Ok(outcome)
}

fn restore_checkpoint(
    file: &mut File,
    file_len: &mut u64,
    expected_total: u64,
    index: &mut SegmentIndex,
) -> Result<Option<MediaHeader>, SabrError> {
    let checkpoint = index.last();
    let committed = checkpoint.as_ref().map_or(0, |header| {
        header.start_range.saturating_add(header.content_length) as u64
    });
    let committed = if committed <= *file_len && committed <= expected_total {
        committed
    } else {
        index.segments.clear();
        0
    };
    if *file_len != committed {
        file.set_len(committed).map_err(|_| {
            SabrError::new(SabrErrorKind::Fatal, "임시 파일을 복구하지 못했습니다.")
        })?;
        *file_len = committed;
    }
    file.seek(SeekFrom::Start(committed)).map_err(|_| {
        SabrError::new(
            SabrErrorKind::Fatal,
            "임시 파일에서 이어받을 위치로 이동하지 못했습니다.",
        )
    })?;
    Ok(index.last())
}

pub fn download_sabr_audio<F: FnMut(u64, u64)>(
    client: &Client,
    spec: &SabrAudioSpec,
    audio: &SabrAdaptiveFormat,
    part_path: &Path,
    cancel: &AtomicBool,
    on_progress: F,
) -> Result<u64, SabrError> {
    resume_sabr_audio(
        client,
        spec,
        audio,
        part_path,
        &mut SegmentIndex::default(),
        cancel,
        on_progress,
    )
}

pub(crate) fn resume_sabr_audio<F: FnMut(u64, u64)>(
    client: &Client,
    spec: &SabrAudioSpec,
    audio: &SabrAdaptiveFormat,
    part_path: &Path,
    segment_index: &mut SegmentIndex,
    cancel: &AtomicBool,
    mut on_progress: F,
) -> Result<u64, SabrError> {
    if audio.content_length == 0 {
        return Err(SabrError::new(
            SabrErrorKind::Retryable,
            "오디오 크기를 알 수 없는 스트림입니다.",
        ));
    }
    let mut file = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(part_path)
        .map_err(|_| SabrError::new(SabrErrorKind::Fatal, "임시 파일을 만들지 못했습니다."))?;
    let mut file_len = file
        .metadata()
        .map_err(|_| SabrError::new(SabrErrorKind::Fatal, "임시 파일 정보를 읽지 못했습니다."))?
        .len();
    let target_id = audio.format_id();
    let expected_total = audio.content_length;
    let mut audio_segment =
        restore_checkpoint(&mut file, &mut file_len, expected_total, segment_index)?;
    on_progress(file_len, expected_total);
    if file_len >= expected_total {
        return Ok(file_len);
    }

    let cpn = generate_cpn();
    let started = Instant::now();
    let mut url = set_query_param(&spec.sabr_url, "alr", "yes");
    let mut rn = 0u32;
    let mut playback_cookie: Vec<u8> = Vec::new();
    let mut contexts: BTreeMap<i64, SabrContextUpdate> = BTreeMap::new();
    let mut active_contexts: BTreeSet<i64> = BTreeSet::new();
    let mut po_token_valid = true;
    let mut empty_rounds = 0u32;
    let mut transient_retries = 0u32;
    let mut last_protection: Option<u64> = None;
    let mut last_error = "SABR 세그먼트를 수신하지 못했습니다.".to_owned();

    for _ in 0..MAX_TOTAL_ROUNDS {
        if cancel.load(Ordering::Relaxed) {
            return Err(SabrError::new(
                SabrErrorKind::Cancelled,
                "다운로드가 취소되었습니다.",
            ));
        }
        if file_len >= expected_total {
            break;
        }
        if empty_rounds > MAX_CONSECUTIVE_EMPTY_ROUNDS {
            if !po_token_valid {
                return Err(SabrError::new(
                    SabrErrorKind::PoTokenInvalid,
                    "스트림 보호(PO 토큰) 검증으로 거부되었습니다.",
                ));
            }
            if last_protection == Some(2) {
                return Err(SabrError::new(
                    SabrErrorKind::AttestationPending,
                    "YouTube 스트림 보호(PO 토큰) 검증 대기로 다운로드가 중단되었습니다.",
                ));
            }
            return Err(SabrError::new(SabrErrorKind::Retryable, last_error));
        }

        rn += 1;
        let body = build_abr_request(
            spec,
            audio,
            audio_segment.as_ref(),
            &playback_cookie,
            &contexts,
            &active_contexts,
            started.elapsed().as_millis() as i64,
            rn,
        );
        let request_url =
            set_query_param(&set_query_param(&url, "cpn", &cpn), "rn", &rn.to_string());
        let mut req = client
            .post(&request_url)
            .header("User-Agent", &spec.user_agent)
            .header("Content-Type", "application/x-protobuf");
        if let Some(cookie) = spec.cookie.as_deref().filter(|s| !s.is_empty()) {
            req = req.header("Cookie", cookie);
        }
        if let Some(origin) = spec.origin.as_deref().filter(|s| !s.is_empty()) {
            req = req
                .header("Origin", origin)
                .header("Referer", format!("{origin}/"));
        }

        let response = match req.body(body).send() {
            Ok(resp) => resp,
            Err(_) => {
                transient_retries += 1;
                if transient_retries > MAX_TRANSIENT_ROUND_RETRIES {
                    return Err(SabrError::new(
                        SabrErrorKind::Retryable,
                        "SABR 서버에 연결하지 못했습니다.",
                    ));
                }
                let wait_ms = TRANSIENT_RETRY_BACKOFF_MS
                    .get((transient_retries - 1) as usize)
                    .copied()
                    .unwrap_or(4000);
                if !sleep_cancelable(wait_ms, cancel) {
                    return Err(SabrError::new(
                        SabrErrorKind::Cancelled,
                        "다운로드가 취소되었습니다.",
                    ));
                }
                continue;
            }
        };
        let status = response.status();
        if status.is_redirection() {
            if let Some(loc) = response
                .headers()
                .get(reqwest::header::LOCATION)
                .and_then(|v| v.to_str().ok())
                && loc.contains("/videoplayback")
            {
                url = ensure_https(loc);
                continue;
            }
            return Err(SabrError::new(
                SabrErrorKind::Retryable,
                "유효하지 않은 SABR 리다이렉트입니다.",
            ));
        }
        if status.is_server_error() || status == reqwest::StatusCode::TOO_MANY_REQUESTS {
            transient_retries += 1;
            if transient_retries > MAX_TRANSIENT_ROUND_RETRIES {
                return Err(SabrError::new(
                    SabrErrorKind::Retryable,
                    format!("SABR 음원 다운로드 오류 ({status})"),
                ));
            }
            let wait_ms = TRANSIENT_RETRY_BACKOFF_MS
                .get((transient_retries - 1) as usize)
                .copied()
                .unwrap_or(4000);
            if !sleep_cancelable(wait_ms, cancel) {
                return Err(SabrError::new(
                    SabrErrorKind::Cancelled,
                    "다운로드가 취소되었습니다.",
                ));
            }
            continue;
        }
        if !status.is_success() {
            return Err(SabrError::new(
                SabrErrorKind::Retryable,
                format!("SABR 음원 다운로드 오류 ({status})"),
            ));
        }

        let outcome = process_ump_response(
            response,
            &target_id,
            expected_total,
            &mut file,
            &mut file_len,
            &mut audio_segment,
            segment_index,
            &mut playback_cookie,
            &mut contexts,
            &mut active_contexts,
            &mut po_token_valid,
            cancel,
            &mut on_progress,
        );
        let received_len = file_len;
        audio_segment =
            restore_checkpoint(&mut file, &mut file_len, expected_total, segment_index)?;
        if received_len != file_len {
            on_progress(file_len, expected_total);
        }
        let outcome = match outcome {
            Ok(o) => {
                transient_retries = 0;
                o
            }
            Err(err) if err.kind == SabrErrorKind::Retryable => {
                transient_retries += 1;
                if transient_retries > MAX_TRANSIENT_ROUND_RETRIES {
                    return Err(err);
                }
                let wait_ms = TRANSIENT_RETRY_BACKOFF_MS
                    .get((transient_retries - 1) as usize)
                    .copied()
                    .unwrap_or(4000);
                if !sleep_cancelable(wait_ms, cancel) {
                    return Err(SabrError::new(
                        SabrErrorKind::Cancelled,
                        "다운로드가 취소되었습니다.",
                    ));
                }
                continue;
            }
            Err(err) => return Err(err),
        };
        if let Some(redirect) = outcome.redirect {
            url = redirect;
            continue;
        }
        if file_len >= expected_total {
            break;
        }
        if outcome.protection_status == Some(3) {
            return Err(SabrError::new(
                SabrErrorKind::PoTokenInvalid,
                "스트림 보호(PO 토큰) 검증으로 거부되었습니다.",
            ));
        }
        if outcome.completed_segments == 0 {
            empty_rounds += 1;
            last_protection = outcome.protection_status;
            last_error = if outcome.protection_status == Some(2) {
                "YouTube 스트림 보호(PO 토큰) 검증 대기로 세그먼트가 전달되지 않았습니다.".into()
            } else if outcome.reseeded_cursor {
                "SABR 응답이 다음 오디오 세그먼트를 건너뛰었습니다.".into()
            } else {
                "SABR 응답에 오디오 세그먼트가 없습니다.".into()
            };
            let wait_ms = outcome.backoff_ms.max(MIN_EMPTY_ROUND_BACKOFF_MS);
            if !sleep_cancelable(wait_ms, cancel) {
                return Err(SabrError::new(
                    SabrErrorKind::Cancelled,
                    "다운로드가 취소되었습니다.",
                ));
            }
        } else {
            empty_rounds = 0;
        }
    }

    file.flush().map_err(|_| {
        SabrError::new(
            SabrErrorKind::Fatal,
            "음원 파일 저장을 완료하지 못했습니다.",
        )
    })?;
    if file_len < expected_total {
        return Err(SabrError::new(
            SabrErrorKind::Retryable,
            "SABR 음원 다운로드가 완료되지 않았습니다.",
        ));
    }
    Ok(file_len)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_ump_varint(out: &mut Vec<u8>, value: u32) {
        let v = u64::from(value);
        match v {
            0..0x80 => out.push(value as u8),
            0x80..0x4000 => {
                out.extend_from_slice(&[(value as u8 & 0x3F) | 0x80, (value >> 6) as u8])
            }
            _ => {
                out.push(0xF0);
                out.extend_from_slice(&value.to_le_bytes());
            }
        }
    }

    fn write_ump_part(out: &mut Vec<u8>, part_id: u32, payload: &[u8]) {
        write_ump_varint(out, part_id);
        write_ump_varint(out, payload.len() as u32);
        out.extend_from_slice(payload);
    }

    fn mp4_box(kind: &[u8; 4], payload: &[u8]) -> Vec<u8> {
        let mut out = Vec::with_capacity(8 + payload.len());
        out.extend_from_slice(&((8 + payload.len()) as u32).to_be_bytes());
        out.extend_from_slice(kind);
        out.extend_from_slice(payload);
        out
    }

    #[test]
    fn decodes_standard_and_urlsafe_base64_leniently() {
        assert_eq!(
            decode_base64_lenient("SGVsbG8=").as_deref(),
            Some(b"Hello".as_slice())
        );
        assert_eq!(
            decode_base64_lenient("SGVsbG8").as_deref(),
            Some(b"Hello".as_slice())
        );
        assert_eq!(
            decode_base64_lenient("_-_9").as_deref(),
            Some([0xFF, 0xEF, 0xFD].as_slice())
        );
    }

    #[test]
    fn resumes_fmp4_after_a_response_ends_mid_segment() {
        let mut init_bytes = mp4_box(b"ftyp", b"dash\0\0\0\0");
        init_bytes.extend(mp4_box(b"moov", b"mvhd1234"));
        let mut seg1_bytes = mp4_box(b"moof", b"mfhd");
        seg1_bytes.extend(mp4_box(b"mdat", b"audio1234"));

        let mut stream = Vec::new();
        let init_header = ProtoWriter::new()
            .varint(1, Some(1))
            .varint(3, Some(140))
            .varint(4, Some(999))
            .varint(6, Some(0))
            .varint(8, Some(1))
            .varint(14, Some(init_bytes.len() as i64))
            .into_bytes();
        write_ump_part(&mut stream, 20, &init_header);
        let mut data1 = vec![1u8];
        data1.extend_from_slice(&init_bytes);
        write_ump_part(&mut stream, 21, &data1);
        write_ump_part(&mut stream, 22, &[1u8]);
        let resume_offset = stream.len();

        let ctx_update = ProtoWriter::new()
            .varint(1, Some(7))
            .bytes(3, Some(b"ctx-val"))
            .varint(5, Some(1))
            .into_bytes();
        write_ump_part(&mut stream, 57, &ctx_update);

        let seg1_header = ProtoWriter::new()
            .varint(1, Some(2))
            .varint(3, Some(140))
            .varint(4, Some(999))
            .varint(6, Some(init_bytes.len() as i64))
            .varint(8, Some(0))
            .varint(9, Some(1))
            .varint(11, Some(0))
            .varint(12, Some(10_000))
            .varint(14, Some(seg1_bytes.len() as i64))
            .into_bytes();
        write_ump_part(&mut stream, 20, &seg1_header);
        let mut data2 = vec![2u8];
        data2.extend_from_slice(&seg1_bytes);
        write_ump_part(&mut stream, 21, &data2);
        let disconnect_offset = stream.len() - 4;
        write_ump_part(&mut stream, 22, &[2u8]);

        let stop_policy = ProtoWriter::new().varint(2, Some(7)).into_bytes();
        write_ump_part(&mut stream, 59, &stop_policy);

        let total_len = (init_bytes.len() + seg1_bytes.len()) as u64;
        let temp = std::env::temp_dir().join(format!("rm_sabr_test_{}.part", std::process::id()));
        let mut file = OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .open(&temp)
            .unwrap();
        let mut file_len = 0u64;
        let mut cursor = None;
        let mut index = SegmentIndex::default();
        let mut cookie = Vec::new();
        let mut contexts = BTreeMap::new();
        let mut active_contexts = BTreeSet::new();
        let mut po_valid = true;
        let cancel = AtomicBool::new(false);
        let target = FormatId {
            itag: 140,
            lmt: 999,
            xtag: String::new(),
        };
        let mut last_progress = (0u64, 0u64);
        let interrupted = process_ump_response(
            &stream[..disconnect_offset],
            &target,
            total_len,
            &mut file,
            &mut file_len,
            &mut cursor,
            &mut index,
            &mut cookie,
            &mut contexts,
            &mut active_contexts,
            &mut po_valid,
            &cancel,
            &mut |_, _| {},
        );
        assert_eq!(interrupted.err().unwrap().kind, SabrErrorKind::Retryable);
        assert!(file_len > init_bytes.len() as u64);
        drop(file);

        let mut file = OpenOptions::new().write(true).open(&temp).unwrap();
        file_len = file.metadata().unwrap().len();
        cursor = restore_checkpoint(&mut file, &mut file_len, total_len, &mut index).unwrap();
        assert_eq!(cursor.as_ref().unwrap().segment_index, 0);
        assert_eq!(file_len, init_bytes.len() as u64);
        assert_eq!(std::fs::read(&temp).unwrap(), init_bytes);
        contexts.clear();
        active_contexts.clear();
        let outcome = process_ump_response(
            &stream[resume_offset..],
            &target,
            total_len,
            &mut file,
            &mut file_len,
            &mut cursor,
            &mut index,
            &mut cookie,
            &mut contexts,
            &mut active_contexts,
            &mut po_valid,
            &cancel,
            &mut |done, total| last_progress = (done, total),
        )
        .unwrap();
        drop(file);

        assert_eq!(outcome.completed_segments, 1);
        assert_eq!(file_len, total_len);
        assert_eq!(last_progress, (total_len, total_len));
        assert_eq!(cursor.as_ref().unwrap().segment_index, 1);
        assert!(contexts.contains_key(&7));
        assert!(!active_contexts.contains(&7));
        assert!(validate_mp4_file(&temp));
        assert_eq!(
            std::fs::read(&temp).unwrap(),
            [init_bytes, seg1_bytes].concat()
        );
        let _ = std::fs::remove_file(&temp);
    }

    #[test]
    fn encodes_po_token_and_active_sabr_contexts_in_abr_request() {
        let format = SabrAdaptiveFormat {
            itag: 251,
            lmt: 12345,
            xtag: Some("acont=original".into()),
            mime_type: "audio/webm; codecs=\"opus\"".into(),
            extension: "webm".into(),
            content_length: 1_000_000,
            bitrate: 160_000,
            approx_duration_ms: 180_000,
            audio_track_is_default: Some(true),
            audio_track_id: Some("en.4".into()),
            is_drc: false,
            is_vb: false,
        };
        let spec = SabrAudioSpec {
            video_id: "dQw4w9WgXcQ".into(),
            sabr_url: "https://example.com/videoplayback".into(),
            ustreamer_config: vec![1, 2, 3],
            po_token: Some(b"po-token-bytes".to_vec()),
            cookie: None,
            origin: Some("https://www.youtube.com".into()),
            client_info: SabrClientInfo {
                client_name_id: 1,
                client_version: "2.20261020.01.00".into(),
                os_name: "Windows".into(),
                os_version: "10.0".into(),
            },
            user_agent: "UA".into(),
            audio_formats: vec![format.clone()],
            fallback_video: None,
        };
        let mut contexts = BTreeMap::new();
        contexts.insert(
            1,
            SabrContextUpdate {
                context_type: 1,
                value: b"active".to_vec(),
            },
        );
        contexts.insert(
            2,
            SabrContextUpdate {
                context_type: 2,
                value: b"stopped".to_vec(),
            },
        );
        let mut active = BTreeSet::new();
        active.insert(1);

        let body = build_abr_request(&spec, &format, None, b"cookie", &contexts, &active, 50, 1);
        let parsed = ProtoMessage::parse(&body).unwrap();
        let streamer = ProtoMessage::parse(parsed.bytes(19).unwrap()).unwrap();
        assert_eq!(streamer.bytes(2), Some(b"po-token-bytes".as_slice()));
        assert_eq!(streamer.bytes(3), Some(b"cookie".as_slice()));
        let ctx_entries: Vec<&[u8]> = streamer
            .fields
            .iter()
            .filter_map(|&(f, v)| match (f, v) {
                (5, ProtoValue::Len(b)) => Some(b),
                _ => None,
            })
            .collect();
        assert_eq!(ctx_entries.len(), 1);
    }

    #[test]
    fn reseeds_cursor_when_segment_arrives_beyond_file_end() {
        let mut init_bytes = mp4_box(b"ftyp", b"dash\0\0\0\0");
        init_bytes.extend(mp4_box(b"moov", b"mvhd1234"));
        let mut seg2_bytes = mp4_box(b"moof", b"mfhd");
        seg2_bytes.extend(mp4_box(b"mdat", b"later-seg"));

        let mut index = SegmentIndex::default();
        let init_hdr = MediaHeader {
            header_id: 1,
            itag: 140,
            lmt: 999,
            xtag: None,
            start_range: 0,
            is_init_segment: true,
            segment_index: 0,
            start_ms: None,
            duration_ms: None,
            content_length: init_bytes.len() as i64,
            data_offset: 0,
        };
        index.save(&init_hdr, init_bytes.len() as i64);

        let mut stream = Vec::new();
        let seg2_header = ProtoWriter::new()
            .varint(1, Some(3))
            .varint(3, Some(140))
            .varint(4, Some(999))
            .varint(6, Some(init_bytes.len() as i64 + 500))
            .varint(8, Some(0))
            .varint(9, Some(2))
            .varint(11, Some(10_000))
            .varint(12, Some(10_000))
            .varint(14, Some(seg2_bytes.len() as i64))
            .into_bytes();
        write_ump_part(&mut stream, 20, &seg2_header);
        let mut data = vec![3u8];
        data.extend_from_slice(&seg2_bytes);
        write_ump_part(&mut stream, 21, &data);
        write_ump_part(&mut stream, 22, &[3u8]);

        let temp = std::env::temp_dir().join(format!("rm_sabr_reseed_{}.part", std::process::id()));
        std::fs::write(&temp, &init_bytes).unwrap();
        let mut file = OpenOptions::new().append(true).open(&temp).unwrap();
        let mut file_len = init_bytes.len() as u64;
        let mut cursor = Some(MediaHeader {
            segment_index: 1,
            ..init_hdr.clone()
        });
        let mut cookie = Vec::new();
        let mut contexts = BTreeMap::new();
        let mut active_contexts = BTreeSet::new();
        let mut po_valid = true;
        let cancel = AtomicBool::new(false);
        let target = FormatId {
            itag: 140,
            lmt: 999,
            xtag: String::new(),
        };

        let outcome = process_ump_response(
            &stream[..],
            &target,
            10_000,
            &mut file,
            &mut file_len,
            &mut cursor,
            &mut index,
            &mut cookie,
            &mut contexts,
            &mut active_contexts,
            &mut po_valid,
            &cancel,
            &mut |_, _| {},
        )
        .unwrap();
        drop(file);

        assert!(outcome.reseeded_cursor);
        assert_eq!(cursor.as_ref().unwrap().segment_index, 0);
        let _ = std::fs::remove_file(&temp);
    }
}
