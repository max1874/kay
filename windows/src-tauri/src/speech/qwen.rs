//! Qwen Audio 3.1 streaming ASR (Alibaba Cloud Model Studio), the same protocol as `Shared/Qwen.swift`: run-task,
//! audio after task-started, finish-task on release, and the final sentences joined at task-finished.

use std::{collections::HashMap, time::Duration, time::Instant};

use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio::{net::TcpStream, sync::mpsc::UnboundedReceiver, time::timeout};
use tokio_tungstenite::{
    connect_async,
    tungstenite::{self, client::IntoClientRequest, http::Uri, Message},
    MaybeTlsStream, WebSocketStream,
};

use super::{refused, Input, KayError};
use crate::i18n::t;

pub const MODEL: &str = "qwen-audio-3.1-asr-flash-streaming";
pub const DEFAULT_WORKSPACE_URL: &str = "https://dashscope.aliyuncs.com";
const START: Duration = Duration::from_secs(15);

type Socket = WebSocketStream<MaybeTlsStream<TcpStream>>;

/// The inference WebSocket of an official workspace URL, which is all a key is ever sent to.
pub fn endpoint(value: &str) -> Option<String> {
    let uri: Uri = value.trim().parse().ok()?;
    let scheme = uri.scheme_str()?.to_ascii_lowercase();
    let authority = uri.authority()?;
    let host = authority.host().to_ascii_lowercase();
    let plain = ["https", "wss"].contains(&scheme.as_str())
        && !authority.as_str().contains('@')
        && authority.port().is_none()
        && uri.query().is_none()
        && ["", "/", "/api-ws/v1/inference"].contains(&uri.path());
    let official = host == "dashscope.aliyuncs.com"
        || host == "dashscope-intl.aliyuncs.com"
        || host.ends_with(".cn-beijing.maas.aliyuncs.com")
        || host.ends_with(".ap-southeast-1.maas.aliyuncs.com");
    (plain && official).then(|| format!("wss://{host}/api-ws/v1/inference"))
}

fn connection(status: Option<u16>) -> KayError {
    let message = match status {
        Some(401) => t("Alibaba Cloud rejected this key. Copy the full API key for this workspace."),
        Some(403) => t("This key can't use Qwen ASR in this workspace. Check the key, workspace and service access."),
        // Never request headers, payloads or protocol diagnostics in the HUD.
        _ => t("Couldn't reach Alibaba Cloud. Check your network and workspace URL."),
    };
    KayError { message, status, detail: None }
}

fn socket_error(error: tungstenite::Error) -> KayError {
    KayError { detail: Some(error.to_string()), ..connection(refused(&error)) }
}

fn service(code: &str, message: &str) -> KayError {
    let lower = code.to_lowercase();
    let error = if ["auth", "apikey", "api_key"].iter().any(|s| lower.contains(s)) {
        connection(Some(401))
    } else if ["permission", "accessdenied", "forbidden"].iter().any(|s| lower.contains(s)) {
        connection(Some(403))
    } else if lower.contains("limit") || lower.contains("quota") {
        KayError::new(t("Qwen ASR is busy or your quota is exhausted. Check your Alibaba Cloud account and try again."))
    } else {
        KayError::new(t("Qwen ASR couldn't finish this dictation. Try again or check your Alibaba Cloud account."))
    };
    KayError { detail: Some(format!("Qwen {code}: {message}")), ..error }
}

fn unreadable() -> KayError {
    KayError::new(t("Alibaba Cloud returned an unreadable response."))
}

enum Event {
    Started,
    Sentence { id: i64, begin: i64, text: String, end: bool },
    Finished,
    Other,
}

/// Connects and starts the task: on task-started the key, workspace and model access are known to work.
async fn open(key: &str, workspace: &str, task: &str) -> Result<Socket, KayError> {
    let url = endpoint(workspace).ok_or_else(|| KayError::new(t("Enter the Alibaba Cloud workspace URL from the console.")))?;
    let mut request = url.into_client_request().map_err(socket_error)?;
    let bearer = format!("Bearer {key}").parse().map_err(|_| connection(Some(401)))?;
    request.headers_mut().insert("Authorization", bearer);
    let (mut socket, _) = connect_async(request).await.map_err(socket_error)?;
    let start = json!({
        "header": {"action": "run-task", "task_id": task, "streaming": "duplex"},
        "payload": {"task_group": "audio", "task": "asr", "function": "recognition", "model": MODEL,
                    "parameters": {"format": "pcm", "sample_rate": 16000}, "input": {}},
    });
    socket.send(Message::text(start.to_string())).await.map_err(socket_error)?;
    loop {
        if let Event::Started = event(socket.next().await, task)? {
            return Ok(socket);
        }
    }
}

