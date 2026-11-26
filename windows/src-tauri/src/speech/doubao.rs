//! Doubao Streaming ASR 2.0 (Volcengine), sentence mode (`bigmodel_nostream`), the same binary frames as
//! `Shared/Doubao.swift`: a 4-byte header, a 4-byte big-endian payload size, the payload, uncompressed.

use std::time::{Duration, Instant};

use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio::{net::TcpStream, sync::mpsc::UnboundedReceiver, time::timeout};
use tokio_tungstenite::{
    connect_async,
    tungstenite::{self, client::IntoClientRequest, Message},
    MaybeTlsStream, WebSocketStream,
};

use super::{refused, Input, KayError};
use crate::i18n::t;

const URL: &str = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream";
/// Sold two ways; both use the same endpoint. The id, and its title in Settings.
pub const RESOURCES: [(&str, &str); 2] =
    [("volc.seedasr.sauc.duration", "Hourly"), ("volc.seedasr.sauc.concurrent", "Concurrent")];

type Socket = WebSocketStream<MaybeTlsStream<TcpStream>>;

fn message(status: Option<u16>, error: Option<&tungstenite::Error>) -> KayError {
    let message = match (status, error) {
        (Some(401), _) => t("Volcengine rejected this key. Make sure you copied the whole key from the new console."),
        (Some(403), _) => t("This key isn't enabled for Doubao Streaming ASR 2.0. Enable the service in the console, or switch the resource type."),
        (_, Some(tungstenite::Error::Io(_) | tungstenite::Error::Tls(_)) | None) => {
            t("Couldn't reach Volcengine. Check your network or proxy.")
        }
        (_, Some(e)) => e.to_string(),
    };
    KayError { message, status, detail: error.map(|e| e.to_string()) }
}

fn socket_error(error: tungstenite::Error) -> KayError {
    message(refused(&error), Some(&error))
}

fn malformed() -> KayError {
    KayError::new(t("Malformed response from Volcengine."))
}

/// Volcengine answers the upgrade itself: 401 for a key it doesn't know, 403 for a key whose account hasn't enabled
/// this resource (checked 2026-09-30 against the live endpoint).
async fn open(key: &str, resource: &str) -> Result<Socket, KayError> {
    let mut request = URL.into_client_request().map_err(socket_error)?;
    let headers = request.headers_mut();
    headers.insert("X-Api-Key", key.parse().map_err(|_| message(Some(401), None))?);
    headers.insert("X-Api-Resource-Id", resource.parse().map_err(|_| message(Some(403), None))?);
    headers.insert("X-Api-Connect-Id", uuid::Uuid::new_v4().to_string().parse().expect("a UUID is a header value"));
    let connected = timeout(Duration::from_secs(10), connect_async(request)).await;
    let (socket, _) = connected.map_err(|_| message(None, None))?.map_err(socket_error)?;
    Ok(socket)
}

/// Opens the dictation WebSocket and waits for the handshake, without sending audio.
pub async fn verify(key: &str, resource: &str) -> Result<u64, String> {
    let started = Instant::now();
    let mut socket = open(key, resource).await.map_err(|e| e.message)?;
    let _ = socket.close(None).await;
    Ok(started.elapsed().as_millis() as u64)
}

pub async fn run(key: &str, resource: &str, mut input: UnboundedReceiver<Input>) -> Result<String, KayError> {
    let (mut sink, mut stream) = open(key, resource).await?.split();
    let request = json!({
        "user": {"uid": "kay"},
        "audio": {"format": "pcm", "codec": "raw", "rate": 16000, "bits": 16, "channel": 1},
        "request": {"model_name": "bigmodel", "enable_itn": true, "enable_punc": true, "enable_ddc": true},
    });
    sink.send(Message::binary(frame(0b0001, 0, 0b0001, request.to_string().as_bytes()))).await.map_err(socket_error)?;
    let mut latest = String::new();
    let mut finishing = false;
    loop {
        tokio::select! {
            item = input.recv(), if !finishing => match item {
                Some(Input::Audio(pcm)) => sink.send(Message::binary(frame(0b0010, 0, 0, &pcm))).await.map_err(socket_error)?,
                // The last packet is flagged negative: the audio is over.
                Some(Input::Finish(pcm)) => {
                    sink.send(Message::binary(frame(0b0010, 0b0010, 0, &pcm))).await.map_err(socket_error)?;
                    finishing = true;
                }
                None => return Err(KayError::new("cancelled")),
            },
            message = stream.next() => match message {
                None | Some(Ok(Message::Close(_))) => return Err(self::message(None, None)),
                Some(Err(e)) => return Err(socket_error(e)),
                Some(Ok(Message::Binary(data))) => {
                    let (last, json) = parse(&data)?;
                    if let Some(text) = json.as_ref().and_then(|j| j["result"]["text"].as_str()) {
                        latest = text.to_string();
                    }
                    if last {
                        return Ok(latest);
                    }
                }
                Some(Ok(_)) => {}
            },
        }
    }
}

fn frame(kind: u8, flags: u8, serialization: u8, payload: &[u8]) -> Vec<u8> {
    let mut frame = vec![0x11, kind << 4 | flags, serialization << 4, 0x00];
    frame.extend((payload.len() as u32).to_be_bytes());
    frame.extend(payload);
    frame
}

/// Whether this is the last response, and its JSON. An error frame is the service's own failure.
fn parse(b: &[u8]) -> Result<(bool, Option<Value>), KayError> {
    let u32_at = |i: usize| b.get(i..i + 4).map(|s| u32::from_be_bytes(s.try_into().unwrap()));
    if b.len() < 4 {
        return Err(malformed());
    }
    let mut p = (b[0] & 0x0F) as usize * 4;
    let (kind, flags) = (b[1] >> 4, b[1] & 0x0F);
    if kind == 0b1111 {
        let (code, len) = (u32_at(p).ok_or_else(malformed)?, u32_at(p + 4).ok_or_else(malformed)? as usize);
        let text = String::from_utf8_lossy(&b[(p + 8).min(b.len())..(p + 8 + len).min(b.len())]);
        return Err(KayError {
            detail: Some(format!("Volcengine {code}: {text}")),
            ..KayError::new(t("Doubao ASR couldn't finish this dictation. Try again or check your Volcengine account."))
        });
    }
    if flags & 0b0001 != 0 {
        p += 4; // sequence number
    }
    let len = u32_at(p).ok_or_else(malformed)? as usize;
    if b[2] & 0x0F != 0 {
        return Err(malformed()); // compressed
    }
    let payload = &b[(p + 4).min(b.len())..(p + 4 + len).min(b.len())];
    let json = if payload.is_empty() { None } else { Some(serde_json::from_slice(payload).map_err(|_| malformed())?) };
    Ok((flags & 0b0010 != 0, json))
}
