//! Media download (streamed to disk with progress), upload + send, and plain URL fetches.

use std::fs::File;
use std::io::{Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use whatsapp_rust::download::DownloadParams;
use whatsapp_rust::prelude::*;
use whatsapp_rust::upload::UploadOptions;
use whatsapp_rust::wacore::download::{DownloadWriter, MediaType};
use whatsapp_rust::wacore::net::{HttpClient, HttpRequest};
use whatsapp_rust_ureq_http_client::UreqHttpClient;

use crate::bridge::{Shared, quote_ctx_for, require_client, sent_result};
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

/// Uploads the file and sends the matching message. Buffers the file in memory (the library's
/// `upload`); progress is reported at start and completion only. M5 can move large videos and
/// documents to `encrypt_media_streaming` + `upload_stream` with a counting source.
pub async fn send_media(
    shared: Arc<Shared>,
    chat: String,
    m: BridgeOutgoingMedia,
    reply_to: Option<BridgeMessageKey>,
    progress: Option<Arc<dyn ProgressSink>>,
) -> R<BridgeSendResult> {
    let client = require_client(&shared)?;
    let to: Jid = chat.parse().map_err(|_| BridgeError::InvalidJid(chat.clone()))?;
    let path = m.file_path.clone();
    let data = tokio::task::spawn_blocking(move || std::fs::read(path))
        .await
        .map_err(io)?
        .map_err(io)?;
    let total = data.len() as u64;
    if let Some(p) = &progress {
        p.on_progress(0, total);
    }
    let (wa_type, bridge_type) = match m.kind {
        SendMediaKind::Image => (MediaType::Image, BridgeMediaType::Image),
        SendMediaKind::Video | SendMediaKind::Gif => (MediaType::Video, BridgeMediaType::Video),
        SendMediaKind::Document => (MediaType::Document, BridgeMediaType::Document),
    };
    let up = client
        .upload(data, wa_type, UploadOptions::new())
        .await
        .map_err(|e| BridgeError::Network(format!("upload: {e:#}")))?;
    if let Some(p) = &progress {
        p.on_progress(total, total);
    }

    let ctx = reply_to.as_ref().map(|k| quote_ctx_for(&shared, k));
    let ctx_field = || ctx.clone().map(MessageField::some).unwrap_or_default();
    let caption = m.caption.clone().filter(|c| !c.is_empty());
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
            let name = m.file_name.clone().or_else(|| {
                Path::new(&m.file_path).file_name().map(|n| n.to_string_lossy().into_owned())
            });
            msg.document_message = MessageField::some(wa::message::DocumentMessage {
                url: Some(up.url.clone()),
                direct_path: Some(up.direct_path.clone()),
                media_key: Some(up.media_key.to_vec()),
                file_enc_sha256: Some(up.file_enc_sha256.to_vec()),
                file_sha256: Some(up.file_sha256.to_vec()),
                file_length: Some(up.file_length),
                media_key_timestamp: Some(up.media_key_timestamp),
                mimetype: Some(m.mimetype.clone()),
                file_name: name.clone(),
                title: name,
                caption: caption.clone(),
                page_count: m.page_count,
                jpeg_thumbnail: m.jpeg_thumbnail.clone(),
                context_info: ctx_field(),
                ..Default::default()
            });
            MessageKind::Document
        }
    };

    let sent = client
        .send_message(to.clone(), msg)
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
        file_name: m.file_name,
        width: m.width,
        height: m.height,
        duration_secs: m.duration_secs,
        jpeg_thumbnail: m.jpeg_thumbnail,
        waveform: None,
        page_count: m.page_count,
        is_animated: (kind == MessageKind::Gif).then_some(true),
    };
    Ok(sent_result(&shared, &to, sent.message_id, kind, caption, Some(media), reply_to))
}
