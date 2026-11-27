use std::{
    fs::File,
    io::{self, BufReader, BufWriter, Read, Seek, SeekFrom, Write},
    path::Path,
    sync::LazyLock,
};

const ID_EBML: u64 = 0x1A45_DFA3;
const ID_SEGMENT: u64 = 0x1853_8067;
const ID_INFO: u64 = 0x1549_A966;
const ID_TIMESTAMP_SCALE: u64 = 0x002A_D7B1;
const ID_TRACKS: u64 = 0x1654_AE6B;
const ID_TRACK_ENTRY: u64 = 0xAE;
const ID_TRACK_NUMBER: u64 = 0xD7;
const ID_CODEC_ID: u64 = 0x86;
const ID_CODEC_PRIVATE: u64 = 0x63A2;
const ID_CODEC_DELAY: u64 = 0x56AA;
const ID_AUDIO: u64 = 0xE1;
const ID_CHANNELS: u64 = 0x9F;
const ID_SAMPLING_FREQUENCY: u64 = 0xB5;
const ID_CLUSTER: u64 = 0x1F43_B675;
const ID_SIMPLE_BLOCK: u64 = 0xA3;
const ID_BLOCK_GROUP: u64 = 0xA0;
const ID_BLOCK: u64 = 0xA1;
const ID_DISCARD_PADDING: u64 = 0x75A2;

const CLUSTER_CHILDREN: [u64; 9] = [0xE7, 0x5854, 0xA7, 0xAB, 0xA3, 0xA0, 0xAF, 0xEC, 0xBF];
const OGG_FLAG_CONTINUED: u8 = 0x01;
const OGG_FLAG_BOS: u8 = 0x02;
const OGG_FLAG_EOS: u8 = 0x04;
const TARGET_PAGE_SAMPLES: u64 = 48_000;
const MAX_BLOCK_BYTES: usize = 8 * 1024 * 1024;
const OPUS_VENDOR: &str = "ReplicaMusic";

static OGG_CRC_TABLE: LazyLock<[u32; 256]> = LazyLock::new(|| {
    let mut table = [0u32; 256];
    for (index, entry) in table.iter_mut().enumerate() {
        let mut value = (index as u32) << 24;
        for _ in 0..8 {
            value = if value & 0x8000_0000 != 0 {
                (value << 1) ^ 0x04C1_1DB7
            } else {
                value << 1
            };
        }
        *entry = value;
    }
    table
});

pub fn ogg_crc32(bytes: &[u8]) -> u32 {
    bytes.iter().fold(0u32, |crc, &byte| {
        (crc << 8) ^ OGG_CRC_TABLE[((crc >> 24) ^ u32::from(byte)) as usize & 0xFF]
    })
}

fn encode_base64_standard(input: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(input.len().div_ceil(3) * 4);
    let mut chunks = input.chunks_exact(3);
    for chunk in &mut chunks {
        let n = (u32::from(chunk[0]) << 16) | (u32::from(chunk[1]) << 8) | u32::from(chunk[2]);
        out.push(TABLE[((n >> 18) & 0x3F) as usize] as char);
        out.push(TABLE[((n >> 12) & 0x3F) as usize] as char);
        out.push(TABLE[((n >> 6) & 0x3F) as usize] as char);
        out.push(TABLE[(n & 0x3F) as usize] as char);
    }
    match chunks.remainder() {
        [a] => {
            let n = u32::from(*a) << 16;
            out.push(TABLE[((n >> 18) & 0x3F) as usize] as char);
            out.push(TABLE[((n >> 12) & 0x3F) as usize] as char);
            out.push('=');
            out.push('=');
        }
        [a, b] => {
            let n = (u32::from(*a) << 16) | (u32::from(*b) << 8);
            out.push(TABLE[((n >> 18) & 0x3F) as usize] as char);
            out.push(TABLE[((n >> 12) & 0x3F) as usize] as char);
            out.push(TABLE[((n >> 6) & 0x3F) as usize] as char);
            out.push('=');
        }
        _ => {}
    }
    out
}

pub struct OpusMetadata<'a> {
    pub title: &'a str,
    pub artist: &'a str,
    pub cover_jpeg: Option<&'a [u8]>,
}

#[derive(Clone, Debug)]
struct OpusTrackInfo {
    track_number: u64,
    codec_private: Option<Vec<u8>>,
    codec_delay_ns: u64,
    channels: u8,
    sample_rate: u32,
}

impl OpusTrackInfo {
    fn build_opus_head(&self) -> Vec<u8> {
        if let Some(raw) = &self.codec_private
            && raw.len() >= 19
            && raw.starts_with(b"OpusHead")
        {
            let mut head = raw.clone();
            head[8] = 1;
            return head;
        }
        let pre_skip = if self.codec_delay_ns > 0 {
            ((u128::from(self.codec_delay_ns) * 48_000) / 1_000_000_000).min(u128::from(u16::MAX))
                as u16
        } else {
            312
        };
        let mut head = Vec::with_capacity(19);
        head.extend_from_slice(b"OpusHead");
        head.push(1);
        head.push(self.channels.max(1));
        head.extend_from_slice(&pre_skip.to_le_bytes());
        head.extend_from_slice(&self.sample_rate.max(8000).to_le_bytes());
        head.extend_from_slice(&0i16.to_le_bytes());
        head.push(0);
        head
    }
}

fn serial_from_seed(seed: &str) -> u32 {
    let mut hash = 0x811C_9DC5u32;
    for byte in seed.bytes() {
        hash ^= u32::from(byte);
        hash = hash.wrapping_mul(0x0100_0193);
    }
    if hash == 0 { 0x524D_4F50 } else { hash }
}

fn build_opus_picture_comment(jpeg: &[u8]) -> Option<String> {
    if jpeg.len() < 4 || !jpeg.starts_with(&[0xFF, 0xD8]) {
        return None;
    }
    const FRONT_COVER: u32 = 3;
    let mime = b"image/jpeg";
    let mut block = Vec::with_capacity(jpeg.len() + 48);
    block.extend_from_slice(&FRONT_COVER.to_be_bytes());
    block.extend_from_slice(&(mime.len() as u32).to_be_bytes());
    block.extend_from_slice(mime);
    for _ in 0..5 {
        block.extend_from_slice(&0u32.to_be_bytes());
    }
    block.extend_from_slice(&(jpeg.len() as u32).to_be_bytes());
    block.extend_from_slice(jpeg);
    Some(format!(
        "METADATA_BLOCK_PICTURE={}",
        encode_base64_standard(&block)
    ))
}