async fn open_in_time(key: &str, workspace: &str, task: &str) -> Result<Socket, KayError> {
    timeout(START, open(key, workspace, task)).await.unwrap_or_else(|_| {
        Err(KayError::new(t("Couldn't start Qwen ASR. Check your network and workspace URL.")))
    })
}

/// How long task-started took, without sending any microphone audio.
pub async fn verify(key: &str, workspace: &str) -> Result<u64, String> {
    let started = Instant::now();
    let mut socket = open_in_time(key, workspace, &uuid::Uuid::new_v4().to_string()).await.map_err(|e| e.message)?;
    let _ = socket.close(None).await;
    Ok(started.elapsed().as_millis() as u64)
}

pub async fn run(key: &str, workspace: &str, mut input: UnboundedReceiver<Input>) -> Result<String, KayError> {
    let task = uuid::Uuid::new_v4().to_string();
    let (mut sink, mut stream) = open_in_time(key, workspace, &task).await?.split();
    let mut sentences: HashMap<i64, (i64, String, bool)> = HashMap::new();
    let mut finishing = false;
    loop {
        tokio::select! {
            item = input.recv(), if !finishing => match item {
                Some(Input::Audio(pcm)) => sink.send(Message::binary(pcm)).await.map_err(socket_error)?,
                Some(Input::Finish(pcm)) => {
                    if !pcm.is_empty() {
                        sink.send(Message::binary(pcm)).await.map_err(socket_error)?;
                    }
                    let end = json!({"header": {"action": "finish-task", "task_id": task, "streaming": "duplex"},
                                     "payload": {"input": {}}});
                    sink.send(Message::text(end.to_string())).await.map_err(socket_error)?;
                    finishing = true;
                }
                None => return Err(KayError::new("cancelled")),
            },
            message = stream.next() => match event(message, &task)? {
                Event::Sentence { id, begin, text, end } => {
                    // A final sentence is never revised back.
                    if !(sentences.get(&id).is_some_and(|s| s.2) && !end) {
                        sentences.insert(id, (begin, text, end));
                    }
                }
                Event::Finished => {
                    if !finishing || sentences.values().any(|(_, text, end)| !text.trim().is_empty() && !end) {
                        return Err(unreadable());
                    }
                    return Ok(join(sentences));
                }
                Event::Started | Event::Other => {}
            },
        }
    }
}

/// By start time; a space only between a Latin word and the next.
fn join(sentences: HashMap<i64, (i64, String, bool)>) -> String {
    let mut ordered: Vec<_> = sentences.into_iter().collect();
    ordered.sort_by_key(|(id, (begin, _, _))| (*begin, *id));
    let mut text = String::new();
    for (_, (_, sentence, _)) in ordered {
        if let (Some(last), Some(first)) = (text.chars().last(), sentence.chars().next()) {
            if last.is_ascii() && !last.is_whitespace() && first.is_ascii_alphabetic() {
                text.push(' ');
            }
        }
        text.push_str(&sentence);
    }
    text
}

fn event(message: Option<Result<Message, tungstenite::Error>>, task: &str) -> Result<Event, KayError> {
    let json: Value = match message {
        None | Some(Ok(Message::Close(_))) => return Err(connection(None)),
        Some(Err(e)) => return Err(socket_error(e)),
        Some(Ok(Message::Text(text))) => serde_json::from_str(text.as_str()).map_err(|_| unreadable())?,
        Some(Ok(Message::Binary(data))) => serde_json::from_slice(&data).map_err(|_| unreadable())?,
        Some(Ok(_)) => return Ok(Event::Other),
    };
    let header = &json["header"];
    if header["task_id"].as_str() != Some(task) {
        return Err(unreadable());
    }
    Ok(match header["event"].as_str().ok_or_else(unreadable)? {
        "task-started" => Event::Started,
        "task-finished" => Event::Finished,
        "task-failed" => {
            return Err(service(header["error_code"].as_str().unwrap_or(""), header["error_message"].as_str().unwrap_or("")))
        }
        "result-generated" => {
            let sentence = &json["payload"]["output"]["sentence"];
            if sentence.is_null() || sentence["heartbeat"].as_bool() == Some(true) {
                return Ok(Event::Other);
            }
            Event::Sentence {
                id: sentence["sentence_id"].as_i64().ok_or_else(unreadable)?,
                begin: sentence["begin_time"].as_i64().unwrap_or(0),
                text: sentence["text"].as_str().ok_or_else(unreadable)?.to_string(),
                end: sentence["sentence_end"].as_bool() == Some(true),
            }
        }
        _ => Event::Other,
    })
}
