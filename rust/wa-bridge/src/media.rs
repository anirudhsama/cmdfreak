//! Media download (streamed to disk with progress), upload + send with byte progress, and plain
//! URL fetches.

use std::fs::File;
use std::io::{BufReader, BufWriter, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use whatsapp_rust::download::DownloadParams;
use whatsapp_rust::prelude::*;
use whatsapp_rust::upload::UploadResponse;
use whatsapp_rust::wacore::download::{DownloadWriter, MediaType};
use whatsapp_rust::wacore::time::now_secs;
use whatsapp_rust::wacore::upload::{UploadSource, encrypt_media_streaming, encrypted_len};
use whatsapp_rust::wacore::net::{HttpClient, HttpRequest};
use whatsapp_rust_ureq_http_client::UreqHttpClient;

use crate::bridge::{Shared, quote_context, require_client, sent_result};
use crate::map::media_type;
use crate::types::*;

type R<T> = Result<T, BridgeError>;

fn io(e: impl std::fmt::Display) -> BridgeError {
    BridgeError::Io(e.to_string())
}

/// File writer that reports bytes written. The library truncates the writer back to 0 before a
/// retry against another host, so `truncate` resets the reported progress too.
pub struct ProgressFile {
    file: File,
    written: u64,
    total: u64,
    last_reported: u64,
    sink: Option<Arc<dyn ProgressSink>>,
}

impl ProgressFile {
    const STEP: u64 = 64 * 1024;

    pub fn new(file: File, total: u64, sink: Option<Arc<dyn ProgressSink>>) -> Self {
        Self { file, written: 0, total, last_reported: 0, sink }
    }

    fn report(&mut self, force: bool) {
        if let Some(s) = &self.sink
            && (force || self.written.abs_diff(self.last_reported) >= Self::STEP)
        {
            self.last_reported = self.written;
            s.on_progress(self.written, self.total);
        }
    }
}

impl Write for ProgressFile {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let n = self.file.write(buf)?;
        self.written += n as u64;
        self.report(false);
        Ok(n)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.file.flush()
    }
}

impl Seek for ProgressFile {
    fn seek(&mut self, pos: SeekFrom) -> std::io::Result<u64> {
        self.file.seek(pos)
    }
}

impl DownloadWriter for ProgressFile {
    fn truncate(&mut self, len: u64) -> std::io::Result<()> {
        self.file.set_len(len)?;
        self.written = len;
        self.report(true);
        Ok(())
    }
}

fn part_path(dest: &Path) -> PathBuf {
    let mut p = dest.as_os_str().to_owned();
    p.push(".part");
    PathBuf::from(p)
}

pub async fn download(
    client: Arc<Client>,
    media: BridgeMedia,
    dest_path: String,
    progress: Option<Arc<dyn ProgressSink>>,
) -> R<()> {
    let dest = PathBuf::from(&dest_path);
    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent).map_err(io)?;
    }
    let part = part_path(&dest);
    let file = File::create(&part).map_err(io)?;
    let params = DownloadParams::encrypted(
        media.direct_path.clone(),
        &media.media_key,
        &media.file_sha256,
        &media.file_enc_sha256,
        media.file_length,
        media_type(media.media_type),
    );
    let writer = ProgressFile::new(file, media.file_length, progress);
    match client.download_from_params_to_writer(&params, writer).await {
        Ok(mut w) => {
            w.report(true);
            w.flush().map_err(io)?;
            drop(w);
            std::fs::rename(&part, &dest).map_err(io)?;
            Ok(())
        }
        Err(e) => {
            let _ = std::fs::remove_file(&part);
            Err(BridgeError::Network(format!("download: {e:#}")))
        }
    }
}

/// Plain HTTPS GET to a file (profile pictures are served unencrypted).
pub async fn fetch_url_to(url: &str, dest_path: &str) -> R<()> {
    let resp = UreqHttpClient::new()
        .execute(HttpRequest::get(url))
        .await
        .map_err(|e| BridgeError::Network(e.to_string()))?;
    if !(200..300).contains(&resp.status_code) {
        return Err(BridgeError::Network(format!("HTTP {}", resp.status_code)));
    }
    let dest = PathBuf::from(dest_path);
    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent).map_err(io)?;
    }
    let part = part_path(&dest);
    std::fs::write(&part, &resp.body).map_err(io)?;
    std::fs::rename(&part, &dest).map_err(io)
}

// MARK: - Upload

/// Above this, videos and documents are encrypted to a temp file and streamed; below it (and for
/// all images and GIFs) the ciphertext stays in memory.
const STREAM_THRESHOLD: u64 = 4 * 1024 * 1024;

/// Wraps an upload source so reads report `(offset + bytes read, total)`. The library asks for a
/// fresh reader per attempt (failover, resume), so progress rewinds with it.
struct CountingSource<S> {
    inner: S,
    sink: Option<Arc<dyn ProgressSink>>,
}