fn build_opus_tags(metadata: &OpusMetadata<'_>) -> Vec<u8> {
    let mut comments = Vec::new();
    let title = metadata.title.trim();
    if !title.is_empty() {
        comments.push(format!("TITLE={title}"));
    }
    let artist = metadata.artist.trim();
    if !artist.is_empty() {
        comments.push(format!("ARTIST={artist}"));
    }
    if let Some(jpeg) = metadata.cover_jpeg
        && let Some(pic) = build_opus_picture_comment(jpeg)
    {
        comments.push(pic);
    }
    let total_comments_len: usize = comments.iter().map(|c| 4 + c.len()).sum();
    let mut out = Vec::with_capacity(16 + OPUS_VENDOR.len() + total_comments_len);
    out.extend_from_slice(b"OpusTags");
    out.extend_from_slice(&(OPUS_VENDOR.len() as u32).to_le_bytes());
    out.extend_from_slice(OPUS_VENDOR.as_bytes());
    out.extend_from_slice(&(comments.len() as u32).to_le_bytes());
    for comment in &comments {
        out.extend_from_slice(&(comment.len() as u32).to_le_bytes());
        out.extend_from_slice(comment.as_bytes());
    }
    out
}

pub fn opus_packet_samples_48k(packet: &[u8]) -> Result<u64, String> {
    let Some(&toc) = packet.first() else {
        return Err("빈 Opus 패킷입니다.".into());
    };
    let config = toc >> 3;
    let frame_samples = match config {
        0..=11 => match config & 0x03 {
            0 => 480,
            1 => 960,
            2 => 1920,
            _ => 2880,
        },
        12..=15 => match config & 0x01 {
            0 => 480,
            _ => 960,
        },
        _ => match config & 0x03 {
            0 => 120,
            1 => 240,
            2 => 480,
            _ => 960,
        },
    };
    let frame_count = match toc & 0x03 {
        0 => 1u64,
        1 | 2 => 2u64,
        _ => {
            let count_byte = *packet
                .get(1)
                .ok_or("Opus 다중 프레임 패킷 헤더가 잘렸습니다.")?;
            let count = u64::from(count_byte & 0x3F);
            if count == 0 {
                return Err("Opus 프레임 개수가 0입니다.".into());
            }
            count
        }
    };
    Ok(frame_samples * frame_count)
}

fn packet_lacing_segments(len: usize) -> Vec<u8> {
    let mut segs = vec![255u8; len / 255 + 1];
    if let Some(last) = segs.last_mut() {
        *last = (len % 255) as u8;
    }
    segs
}

struct PendingPacket {
    data: Vec<u8>,
    samples: u64,
    discard_samples: u64,
}

struct OggOpusWriter<W: Write> {
    sink: W,
    serial: u32,
    sequence: u32,
    granule: u64,
    bytes_written: u64,
    page_segments: Vec<u8>,
    page_body: Vec<u8>,
    page_samples: u64,
    page_granule: u64,
    headers_written: bool,
    packet_count: u64,
    pending: Option<PendingPacket>,
}

impl<W: Write> OggOpusWriter<W> {
    fn new(sink: W, serial: u32) -> Self {
        Self {
            sink,
            serial,
            sequence: 0,
            granule: 0,
            bytes_written: 0,
            page_segments: Vec::with_capacity(255),
            page_body: Vec::with_capacity(16 * 1024),
            page_samples: 0,
            page_granule: 0,
            headers_written: false,
            packet_count: 0,
            pending: None,
        }
    }

    fn write_raw_page(
        &mut self,
        flags: u8,
        granule: u64,
        segments: &[u8],
        body: &[u8],
    ) -> Result<(), String> {
        let mut page = Vec::with_capacity(27 + segments.len() + body.len());
        page.extend_from_slice(b"OggS");
        page.push(0);
        page.push(flags);
        page.extend_from_slice(&granule.to_le_bytes());
        page.extend_from_slice(&self.serial.to_le_bytes());
        page.extend_from_slice(&self.sequence.to_le_bytes());
        page.extend_from_slice(&[0u8; 4]);
        page.push(segments.len() as u8);
        page.extend_from_slice(segments);
        page.extend_from_slice(body);
        let crc = ogg_crc32(&page);
        page[22..26].copy_from_slice(&crc.to_le_bytes());
        self.sink
            .write_all(&page)
            .map_err(|_| "Ogg Opus 페이지 쓰기에 실패했습니다.".to_owned())?;
        self.bytes_written = self.bytes_written.saturating_add(page.len() as u64);
        self.sequence = self.sequence.wrapping_add(1);
        Ok(())
    }

    fn write_packet_spanning(
        &mut self,
        packet: &[u8],
        first_flags: u8,
        end_granule: u64,
        eos: bool,
    ) -> Result<(), String> {
        let lacing = packet_lacing_segments(packet.len());
        let mut seg_idx = 0usize;
        let mut body_offset = 0usize;
        while seg_idx < lacing.len() {
            let chunk_end = (seg_idx + 255).min(lacing.len());
            let chunk = &lacing[seg_idx..chunk_end];
            let chunk_bytes: usize = chunk.iter().map(|&b| usize::from(b)).sum();
            let is_first = seg_idx == 0;
            let is_last = chunk_end == lacing.len();
            let mut flags = if is_first {
                first_flags
            } else {
                OGG_FLAG_CONTINUED
            };
            if is_last && eos {
                flags |= OGG_FLAG_EOS;
            }
            let granule = if is_last { end_granule } else { u64::MAX };
            self.write_raw_page(
                flags,
                granule,
                chunk,
                &packet[body_offset..body_offset + chunk_bytes],
            )?;
            seg_idx = chunk_end;
            body_offset += chunk_bytes;
        }
        Ok(())
    }

