//! The microphone, as 16 kHz / 16-bit mono PCM in 200 ms packets: what both speech services take.
//!
//! WASAPI in shared mode converts to that format itself (AUTOCONVERTPCM), so Kay never resamples. Each recording
//! starts on a thread of its own and is given up after a timeout: on the Mac, Core Audio once hung for good while a
//! recording started (2026-10-09), and the thread that waited went with it.

use std::{
    sync::{
        atomic::{AtomicBool, AtomicUsize, Ordering},
        mpsc, Arc,
    },
    thread,
    time::Duration,
};

use windows::{
    core::{HSTRING, PWSTR},
    Win32::{
        Devices::FunctionDiscovery::PKEY_Device_FriendlyName,
        Foundation::{CloseHandle, E_ACCESSDENIED, PROPERTYKEY, WAIT_OBJECT_0},
        Media::Audio::*,
        System::{
            Com::{
                CoCreateInstance, CoInitializeEx, CoTaskMemFree,
                StructuredStorage::{PropVariantClear, PropVariantToStringAlloc, PropVariantToUInt32},
                CLSCTX_ALL, COINIT_MULTITHREADED, STGM_READ,
            },
            Threading::{CreateEventW, WaitForSingleObject},
        },
    },
};

use crate::{i18n::t, speech::KayError};

pub const SAMPLE_RATE: usize = 16_000;
pub const CHUNK_BYTES: usize = SAMPLE_RATE * 2 / 5;
/// Samples per level reading: 20 a second, which drives the HUD's bars.
const LEVEL_SAMPLES: usize = SAMPLE_RATE / 20;

#[derive(Clone, serde::Serialize)]
pub struct Device {
    pub id: String,
    pub name: String,
}

/// COM for the calling thread; every thread that calls in here is Kay's own, and none of them has a UI.
pub fn com() {
    let _ = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
}

fn enumerator() -> windows::core::Result<IMMDeviceEnumerator> {
    com();
    unsafe { CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL) }
}

/// Every microphone that is plugged in and enabled.
pub fn microphones() -> Vec<Device> {
    let Ok(enumerator) = enumerator() else { return vec![] };
    unsafe {
        let Ok(collection) = enumerator.EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE) else { return vec![] };
        let count = collection.GetCount().unwrap_or(0);
        (0..count).filter_map(|i| collection.Item(i).ok()).filter_map(|d| describe(&d)).collect()
    }
}

pub fn default_microphone() -> Option<Device> {
    unsafe { describe(&enumerator().ok()?.GetDefaultAudioEndpoint(eCapture, eConsole).ok()?) }
}

/// The default output's name when it is headphones or a headset, wired or Bluetooth: the microphone doesn't hear
/// them, so what plays can keep playing. Everything else is the room: speakers, a monitor's, HDMI.
pub fn headphones() -> Option<String> {
    unsafe {
        let device = enumerator().ok()?.GetDefaultAudioEndpoint(eRender, eConsole).ok()?;
        let form = property(&device, &PKEY_AudioEndpoint_FormFactor, |v| PropVariantToUInt32(v).ok())?;
        (form == Headphones.0 as u32 || form == Headset.0 as u32)
            .then(|| describe(&device).map(|d| d.name).unwrap_or_else(|| "headphones".into()))
    }
}

/// Whether Windows lets desktop apps use the microphone (Settings → Privacy & security → Microphone). When it doesn't,
/// a recording starts and hears only silence, so this is read before each one.
pub fn microphone_allowed() -> bool {
    use winreg::{enums::{HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE}, RegKey};
    const STORE: &str = r"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";
    let denied = |root, path: &str| {
        RegKey::predef(root).open_subkey(path).and_then(|k| k.get_value::<String, _>("Value")).is_ok_and(|v| v == "Deny")
    };
    !(denied(HKEY_LOCAL_MACHINE, STORE) || denied(HKEY_CURRENT_USER, STORE) || denied(HKEY_CURRENT_USER, &format!(r"{STORE}\NonPackaged")))
}