impl<S: UploadSource> UploadSource for CountingSource<S> {
    fn len(&self) -> u64 {
        self.inner.len()
    }

    fn reader_from(&self, offset: u64) -> std::io::Result<Box<dyn Read + Send>> {
        let reader = self.inner.reader_from(offset)?;
        let total = self.inner.len();
        if let Some(s) = &self.sink {
            s.on_progress(offset, total);
        }
        Ok(Box::new(CountingReader { inner: reader, pos: offset, last: offset, total, sink: self.sink.clone() }))
    }
}

struct CountingReader {
    inner: Box<dyn Read + Send>,
    pos: u64,
    last: u64,
    total: u64,
    sink: Option<Arc<dyn ProgressSink>>,
}

impl Read for CountingReader {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let n = self.inner.read(buf)?;
        self.pos += n as u64;
        if let Some(s) = &self.sink
            && (self.pos - self.last >= ProgressFile::STEP || self.pos == self.total)
        {
            self.last = self.pos;
            s.on_progress(self.pos, self.total);
        }
        Ok(n)
    }
}

struct FileSource {
    path: PathBuf,
    len: u64,
}

impl UploadSource for FileSource {
    fn len(&self) -> u64 {
        self.len
    }

    fn reader_from(&self, offset: u64) -> std::io::Result<Box<dyn Read + Send>> {
        let mut f = File::open(&self.path)?;
        f.seek(SeekFrom::Start(offset))?;
        Ok(Box::new(BufReader::with_capacity(64 * 1024, f)))
    }
}

/// Deletes the staged ciphertext however the send ends.
struct TempFile(PathBuf);

impl Drop for TempFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

fn temp_upload_path() -> PathBuf {
    static SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let n = SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    std::env::temp_dir().join(format!("wa-upload-{}-{}-{n}.enc", std::process::id(), now_secs()))
}

/// Encrypts `path` (in memory, or to a temp file when `stream`) and uploads it with byte progress.
async fn upload_file(
    client: &Client,
    path: PathBuf,
    media_type: MediaType,
    stream: bool,
    progress: Option<Arc<dyn ProgressSink>>,
) -> R<UploadResponse> {
    let upload_err = |e: anyhow::Error| BridgeError::Network(format!("upload: {e:#}"));
    if stream {
        let tmp = TempFile(temp_upload_path());
        let dest = tmp.0.clone();
        let (info, len) = tokio::task::spawn_blocking(move || -> R<_> {
            let reader = BufReader::with_capacity(256 * 1024, File::open(&path).map_err(io)?);
            let mut writer = BufWriter::with_capacity(256 * 1024, File::create(&dest).map_err(io)?);
            let info = encrypt_media_streaming(reader, &mut writer, media_type).map_err(io)?;
            writer.flush().map_err(io)?;
            let len = std::fs::metadata(&dest).map_err(io)?.len();
            Ok((info, len))
        })
        .await
        .map_err(io)??;
        let source = CountingSource { inner: FileSource { path: tmp.0.clone(), len }, sink: progress };
        client.upload_stream(source, info, media_type).await.map_err(upload_err)
    } else {
        let (info, data) = tokio::task::spawn_blocking(move || -> R<_> {
            let plain = std::fs::read(&path).map_err(io)?;
            let mut out = Vec::with_capacity(encrypted_len(plain.len()));
            let info = encrypt_media_streaming(&plain[..], &mut out, media_type).map_err(io)?;
            Ok((info, bytes::Bytes::from(out)))
        })
        .await
        .map_err(io)??;
        let source = CountingSource { inner: data, sink: progress };
        client.upload_stream(source, info, media_type).await.map_err(upload_err)
    }
}