    fn write_headers(&mut self, head: &[u8], tags: &[u8]) -> Result<(), String> {
        if self.headers_written {
            return Ok(());
        }
        self.write_packet_spanning(head, OGG_FLAG_BOS, 0, false)?;
        self.write_packet_spanning(tags, 0, 0, false)?;
        self.headers_written = true;
        Ok(())
    }

    fn flush_audio_page(&mut self, eos: bool) -> Result<(), String> {
        if self.page_segments.is_empty() {
            return Ok(());
        }
        let flags = if eos { OGG_FLAG_EOS } else { 0 };
        let segments = std::mem::take(&mut self.page_segments);
        let body = std::mem::take(&mut self.page_body);
        let granule = self.page_granule;
        self.page_samples = 0;
        self.write_raw_page(flags, granule, &segments, &body)
    }

    fn commit_packet(&mut self, packet: PendingPacket, is_final: bool) -> Result<(), String> {
        let effective_samples = if is_final && packet.discard_samples > 0 {
            packet.samples.saturating_sub(packet.discard_samples).max(1)
        } else {
            packet.samples
        };
        let next_granule = self.granule.saturating_add(effective_samples);
        let lacing = packet_lacing_segments(packet.data.len());

        if lacing.len() > 255 {
            self.flush_audio_page(false)?;
            self.granule = next_granule;
            self.packet_count += 1;
            return self.write_packet_spanning(&packet.data, 0, next_granule, is_final);
        }

        if !self.page_segments.is_empty() && self.page_segments.len() + lacing.len() > 255 {
            self.flush_audio_page(false)?;
        }

        self.page_segments.extend_from_slice(&lacing);
        self.page_body.extend_from_slice(&packet.data);
        self.granule = next_granule;
        self.page_granule = next_granule;
        self.page_samples = self.page_samples.saturating_add(effective_samples);
        self.packet_count += 1;

        if is_final {
            self.flush_audio_page(true)?;
        } else if self.page_samples >= TARGET_PAGE_SAMPLES {
            self.flush_audio_page(false)?;
        }
        Ok(())
    }

    fn push_packet(&mut self, data: Vec<u8>, discard_samples: u64) -> Result<(), String> {
        let samples = opus_packet_samples_48k(&data)?;
        if let Some(prev) = self.pending.replace(PendingPacket {
            data,
            samples,
            discard_samples,
        }) {
            self.commit_packet(prev, false)?;
        }
        Ok(())
    }

    fn finish(mut self) -> Result<u64, String> {
        if let Some(last) = self.pending.take() {
            self.commit_packet(last, true)?;
        } else {
            self.flush_audio_page(true)?;
        }
        if self.packet_count == 0 {
            return Err("WebM 파일에서 Opus 오디오 패킷을 찾지 못했습니다.".into());
        }
        self.sink
            .flush()
            .map_err(|_| "Ogg Opus 파일 저장을 완료하지 못했습니다.".to_owned())?;
        Ok(self.bytes_written)
    }
}

fn read_exact_or_eof<R: Read>(reader: &mut R, buf: &mut [u8]) -> io::Result<bool> {
    let mut filled = 0usize;
    while filled < buf.len() {
        match reader.read(&mut buf[filled..])? {
            0 if filled == 0 => return Ok(false),
            0 => {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "EBML 스트림이 예기치 않게 끝났습니다.",
                ));
            }
            n => filled += n,
        }
    }
    Ok(true)
}

fn read_ebml_id<R: Read>(reader: &mut R) -> io::Result<Option<(u64, u64)>> {
    let mut first = [0u8; 1];
    if !read_exact_or_eof(reader, &mut first)? {
        return Ok(None);
    }
    let len = (first[0].leading_zeros() as usize) + 1;
    if !(1..=4).contains(&len) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "유효하지 않은 EBML 요소 ID입니다.",
        ));
    }
    let mut id = u64::from(first[0]);
    if len > 1 {
        let mut rest = [0u8; 3];
        reader.read_exact(&mut rest[..len - 1])?;
        for &b in &rest[..len - 1] {
            id = (id << 8) | u64::from(b);
        }
    }
    Ok(Some((id, len as u64)))
}

fn read_ebml_size<R: Read>(reader: &mut R) -> io::Result<(u64, bool, u64)> {
    let mut first = [0u8; 1];
    reader.read_exact(&mut first)?;
    let len = (first[0].leading_zeros() as usize) + 1;
    if !(1..=8).contains(&len) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "유효하지 않은 EBML 크기 VINT입니다.",
        ));
    }
    let mask = 0xFFu8.checked_shr(len as u32).unwrap_or(0);
    let mut value = u64::from(first[0] & mask);
    let mut all_ones = (first[0] & mask) == mask;
    if len > 1 {
        let mut rest = [0u8; 7];
        reader.read_exact(&mut rest[..len - 1])?;
        for &b in &rest[..len - 1] {
            if b != 0xFF {
                all_ones = false;
            }
            value = (value << 8) | u64::from(b);
        }
    }
    Ok((value, all_ones, len as u64))
}

fn read_ebml_uint<R: Read>(reader: &mut R, size: u64) -> io::Result<u64> {
    if size > 8 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "EBML 정수 크기 초과",
        ));
    }
    let mut buf = [0u8; 8];
    let n = size as usize;
    reader.read_exact(&mut buf[..n])?;
    let mut val = 0u64;
    for &b in &buf[..n] {
        val = (val << 8) | u64::from(b);
    }
    Ok(val)
}

fn read_ebml_int<R: Read>(reader: &mut R, size: u64) -> io::Result<i64> {
    if size == 0 || size > 8 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "EBML 부호 정수 크기 오류",
        ));
    }
    let mut buf = [0u8; 8];
    let n = size as usize;
    reader.read_exact(&mut buf[..n])?;
    let negative = (buf[0] & 0x80) != 0;
    let mut val = if negative { -1i64 } else { 0i64 };
    for &b in &buf[..n] {
        val = (val << 8) | i64::from(b);
    }
    Ok(val)
}