/// A headset's microphone, Bluetooth ones especially, may first have to switch profiles: it gets longer to start.
pub fn is_headset(id: &str) -> bool {
    unsafe {
        let Some(device) = enumerator().ok().and_then(|e| e.GetDevice(&HSTRING::from(id)).ok()) else { return false };
        property(&device, &PKEY_AudioEndpoint_FormFactor, |v| PropVariantToUInt32(v).ok())
            .is_some_and(|form| form == Headset.0 as u32 || form == Handset.0 as u32)
    }
}

unsafe fn describe(device: &IMMDevice) -> Option<Device> {
    let id = owned(device.GetId().ok()?)?;
    let name = property(device, &PKEY_Device_FriendlyName, |v| PropVariantToStringAlloc(v).ok().and_then(|s| owned(s)))
        .unwrap_or_else(|| id.clone());
    Some(Device { id, name })
}

unsafe fn property<T>(
    device: &IMMDevice,
    key: &PROPERTYKEY,
    read: impl FnOnce(&windows::Win32::System::Com::StructuredStorage::PROPVARIANT) -> Option<T>,
) -> Option<T> {
    let store = device.OpenPropertyStore(STGM_READ).ok()?;
    let mut value = store.GetValue(key).ok()?;
    let result = read(&value);
    let _ = PropVariantClear(&mut value);
    result
}

/// A string COM allocated, as a String, freed.
unsafe fn owned(s: PWSTR) -> Option<String> {
    let value = s.to_string().ok();
    CoTaskMemFree(Some(s.0 as *const _));
    value
}

/// A recording in progress. Stop it with `stop`, which hands back the audio not yet sent as a packet.
pub struct Capture {
    stop: Arc<AtomicBool>,
    rest: mpsc::Receiver<Vec<u8>>,
    recorded: Arc<AtomicUsize>,
}

impl Capture {
    /// Records from microphone `id`, calling `on_chunk` with each 200 ms packet and `on_level` with the loudness,
    /// 0…1, about 20 times a second; both on the recording thread. Fails if the microphone doesn't start within
    /// `timeout`.
    pub fn start(
        id: &str,
        timeout: Duration,
        mut on_chunk: impl FnMut(Vec<u8>) + Send + 'static,
        mut on_level: impl FnMut(f32) + Send + 'static,
    ) -> Result<Capture, KayError> {
        let stop = Arc::new(AtomicBool::new(false));
        let recorded = Arc::new(AtomicUsize::new(0));
        let (started_tx, started) = mpsc::channel();
        let (rest_tx, rest) = mpsc::channel();
        let (id, stopped, bytes) = (id.to_string(), stop.clone(), recorded.clone());
        thread::Builder::new()
            .name("kay-audio".into())
            .spawn(move || unsafe {
                let stream = match Stream::open(&id) {
                    Ok(stream) => stream,
                    Err(e) => return drop(started_tx.send(Err(e))),
                };
                let _ = started_tx.send(Ok(()));
                let mut buffer = Vec::with_capacity(CHUNK_BYTES * 2);
                let mut level = Level::default();
                // Also when the caller gave up waiting, which set `stopped`: a start that went through after all is
                // not the dictation's audio.
                while !stopped.load(Ordering::Relaxed) {
                    if WaitForSingleObject(stream.event, 100) != WAIT_OBJECT_0 {
                        continue;
                    }
                    stream.drain(|samples| {
                        if let Some(value) = level.add(samples) {
                            on_level(value);
                        }
                        buffer.extend(samples.iter().flat_map(|s| s.to_le_bytes()));
                        bytes.fetch_add(samples.len() * 2, Ordering::Relaxed);
                        while buffer.len() >= CHUNK_BYTES {
                            on_chunk(buffer.drain(..CHUNK_BYTES).collect());
                        }
                    });
                }
                drop(stream);
                let _ = rest_tx.send(buffer);
            })
            .map_err(|e| KayError::new(e.to_string()))?;
        match started.recv_timeout(timeout) {
            Ok(Ok(())) => Ok(Capture { stop, rest, recorded }),
            Ok(Err(e)) => Err(e),
            Err(_) => {
                stop.store(true, Ordering::Relaxed);
                Err(KayError::new(t("The microphone didn't respond.")))
            }
        }
    }