/// Uploads the file and sends the matching message. Swift supplies the metadata (thumbnail,
/// dimensions, duration, page count); GIFs arrive already converted to MP4.
pub async fn send_media(
    shared: Arc<Shared>,
    chat: String,
    m: BridgeOutgoingMedia,
    reply_to: Option<BridgeMessageKey>,
    message_id: Option<String>,
    progress: Option<Arc<dyn ProgressSink>>,
) -> R<BridgeSendResult> {
    let client = require_client(&shared)?;
    let to: Jid = chat.parse().map_err(|_| BridgeError::InvalidJid(chat.clone()))?;
    let path = PathBuf::from(&m.file_path);
    let plain_len = std::fs::metadata(&path).map_err(io)?.len();
    let (wa_type, bridge_type) = match m.kind {
        SendMediaKind::Image => (MediaType::Image, BridgeMediaType::Image),
        SendMediaKind::Video | SendMediaKind::Gif => (MediaType::Video, BridgeMediaType::Video),
        SendMediaKind::Document => (MediaType::Document, BridgeMediaType::Document),
    };
    let stream = matches!(m.kind, SendMediaKind::Video | SendMediaKind::Document) && plain_len > STREAM_THRESHOLD;
    let up = upload_file(&client, path, wa_type, stream, progress).await?;

    let ctx = match &reply_to {
        Some(k) => Some(quote_context(&shared, &client, &to, k).await?),
        None => None,
    };
    let ctx_field = || ctx.clone().map(MessageField::some).unwrap_or_default();
    let caption = m.caption.clone().filter(|c| !c.is_empty());
    let doc_name = m.file_name.clone().or_else(|| {
        Path::new(&m.file_path).file_name().map(|n| n.to_string_lossy().into_owned())
    });
    let mut msg = wa::Message::default();
    let kind = match m.kind {
        SendMediaKind::Image => {
            msg.image_message = MessageField::some(wa::message::ImageMessage {
                url: Some(up.url.clone()),
                direct_path: Some(up.direct_path.clone()),
                media_key: Some(up.media_key.to_vec()),
                file_enc_sha256: Some(up.file_enc_sha256.to_vec()),
                file_sha256: Some(up.file_sha256.to_vec()),
                file_length: Some(up.file_length),
                media_key_timestamp: Some(up.media_key_timestamp),
                mimetype: Some(m.mimetype.clone()),
                caption: caption.clone(),
                width: m.width,
                height: m.height,
                jpeg_thumbnail: m.jpeg_thumbnail.clone(),
                context_info: ctx_field(),
                ..Default::default()
            });
            MessageKind::Image
        }
        SendMediaKind::Video | SendMediaKind::Gif => {
            let gif = m.kind == SendMediaKind::Gif;
            msg.video_message = MessageField::some(wa::message::VideoMessage {
                url: Some(up.url.clone()),
                direct_path: Some(up.direct_path.clone()),
                media_key: Some(up.media_key.to_vec()),
                file_enc_sha256: Some(up.file_enc_sha256.to_vec()),
                file_sha256: Some(up.file_sha256.to_vec()),
                file_length: Some(up.file_length),
                media_key_timestamp: Some(up.media_key_timestamp),
                mimetype: Some(m.mimetype.clone()),
                caption: caption.clone(),
                width: m.width,
                height: m.height,
                seconds: m.duration_secs,
                gif_playback: gif.then_some(true),
                jpeg_thumbnail: m.jpeg_thumbnail.clone(),
                streaming_sidecar: up.streaming_sidecar.clone(),
                context_info: ctx_field(),
                ..Default::default()
            });
            if gif { MessageKind::Gif } else { MessageKind::Video }
        }
        SendMediaKind::Document => {
            msg.document_message = MessageField::some(wa::message::DocumentMessage {
                url: Some(up.url.clone()),
                direct_path: Some(up.direct_path.clone()),
                media_key: Some(up.media_key.to_vec()),
                file_enc_sha256: Some(up.file_enc_sha256.to_vec()),
                file_sha256: Some(up.file_sha256.to_vec()),
                file_length: Some(up.file_length),
                media_key_timestamp: Some(up.media_key_timestamp),
                mimetype: Some(m.mimetype.clone()),
                file_name: doc_name.clone(),
                title: doc_name.clone(),
                caption: caption.clone(),
                page_count: m.page_count,
                jpeg_thumbnail: m.jpeg_thumbnail.clone(),
                thumbnail_width: m.thumbnail_width,
                thumbnail_height: m.thumbnail_height,
                context_info: ctx_field(),
                ..Default::default()
            });
            MessageKind::Document
        }
    };

    crate::bridge::keep_original_secret(&shared, &client, &to, message_id.as_deref(), &mut msg).await;
    let sent = client
        .send_message_with_options(to.clone(), msg, crate::bridge::send_options(message_id))
        .await
        .map_err(|e| BridgeError::Network(e.to_string()))?;
    let media = BridgeMedia {
        direct_path: up.direct_path,
        media_key: up.media_key.to_vec(),
        file_sha256: up.file_sha256.to_vec(),
        file_enc_sha256: up.file_enc_sha256.to_vec(),
        file_length: up.file_length,
        media_type: bridge_type,
        mimetype: Some(m.mimetype),
        file_name: if m.kind == SendMediaKind::Document { doc_name } else { m.file_name },
        width: m.width,
        height: m.height,
        duration_secs: m.duration_secs,
        jpeg_thumbnail: m.jpeg_thumbnail,
        waveform: None,
        page_count: m.page_count,
        is_animated: (kind == MessageKind::Gif).then_some(true),
    };
    let mut result = sent_result(&shared, &to, sent.message_id, kind, caption, Some(media), reply_to);
    result.message.participant = crate::bridge::own_participant(&shared, &client, &to).await;
    Ok(result)
}