fn read_ebml_float<R: Read>(reader: &mut R, size: u64) -> io::Result<f64> {
    match size {
        4 => {
            let mut buf = [0u8; 4];
            reader.read_exact(&mut buf)?;
            Ok(f64::from(f32::from_be_bytes(buf)))
        }
        8 => {
            let mut buf = [0u8; 8];
            reader.read_exact(&mut buf)?;
            Ok(f64::from_be_bytes(buf))
        }
        _ => Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "EBML 실수 크기 오류",
        )),
    }
}

fn parse_slice_vint_unsigned(data: &[u8]) -> Result<(u64, usize), String> {
    let Some(&first) = data.first() else {
        return Err("블록 VINT가 잘렸습니다.".into());
    };
    let len = (first.leading_zeros() as usize) + 1;
    if !(1..=8).contains(&len) || data.len() < len {
        return Err("유효하지 않은 블록 VINT입니다.".into());
    }
    let mask = 0xFFu8.checked_shr(len as u32).unwrap_or(0);
    let mut val = u64::from(first & mask);
    for &b in &data[1..len] {
        val = (val << 8) | u64::from(b);
    }
    Ok((val, len))
}

fn parse_slice_vint_signed(data: &[u8]) -> Result<(i64, usize), String> {
    let (raw, len) = parse_slice_vint_unsigned(data)?;
    let bias = (1i64 << (7 * len - 1)) - 1;
    Ok((raw as i64 - bias, len))
}

fn decode_matroska_block<'a>(block: &'a [u8], target_track: u64) -> Result<Vec<&'a [u8]>, String> {
    let (track_num, vint_len) = parse_slice_vint_unsigned(block)?;
    if track_num != target_track {
        return Ok(Vec::new());
    }
    if block.len() < vint_len + 3 {
        return Err("Matroska 블록 헤더가 너무 짧습니다.".into());
    }
    let flags = block[vint_len + 2];
    let payload = &block[vint_len + 3..];
    let lacing = (flags >> 1) & 0x03;

    match lacing {
        0 => {
            if payload.is_empty() {
                Ok(Vec::new())
            } else {
                Ok(vec![payload])
            }
        }
        1 => {
            let Some(&count_minus_one) = payload.first() else {
                return Err("Xiph 레이싱 헤더가 없습니다.".into());
            };
            let frame_count = usize::from(count_minus_one) + 1;
            let mut offset = 1usize;
            let mut sizes = Vec::with_capacity(frame_count);
            for _ in 0..frame_count.saturating_sub(1) {
                let mut frame_size = 0usize;
                loop {
                    let &b = payload
                        .get(offset)
                        .ok_or("Xiph 레이싱 크기가 잘렸습니다.")?;
                    offset += 1;
                    frame_size = frame_size
                        .checked_add(usize::from(b))
                        .ok_or("Xiph 레이싱 크기 오버플로")?;
                    if b != 255 {
                        break;
                    }
                }
                sizes.push(frame_size);
            }
            split_laced_frames(&payload[offset..], &sizes)
        }
        2 => {
            let Some(&count_minus_one) = payload.first() else {
                return Err("고정 레이싱 헤더가 없습니다.".into());
            };
            let frame_count = usize::from(count_minus_one) + 1;
            let frames_data = &payload[1..];
            if frames_data.len() % frame_count != 0 {
                return Err("고정 레이싱 프레임 크기가 나누어 떨어지지 않습니다.".into());
            }
            let frame_size = frames_data.len() / frame_count;
            let mut out = Vec::with_capacity(frame_count);
            for i in 0..frame_count {
                let start = i * frame_size;
                out.push(&frames_data[start..start + frame_size]);
            }
            Ok(out)
        }
        _ => {
            let Some(&count_minus_one) = payload.first() else {
                return Err("EBML 레이싱 헤더가 없습니다.".into());
            };
            let frame_count = usize::from(count_minus_one) + 1;
            let mut offset = 1usize;
            let mut sizes = Vec::with_capacity(frame_count);
            if frame_count > 1 {
                let (first_size, used) = parse_slice_vint_unsigned(&payload[offset..])?;
                offset += used;
                let mut prev = i64::try_from(first_size).map_err(|_| "EBML 레이싱 크기 초과")?;
                sizes.push(usize::try_from(prev).map_err(|_| "EBML 레이싱 크기 초과")?);
                for _ in 1..frame_count - 1 {
                    let (delta, used) = parse_slice_vint_signed(&payload[offset..])?;
                    offset += used;
                    prev = prev.checked_add(delta).ok_or("EBML 레이싱 크기 오버플로")?;
                    if prev < 0 {
                        return Err("EBML 레이싱 프레임 크기가 음수입니다.".into());
                    }
                    sizes.push(usize::try_from(prev).map_err(|_| "EBML 레이싱 크기 초과")?);
                }
            }
            split_laced_frames(&payload[offset..], &sizes)
        }
    }
}

fn split_laced_frames<'a>(data: &'a [u8], prefix_sizes: &[usize]) -> Result<Vec<&'a [u8]>, String> {
    let mut frames = Vec::with_capacity(prefix_sizes.len() + 1);
    let mut pos = 0usize;
    for &size in prefix_sizes {
        let end = pos
            .checked_add(size)
            .ok_or("레이싱 프레임 오프셋 오버플로")?;
        if end > data.len() {
            return Err("레이싱 프레임이 블록 크기를 초과했습니다.".into());
        }
        frames.push(&data[pos..end]);
        pos = end;
    }
    if pos < data.len() {
        frames.push(&data[pos..]);
    }
    Ok(frames)
}