    /// Stops recording. Returns the audio not yet sent as a packet, and how much was recorded in all, which is what
    /// Volcengine bills by.
    pub fn stop(self) -> (Vec<u8>, f64) {
        self.stop.store(true, Ordering::Relaxed);
        // The thread wakes at least every 100 ms.
        let rest = self.rest.recv_timeout(Duration::from_millis(500)).unwrap_or_default();
        (rest, self.recorded.load(Ordering::Relaxed) as f64 / (SAMPLE_RATE * 2) as f64)
    }
}

impl Drop for Capture {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

struct Stream {
    client: IAudioClient,
    capture: IAudioCaptureClient,
    event: windows::Win32::Foundation::HANDLE,
}

impl Stream {
    unsafe fn open(id: &str) -> Result<Stream, KayError> {
        let failed = |e: windows::core::Error| {
            if e.code() == E_ACCESSDENIED {
                KayError::new(t("Kay can't use the microphone. Allow it in Windows Settings."))
            } else {
                KayError::new(e.message())
            }
        };
        let device = enumerator().and_then(|e| e.GetDevice(&HSTRING::from(id))).map_err(failed)?;
        let client: IAudioClient = device.Activate(CLSCTX_ALL, None).map_err(failed)?;
        let format = WAVEFORMATEX {
            wFormatTag: WAVE_FORMAT_PCM as u16,
            nChannels: 1,
            nSamplesPerSec: SAMPLE_RATE as u32,
            nAvgBytesPerSec: SAMPLE_RATE as u32 * 2,
            nBlockAlign: 2,
            wBitsPerSample: 16,
            cbSize: 0,
        };
        let flags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK
            | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM
            | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
        // A 200 ms buffer, in 100 ns units.
        client.Initialize(AUDCLNT_SHAREMODE_SHARED, flags, 2_000_000, 0, &format, None).map_err(failed)?;
        let event = CreateEventW(None, false, false, None).map_err(failed)?;
        let stream = Stream { capture: client.GetService().map_err(failed)?, client, event };
        stream.client.SetEventHandle(event).map_err(failed)?;
        stream.client.Start().map_err(failed)?;
        Ok(stream)
    }

    /// Hands every packet waiting to `take`, silence as zeros.
    unsafe fn drain(&self, mut take: impl FnMut(&[i16])) {
        while self.capture.GetNextPacketSize().unwrap_or(0) > 0 {
            let (mut data, mut frames, mut flags) = (std::ptr::null_mut(), 0u32, 0u32);
            if self.capture.GetBuffer(&mut data, &mut frames, &mut flags, None, None).is_err() {
                return;
            }
            if flags & AUDCLNT_BUFFERFLAGS_SILENT.0 as u32 != 0 || data.is_null() {
                take(&vec![0; frames as usize]);
            } else {
                take(std::slice::from_raw_parts(data as *const i16, frames as usize));
            }
            let _ = self.capture.ReleaseBuffer(frames);
        }
    }
}

impl Drop for Stream {
    fn drop(&mut self) {
        unsafe {
            let _ = self.client.Stop();
            let _ = CloseHandle(self.event);
        }
    }
}

/// RMS on a log scale over `LEVEL_SAMPLES`, so ordinary speech fills most of the range instead of a sliver of it.
#[derive(Default)]
struct Level {
    sum: f32,
    count: usize,
}

impl Level {
    fn add(&mut self, samples: &[i16]) -> Option<f32> {
        for &s in samples {
            let v = s as f32 / i16::MAX as f32;
            self.sum += v * v;
        }
        self.count += samples.len();
        if self.count < LEVEL_SAMPLES {
            return None;
        }
        let db = 20.0 * (self.sum / self.count as f32).sqrt().max(1e-5).log10();
        *self = Level::default();
        Some(((db + 55.0) / 45.0).clamp(0.0, 1.0)) // -55 dB → 0, -10 dB → 1
    }
}