fn parse_track_entry<R: Read + Seek>(
    reader: &mut R,
    entry_end: u64,
) -> Result<Option<OpusTrackInfo>, String> {
    let mut track_number = 0u64;
    let mut codec_id = String::new();
    let mut codec_private: Option<Vec<u8>> = None;
    let mut codec_delay_ns = 0u64;
    let mut channels = 2u8;
    let mut sample_rate = 48_000u32;

    while reader.stream_position().map_err(|e| e.to_string())? < entry_end {
        let Some((id, _)) = read_ebml_id(reader).map_err(|e| e.to_string())? else {
            break;
        };
        let (size, unknown, _) = read_ebml_size(reader).map_err(|e| e.to_string())?;
        let data_start = reader.stream_position().map_err(|e| e.to_string())?;
        let elem_end = if unknown {
            entry_end
        } else {
            data_start.saturating_add(size).min(entry_end)
        };
        match id {
            ID_TRACK_NUMBER => {
                track_number = read_ebml_uint(reader, size).map_err(|e| e.to_string())?;
            }
            ID_CODEC_ID => {
                let len = usize::try_from(size.min(64)).unwrap_or(0);
                let mut buf = vec![0u8; len];
                reader.read_exact(&mut buf).map_err(|e| e.to_string())?;
                codec_id = String::from_utf8_lossy(&buf)
                    .trim_end_matches('\0')
                    .to_owned();
            }
            ID_CODEC_PRIVATE => {
                let len = usize::try_from(size.min(64 * 1024)).unwrap_or(0);
                let mut buf = vec![0u8; len];
                reader.read_exact(&mut buf).map_err(|e| e.to_string())?;
                codec_private = Some(buf);
            }
            ID_CODEC_DELAY => {
                codec_delay_ns = read_ebml_uint(reader, size).map_err(|e| e.to_string())?;
            }
            ID_AUDIO => {
                while reader.stream_position().map_err(|e| e.to_string())? < elem_end {
                    let Some((aid, _)) = read_ebml_id(reader).map_err(|e| e.to_string())? else {
                        break;
                    };
                    let (asize, aunknown, _) = read_ebml_size(reader).map_err(|e| e.to_string())?;
                    let astart = reader.stream_position().map_err(|e| e.to_string())?;
                    let aend = if aunknown {
                        elem_end
                    } else {
                        astart.saturating_add(asize).min(elem_end)
                    };
                    match aid {
                        ID_CHANNELS => {
                            let ch = read_ebml_uint(reader, asize).map_err(|e| e.to_string())?;
                            channels = u8::try_from(ch.clamp(1, 255)).unwrap_or(2);
                        }
                        ID_SAMPLING_FREQUENCY => {
                            let sr = read_ebml_float(reader, asize).map_err(|e| e.to_string())?;
                            if sr.is_finite() && sr >= 8000.0 {
                                sample_rate = sr.round() as u32;
                            }
                        }
                        _ => {}
                    }
                    reader
                        .seek(SeekFrom::Start(aend))
                        .map_err(|e| e.to_string())?;
                }
            }
            _ => {}
        }
        reader
            .seek(SeekFrom::Start(elem_end))
            .map_err(|e| e.to_string())?;
    }

    if codec_id == "A_OPUS" && track_number > 0 {
        Ok(Some(OpusTrackInfo {
            track_number,
            codec_private,
            codec_delay_ns,
            channels,
            sample_rate,
        }))
    } else {
        Ok(None)
    }
}

fn parse_tracks<R: Read + Seek>(
    reader: &mut R,
    tracks_end: u64,
) -> Result<Option<OpusTrackInfo>, String> {
    let mut found = None;
    while reader.stream_position().map_err(|e| e.to_string())? < tracks_end {
        let Some((id, _)) = read_ebml_id(reader).map_err(|e| e.to_string())? else {
            break;
        };
        let (size, unknown, _) = read_ebml_size(reader).map_err(|e| e.to_string())?;
        let data_start = reader.stream_position().map_err(|e| e.to_string())?;
        let elem_end = if unknown {
            tracks_end
        } else {
            data_start.saturating_add(size).min(tracks_end)
        };
        if id == ID_TRACK_ENTRY && found.is_none() {
            found = parse_track_entry(reader, elem_end)?;
        }
        reader
            .seek(SeekFrom::Start(elem_end))
            .map_err(|e| e.to_string())?;
    }
    Ok(found)
}

fn parse_info<R: Read + Seek>(reader: &mut R, info_end: u64) -> Result<u64, String> {
    let mut timestamp_scale = 1_000_000u64;
    while reader.stream_position().map_err(|e| e.to_string())? < info_end {
        let Some((id, _)) = read_ebml_id(reader).map_err(|e| e.to_string())? else {
            break;
        };
        let (size, unknown, _) = read_ebml_size(reader).map_err(|e| e.to_string())?;
        let data_start = reader.stream_position().map_err(|e| e.to_string())?;
        let elem_end = if unknown {
            info_end
        } else {
            data_start.saturating_add(size).min(info_end)
        };
        if id == ID_TIMESTAMP_SCALE {
            timestamp_scale = read_ebml_uint(reader, size).map_err(|e| e.to_string())?;
        }
        reader
            .seek(SeekFrom::Start(elem_end))
            .map_err(|e| e.to_string())?;
    }
    Ok(timestamp_scale)
}

fn feed_block_packets<W: Write>(
    block: &[u8],
    track_number: u64,
    discard_ns: i64,
    writer: &mut OggOpusWriter<W>,
) -> Result<(), String> {
    let frames = decode_matroska_block(block, track_number)?;
    if frames.is_empty() {
        return Ok(());
    }
    let discard_samples = if discard_ns > 0 {
        ((u128::from(discard_ns as u64) * 48_000) / 1_000_000_000) as u64
    } else {
        0
    };
    let last_idx = frames.len() - 1;
    for (idx, frame) in frames.into_iter().enumerate() {
        let trim = if idx == last_idx { discard_samples } else { 0 };
        writer.push_packet(frame.to_vec(), trim)?;
    }
    Ok(())
}

fn parse_block_group<R: Read + Seek, W: Write>(
    reader: &mut R,
    group_end: u64,
    track_number: u64,
    writer: &mut OggOpusWriter<W>,
) -> Result<(), String> {
    let mut block_bytes: Option<Vec<u8>> = None;
    let mut discard_ns = 0i64;
    while reader.stream_position().map_err(|e| e.to_string())? < group_end {
        let Some((id, _)) = read_ebml_id(reader).map_err(|e| e.to_string())? else {
            break;
        };
        let (size, unknown, _) = read_ebml_size(reader).map_err(|e| e.to_string())?;
        let data_start = reader.stream_position().map_err(|e| e.to_string())?;
        let elem_end = if unknown {
            group_end
        } else {
            data_start.saturating_add(size).min(group_end)
        };
        match id {
            ID_BLOCK => {
                let len =
                    usize::try_from(size).map_err(|_| "Block 크기가 너무 큽니다.".to_owned())?;
                if len > MAX_BLOCK_BYTES {
                    return Err("Block 크기가 허용 한도를 초과했습니다.".into());
                }
                let mut buf = vec![0u8; len];
                reader.read_exact(&mut buf).map_err(|e| e.to_string())?;
                block_bytes = Some(buf);
            }
            ID_DISCARD_PADDING => {
                discard_ns = read_ebml_int(reader, size).map_err(|e| e.to_string())?;
            }
            _ => {}
        }
        reader
            .seek(SeekFrom::Start(elem_end))
            .map_err(|e| e.to_string())?;
    }
    if let Some(block) = block_bytes {
        feed_block_packets(&block, track_number, discard_ns, writer)?;
    }
    Ok(())
}

fn parse_cluster<R: Read + Seek, W: Write>(
    reader: &mut R,
    cluster_end: u64,
    unknown_cluster_size: bool,
    track_number: u64,
    writer: &mut OggOpusWriter<W>,
) -> Result<(), String> {
    while reader.stream_position().map_err(|e| e.to_string())? < cluster_end {
        let child_start = reader.stream_position().map_err(|e| e.to_string())?;
        let Some((id, _)) = read_ebml_id(reader).map_err(|e| e.to_string())? else {
            break;
        };
        if !CLUSTER_CHILDREN.contains(&id) {
            if unknown_cluster_size {
                reader
                    .seek(SeekFrom::Start(child_start))
                    .map_err(|e| e.to_string())?;
                return Ok(());
            }
            return Err(format!("Cluster 내부에 유효하지 않은 요소 (0x{id:x})"));
        }
        let (size, unknown, _) = read_ebml_size(reader).map_err(|e| e.to_string())?;
        let data_start = reader.stream_position().map_err(|e| e.to_string())?;
        let elem_end = if unknown {
            cluster_end
        } else {
            data_start.saturating_add(size).min(cluster_end)
        };
        match id {
            ID_SIMPLE_BLOCK => {
                let len = usize::try_from(size)
                    .map_err(|_| "SimpleBlock 크기가 너무 큽니다.".to_owned())?;
                if len > MAX_BLOCK_BYTES {
                    return Err("SimpleBlock 크기가 허용 한도를 초과했습니다.".into());
                }
                let mut buf = vec![0u8; len];
                reader.read_exact(&mut buf).map_err(|e| e.to_string())?;
                feed_block_packets(&buf, track_number, 0, writer)?;
            }
            ID_BLOCK_GROUP => {
                parse_block_group(reader, elem_end, track_number, writer)?;
            }
            _ => {}
        }
        reader
            .seek(SeekFrom::Start(elem_end))
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}

pub fn remux_webm_to_ogg_opus_streams<R: Read + Seek, W: Write>(
    mut reader: R,
    sink: W,
    metadata: &OpusMetadata<'_>,
    serial_seed: &str,
) -> Result<u64, String> {
    let file_len = reader.seek(SeekFrom::End(0)).map_err(|e| e.to_string())?;
    reader.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;

    let mut saw_ebml = false;
    let mut segment_range: Option<(u64, u64)> = None;
    while reader.stream_position().map_err(|e| e.to_string())? < file_len {
        let Some((id, _)) = read_ebml_id(&mut reader).map_err(|e| e.to_string())? else {
            break;
        };
        let (size, unknown, _) = read_ebml_size(&mut reader).map_err(|e| e.to_string())?;
        let data_start = reader.stream_position().map_err(|e| e.to_string())?;
        let elem_end = if unknown {
            file_len
        } else {
            data_start.saturating_add(size).min(file_len)
        };
        match id {
            ID_EBML => {
                saw_ebml = true;
                reader
                    .seek(SeekFrom::Start(elem_end))
                    .map_err(|e| e.to_string())?;
            }
            ID_SEGMENT => {
                segment_range = Some((data_start, elem_end));
                break;
            }
            _ => {
                reader
                    .seek(SeekFrom::Start(elem_end))
                    .map_err(|e| e.to_string())?;
            }
        }
    }
    if !saw_ebml {
        return Err("유효한 WebM(EBML) 헤더가 아닙니다.".into());
    }
    let Some((seg_start, seg_end)) = segment_range else {
        return Err("WebM Segment 요소를 찾지 못했습니다.".into());
    };
    reader
        .seek(SeekFrom::Start(seg_start))
        .map_err(|e| e.to_string())?;

    let mut writer = OggOpusWriter::new(sink, serial_from_seed(serial_seed));
    let mut opus_track: Option<OpusTrackInfo> = None;
    let tags_packet = build_opus_tags(metadata);

    while reader.stream_position().map_err(|e| e.to_string())? < seg_end {
        let Some((id, _)) = read_ebml_id(&mut reader).map_err(|e| e.to_string())? else {
            break;
        };
        if id == ID_EBML || id == ID_SEGMENT {
            break;
        }
        let (size, unknown, _) = read_ebml_size(&mut reader).map_err(|e| e.to_string())?;
        let data_start = reader.stream_position().map_err(|e| e.to_string())?;
        let elem_end = if unknown {
            seg_end
        } else {
            data_start.saturating_add(size).min(seg_end)
        };
        match id {
            ID_INFO => {
                let _ = parse_info(&mut reader, elem_end)?;
                reader
                    .seek(SeekFrom::Start(elem_end))
                    .map_err(|e| e.to_string())?;
            }
            ID_TRACKS => {
                if let Some(track) = parse_tracks(&mut reader, elem_end)? {
                    opus_track = Some(track);
                }
                reader
                    .seek(SeekFrom::Start(elem_end))
                    .map_err(|e| e.to_string())?;
            }
            ID_CLUSTER => {
                let Some(track) = opus_track.as_ref() else {
                    return Err("WebM 파일에 A_OPUS 트랙 정보가 없습니다.".into());
                };
                if !writer.headers_written {
                    let head_packet = track.build_opus_head();
                    writer.write_headers(&head_packet, &tags_packet)?;
                }
                parse_cluster(
                    &mut reader,
                    elem_end,
                    unknown,
                    track.track_number,
                    &mut writer,
                )?;
                if !unknown {
                    reader
                        .seek(SeekFrom::Start(elem_end))
                        .map_err(|e| e.to_string())?;
                }
            }
            _ => {
                reader
                    .seek(SeekFrom::Start(elem_end))
                    .map_err(|e| e.to_string())?;
            }
        }
    }

    writer.finish()
}

pub fn remux_webm_to_ogg_opus(
    input_path: &Path,
    output_path: &Path,
    metadata: &OpusMetadata<'_>,
    serial_seed: &str,
) -> Result<u64, String> {
    let input = File::open(input_path).map_err(|_| "WebM 임시 파일을 열지 못했습니다.")?;
    let output = File::create(output_path).map_err(|_| "Opus 출력 파일을 만들지 못했습니다.")?;
    remux_webm_to_ogg_opus_streams(
        BufReader::with_capacity(64 * 1024, input),
        BufWriter::with_capacity(64 * 1024, output),
        metadata,
        serial_seed,
    )
}

fn read_and_verify_ogg_page<R: Read>(reader: &mut R) -> Option<(u8, u64, u32, Vec<u8>)> {
    let mut header = [0u8; 27];
    if reader.read_exact(&mut header).is_err() {
        return None;
    }
    if &header[..4] != b"OggS" || header[4] != 0 {
        return None;
    }
    let flags = header[5];
    let granule = u64::from_le_bytes(header[6..14].try_into().ok()?);
    let sequence = u32::from_le_bytes(header[18..22].try_into().ok()?);
    let expected_crc = u32::from_le_bytes(header[22..26].try_into().ok()?);
    let seg_count = usize::from(header[26]);
    let mut segments = vec![0u8; seg_count];
    if reader.read_exact(&mut segments).is_err() {
        return None;
    }
    let body_len: usize = segments.iter().map(|&b| usize::from(b)).sum();
    let mut body = vec![0u8; body_len];
    if reader.read_exact(&mut body).is_err() {
        return None;
    }
    let mut raw = Vec::with_capacity(27 + seg_count + body_len);
    raw.extend_from_slice(&header);
    raw[22..26].copy_from_slice(&[0u8; 4]);
    raw.extend_from_slice(&segments);
    raw.extend_from_slice(&body);
    if ogg_crc32(&raw) != expected_crc {
        return None;
    }
    Some((flags, granule, sequence, body))
}

pub fn validate_ogg_opus_file(path: &Path) -> bool {
    let Ok(file) = File::open(path) else {
        return false;
    };
    let mut reader = BufReader::new(file);
    let Some((head_flags, _, head_seq, head_body)) = read_and_verify_ogg_page(&mut reader) else {
        return false;
    };
    if (head_flags & OGG_FLAG_BOS) == 0
        || head_seq != 0
        || head_body.len() < 19
        || !head_body.starts_with(b"OpusHead")
    {
        return false;
    }
    let Some((_, _, tags_seq, tags_body)) = read_and_verify_ogg_page(&mut reader) else {
        return false;
    };
    if tags_seq != 1 || !tags_body.starts_with(b"OpusTags") {
        return false;
    }
    while let Some((flags, granule, _, _)) = read_and_verify_ogg_page(&mut reader) {
        if granule != u64::MAX && granule > 0 {
            return true;
        }
        if (flags & OGG_FLAG_EOS) != 0 {
            return granule > 0;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    fn write_vint_id(out: &mut Vec<u8>, id: u64) {
        let bytes = id.to_be_bytes();
        let start = bytes.iter().position(|&b| b != 0).unwrap_or(7);
        out.extend_from_slice(&bytes[start..]);
    }

    fn write_vint_size(out: &mut Vec<u8>, size: u64) {
        if size < 0x7F {
            out.push((size as u8) | 0x80);
        } else if size < 0x3FFF {
            let v = (size as u16) | 0x4000;
            out.extend_from_slice(&v.to_be_bytes());
        } else {
            let v = (size as u32) | 0x1000_0000;
            out.extend_from_slice(&v.to_be_bytes());
        }
    }

    fn ebml_elem(id: u64, body: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        write_vint_id(&mut out, id);
        write_vint_size(&mut out, body.len() as u64);
        out.extend_from_slice(body);
        out
    }

    fn build_synthetic_webm(blocks: Vec<Vec<u8>>, unknown_sizes: bool) -> Vec<u8> {
        let mut opus_head = Vec::new();
        opus_head.extend_from_slice(b"OpusHead");
        opus_head.push(1);
        opus_head.push(2);
        opus_head.extend_from_slice(&312u16.to_le_bytes());
        opus_head.extend_from_slice(&48_000u32.to_le_bytes());
        opus_head.extend_from_slice(&0i16.to_le_bytes());
        opus_head.push(0);

        let mut audio = Vec::new();
        audio.extend(ebml_elem(ID_CHANNELS, &[2]));
        audio.extend(ebml_elem(ID_SAMPLING_FREQUENCY, &48_000.0f32.to_be_bytes()));

        let mut track_entry = Vec::new();
        track_entry.extend(ebml_elem(ID_TRACK_NUMBER, &[1]));
        track_entry.extend(ebml_elem(ID_CODEC_ID, b"A_OPUS"));
        track_entry.extend(ebml_elem(ID_CODEC_PRIVATE, &opus_head));
        track_entry.extend(ebml_elem(ID_AUDIO, &audio));

        let tracks = ebml_elem(ID_TRACKS, &ebml_elem(ID_TRACK_ENTRY, &track_entry));
        let info = ebml_elem(ID_INFO, &ebml_elem(ID_TIMESTAMP_SCALE, &[0x0F, 0x42, 0x40]));

        let mut cluster_body = Vec::new();
        cluster_body.extend(ebml_elem(0xE7, &[0]));
        for block in blocks {
            cluster_body.extend(block);
        }
        let mut cluster = Vec::new();
        write_vint_id(&mut cluster, ID_CLUSTER);
        if unknown_sizes {
            cluster.push(0xFF);
        } else {
            write_vint_size(&mut cluster, cluster_body.len() as u64);
        }
        cluster.extend(cluster_body);

        let mut seg_body = Vec::new();
        seg_body.extend(info);
        seg_body.extend(tracks);
        seg_body.extend(cluster);

        let mut out = Vec::new();
        out.extend(ebml_elem(ID_EBML, &ebml_elem(0x4282, b"webm")));
        write_vint_id(&mut out, ID_SEGMENT);
        if unknown_sizes {
            out.push(0xFF);
        } else {
            write_vint_size(&mut out, seg_body.len() as u64);
        }
        out.extend(seg_body);
        out
    }

    fn simple_block_raw(lacing: u8, payload: &[u8]) -> Vec<u8> {
        let mut b = vec![0x81, 0x00, 0x00, (lacing & 0x03) << 1];
        b.extend_from_slice(payload);
        ebml_elem(ID_SIMPLE_BLOCK, &b)
    }

    #[test]
    fn computes_opus_packet_samples_across_toc_configs() {
        assert_eq!(opus_packet_samples_48k(&[0x00, 0xAA]).unwrap(), 480);
        assert_eq!(opus_packet_samples_48k(&[0x08, 0xAA]).unwrap(), 960);
        assert_eq!(opus_packet_samples_48k(&[0x10, 0xAA]).unwrap(), 1920);
        assert_eq!(opus_packet_samples_48k(&[0x18, 0xAA]).unwrap(), 2880);
        assert_eq!(opus_packet_samples_48k(&[0x60, 0xAA]).unwrap(), 480);
        assert_eq!(opus_packet_samples_48k(&[0x68, 0xAA]).unwrap(), 960);
        assert_eq!(opus_packet_samples_48k(&[0x80, 0xAA]).unwrap(), 120);
        assert_eq!(opus_packet_samples_48k(&[0x88, 0xAA]).unwrap(), 240);
        assert_eq!(opus_packet_samples_48k(&[0xF8, 0xAA]).unwrap(), 960);
        assert_eq!(opus_packet_samples_48k(&[0xF9, 0xAA]).unwrap(), 1920);
        assert_eq!(opus_packet_samples_48k(&[0xFB, 0x03, 0xAA]).unwrap(), 2880);
    }

    #[test]
    fn remuxes_webm_opus_with_all_lacing_modes_discard_padding_and_multipage_cover() {
        let pkt_20ms = [0xF8u8, 0x11, 0x22, 0x33];
        let pkt_10ms = [0xF0u8, 0x44, 0x55];

        let unlaced = simple_block_raw(0, &pkt_20ms);

        let mut xiph_payload = vec![1u8, pkt_20ms.len() as u8];
        xiph_payload.extend_from_slice(&pkt_20ms);
        xiph_payload.extend_from_slice(&pkt_10ms);
        let xiph = simple_block_raw(1, &xiph_payload);

        let mut fixed_payload = vec![1u8];
        fixed_payload.extend_from_slice(&pkt_20ms);
        fixed_payload.extend_from_slice(&pkt_20ms);
        let fixed = simple_block_raw(2, &fixed_payload);

        let mut ebml_lace_payload = vec![1u8, 0x80 | (pkt_20ms.len() as u8)];
        ebml_lace_payload.extend_from_slice(&pkt_20ms);
        ebml_lace_payload.extend_from_slice(&pkt_10ms);
        let ebml_laced = simple_block_raw(3, &ebml_lace_payload);

        let mut last_raw = vec![0x81, 0x00, 0x00, 0x00];
        last_raw.extend_from_slice(&pkt_20ms);
        let discard_5ms_ns: i64 = 5_000_000;
        let mut group_body = Vec::new();
        group_body.extend(ebml_elem(ID_BLOCK, &last_raw));
        group_body.extend(ebml_elem(ID_DISCARD_PADDING, &discard_5ms_ns.to_be_bytes()));
        let block_group = ebml_elem(ID_BLOCK_GROUP, &group_body);

        let webm = build_synthetic_webm(vec![unlaced, xiph, fixed, ebml_laced, block_group], true);

        let mut fake_jpeg = vec![0xFFu8, 0xD8, 0xFF, 0xE0];
        fake_jpeg.resize(60_000, 0x42);

        let meta = OpusMetadata {
            title: "Test Opus Track",
            artist: "Replica Artist",
            cover_jpeg: Some(&fake_jpeg),
        };
        let mut ogg_out = Vec::new();
        let written =
            remux_webm_to_ogg_opus_streams(Cursor::new(&webm), &mut ogg_out, &meta, "dQw4w9WgXcQ")
                .unwrap();
        assert_eq!(written as usize, ogg_out.len());

        let mut cursor = Cursor::new(&ogg_out);
        let mut pages = Vec::new();
        while let Some(page) = read_and_verify_ogg_page(&mut cursor) {
            pages.push(page);
        }
        assert!(pages.len() >= 4);
        assert_eq!(pages[0].0 & OGG_FLAG_BOS, OGG_FLAG_BOS);
        assert!(pages[0].3.starts_with(b"OpusHead"));
        assert!(pages[1].3.starts_with(b"OpusTags"));
        assert_eq!(pages[1].1, u64::MAX);
        assert_eq!(pages[2].0 & OGG_FLAG_CONTINUED, OGG_FLAG_CONTINUED);
        assert_eq!(pages[2].1, 0);

        let mut tags_combined = Vec::new();
        tags_combined.extend_from_slice(&pages[1].3);
        tags_combined.extend_from_slice(&pages[2].3);
        let tags_str = String::from_utf8_lossy(&tags_combined);
        assert!(tags_str.contains("TITLE=Test Opus Track"));
        assert!(tags_str.contains("ARTIST=Replica Artist"));
        assert!(tags_str.contains("METADATA_BLOCK_PICTURE="));

        let last = pages.last().unwrap();
        assert_eq!(last.0 & OGG_FLAG_EOS, OGG_FLAG_EOS);
        let expected_samples = 960 + (960 + 480) + (960 + 960) + (960 + 480) + (960 - 240);
        assert_eq!(last.1, expected_samples);

        let temp = std::env::temp_dir().join(format!("rm_opus_mux_{}.opus", std::process::id()));
        std::fs::write(&temp, &ogg_out).unwrap();
        assert!(validate_ogg_opus_file(&temp));
        let _ = std::fs::remove_file(&temp);
    }
}
