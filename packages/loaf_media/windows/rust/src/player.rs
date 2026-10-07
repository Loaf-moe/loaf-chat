//! One inline video: Media Foundation's Media Engine in frame-server mode,
//! reading through [LoafByteStream], with a thread that copies each new
//! frame into a shared D3D11 texture Flutter draws. Controls are Flutter's;
//! this only plays, pauses, seeks, mutes and reports.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use loaf_streams::Reader;
use windows::Win32::Foundation::{HANDLE, HMODULE, RECT, S_OK};
use windows::Win32::Graphics::Direct3D::{D3D_DRIVER_TYPE_HARDWARE, D3D_DRIVER_TYPE_WARP};
use windows::Win32::Graphics::Direct3D11::{
    D3D11_BIND_RENDER_TARGET, D3D11_BIND_SHADER_RESOURCE, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
    D3D11_CREATE_DEVICE_VIDEO_SUPPORT, D3D11_RESOURCE_MISC_SHARED, D3D11_SDK_VERSION,
    D3D11_TEXTURE2D_DESC, D3D11_USAGE_DEFAULT, D3D11CreateDevice, ID3D11Device,
    ID3D11DeviceContext, ID3D11Multithread, ID3D11Texture2D,
};
use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_SAMPLE_DESC};
use windows::Win32::Graphics::Dxgi::{IDXGIDevice, IDXGIOutput, IDXGIResource};
use windows::Win32::Media::MediaFoundation::{
    CLSID_MFMediaEngineClassFactory, IMFAttributes, IMFByteStream, IMFDXGIDeviceManager,
    IMFMediaEngine, IMFMediaEngineClassFactory, IMFMediaEngineEx, IMFMediaEngineNotify,
    IMFMediaEngineNotify_Impl, MF_MEDIA_ENGINE_CALLBACK, MF_MEDIA_ENGINE_DXGI_MANAGER,
    MF_MEDIA_ENGINE_EVENT_CANPLAY, MF_MEDIA_ENGINE_EVENT_ENDED, MF_MEDIA_ENGINE_EVENT_ERROR,
    MF_MEDIA_ENGINE_EVENT_FIRSTFRAMEREADY, MF_MEDIA_ENGINE_EVENT_LOADEDMETADATA,
    MF_MEDIA_ENGINE_EVENT_PAUSE, MF_MEDIA_ENGINE_EVENT_PLAYING,
    MF_MEDIA_ENGINE_VIDEO_OUTPUT_FORMAT, MF_VERSION, MFCreateAttributes, MFCreateDXGIDeviceManager,
    MFSTARTUP_FULL, MFStartup,
};
use windows::Win32::System::Com::{
    CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx, CoUninitialize,
};
use windows_core::{BSTR, Interface, implement};

use crate::byte_stream::LoafByteStream;

pub type FrameCallback = extern "C" fn(user: *mut std::ffi::c_void);

/// Starts Media Foundation once per process. Later calls give the first
/// call's outcome.
pub fn init() -> Result<(), String> {
    static INIT: OnceLock<Result<(), String>> = OnceLock::new();
    INIT.get_or_init(|| {
        // SAFETY: plain startup call; never shut down while the app runs.
        unsafe { MFStartup(MF_VERSION, MFSTARTUP_FULL) }.map_err(|e| format!("MFStartup: {e}"))
    })
    .clone()
}

/// A texture Flutter can open by its handle, lent out as an Arc: while
/// Flutter holds one, the render thread writes a different one.
pub struct Frame {
    texture: ID3D11Texture2D,
    pub handle: HANDLE,
    pub width: u32,
    pub height: u32,
}
// SAFETY: D3D11 textures are free-threaded objects, and the device is
// multithread-protected.
unsafe impl Send for Frame {}
unsafe impl Sync for Frame {}

/// What the engine's events and the render thread tell the plugin.
struct Shared {
    ready: AtomicBool,
    error: AtomicBool,
    ended: AtomicBool,
    newest: Mutex<Option<Arc<Frame>>>,
    on_frame: FrameCallback,
    user: UserPtr,
}

#[derive(Clone, Copy)]
struct UserPtr(*mut std::ffi::c_void);
// SAFETY: the plugin keeps [user] valid until the player is freed, and the
// callback is written to be called from any thread.
unsafe impl Send for UserPtr {}
unsafe impl Sync for UserPtr {}

impl Shared {
    fn changed(&self) {
        (self.on_frame)(self.user.0);
    }
}

#[implement(IMFMediaEngineNotify)]
struct Notify(Arc<Shared>);

impl IMFMediaEngineNotify_Impl for Notify_Impl {
    fn EventNotify(&self, event: u32, _: usize, _: u32) -> windows_core::Result<()> {
        let event = event as i32;
        let shared = &self.0;
        if event == MF_MEDIA_ENGINE_EVENT_ERROR.0 {
            shared.error.store(true, Ordering::SeqCst);
        } else if event == MF_MEDIA_ENGINE_EVENT_CANPLAY.0
            || event == MF_MEDIA_ENGINE_EVENT_FIRSTFRAMEREADY.0
            || event == MF_MEDIA_ENGINE_EVENT_LOADEDMETADATA.0
        {
            if event != MF_MEDIA_ENGINE_EVENT_LOADEDMETADATA.0 {
                shared.ready.store(true, Ordering::SeqCst);
            }
        } else if event == MF_MEDIA_ENGINE_EVENT_ENDED.0 {
            shared.ended.store(true, Ordering::SeqCst);
        } else if event == MF_MEDIA_ENGINE_EVENT_PLAYING.0 {
            shared.ended.store(false, Ordering::SeqCst);
        } else if event != MF_MEDIA_ENGINE_EVENT_PAUSE.0 {
            return Ok(());
        }
        shared.changed();
        Ok(())
    }
}

/// Free-threaded COM objects, moved to the render thread.
struct Agile<T>(T);
// SAFETY: the Media Engine and D3D11 (multithread-protected) are
// free-threaded.
unsafe impl<T> Send for Agile<T> {}

pub struct Player {
    engine: IMFMediaEngine,
    stream: IMFByteStream,
    shared: Arc<Shared>,
    stop: Arc<AtomicBool>,
    render: Option<JoinHandle<()>>,
}

// SAFETY: the Media Engine and byte stream are free-threaded COM objects,
// and the rest is Arcs and a join handle. The plugin may free a player on a
// different thread from the one that made it.
unsafe impl Send for Player {}

pub struct PlayerState {
    pub position_ms: i64,
    pub duration_ms: i64,
    pub playing: bool,
    pub error: bool,
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

impl Player {
    /// Loads `loaf-media://<id>` paused. [extension] (`mp4`, `mov`…) names
    /// the container for Media Foundation's source resolver.
    pub fn new(
        reader: Reader,
        id: &str,
        extension: &str,
        on_frame: FrameCallback,
        user: *mut std::ffi::c_void,
    ) -> windows_core::Result<Player> {
        let shared = Arc::new(Shared {
            ready: AtomicBool::new(false),
            error: AtomicBool::new(false),
            ended: AtomicBool::new(false),
            newest: Mutex::new(None),
            on_frame,
            user: UserPtr(user),
        });
        // SAFETY: COM and D3D calls with live arguments throughout.
        unsafe {
            // A GPU when there is one; WARP, Windows' own software device,
            // in a VM or on a CI runner with none.
            let (mut device, mut context) = (None, None);
            let mut created = Err(windows::Win32::Foundation::E_FAIL.into());
            for driver in [D3D_DRIVER_TYPE_HARDWARE, D3D_DRIVER_TYPE_WARP] {
                created = D3D11CreateDevice(
                    None,
                    driver,
                    HMODULE::default(),
                    D3D11_CREATE_DEVICE_VIDEO_SUPPORT | D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                    None,
                    D3D11_SDK_VERSION,
                    Some(&mut device),
                    None,
                    Some(&mut context),
                );
                if created.is_ok() {
                    break;
                }
            }
            created?;
            let device: ID3D11Device = device.ok_or(windows::Win32::Foundation::E_FAIL)?;
            let context: ID3D11DeviceContext = context.ok_or(windows::Win32::Foundation::E_FAIL)?;
            // The engine decodes on its threads while ours copies frames.
            // Returns the old setting, which doesn't matter here.
            let _ = device
                .cast::<ID3D11Multithread>()?
                .SetMultithreadProtected(true);

            let mut token = 0;
            let mut manager: Option<IMFDXGIDeviceManager> = None;
            MFCreateDXGIDeviceManager(&mut token, &mut manager)?;
            let manager = manager.ok_or(windows::Win32::Foundation::E_FAIL)?;
            manager.ResetDevice(&device, token)?;

            let mut attributes: Option<IMFAttributes> = None;
            MFCreateAttributes(&mut attributes, 3)?;
            let attributes = attributes.ok_or(windows::Win32::Foundation::E_FAIL)?;
            let notify: IMFMediaEngineNotify = Notify(shared.clone()).into();
            attributes.SetUnknown(&MF_MEDIA_ENGINE_CALLBACK, &notify)?;
            attributes.SetUnknown(&MF_MEDIA_ENGINE_DXGI_MANAGER, &manager)?;
            attributes.SetUINT32(
                &MF_MEDIA_ENGINE_VIDEO_OUTPUT_FORMAT,
                DXGI_FORMAT_B8G8R8A8_UNORM.0 as u32,
            )?;

            let factory: IMFMediaEngineClassFactory =
                CoCreateInstance(&CLSID_MFMediaEngineClassFactory, None, CLSCTX_INPROC_SERVER)?;
            // No window: frame-server mode, frames taken by TransferVideoFrame.
            let engine = factory.CreateInstance(0, &attributes)?;
            let stream = LoafByteStream::create(reader);
            let url = BSTR::from(format!("loaf-media://{id}/video.{extension}"));
            engine
                .cast::<IMFMediaEngineEx>()?
                .SetSourceFromByteStream(&stream, &url)?;

            let stop = Arc::new(AtomicBool::new(false));
            let render = {
                let (engine, device, context) =
                    (Agile(engine.clone()), Agile(device), Agile(context));
                let (shared, stop) = (shared.clone(), stop.clone());
                thread::spawn(move || render_loop(engine, device, context, shared, stop))
            };
            Ok(Player {
                engine,
                stream,
                shared,
                stop,
                render: Some(render),
            })
        }
    }

    pub fn play(&self) -> windows_core::Result<()> {
        // SAFETY: a live engine.
        unsafe { self.engine.Play() }
    }

    pub fn pause(&self) -> windows_core::Result<()> {
        // SAFETY: a live engine.
        unsafe { self.engine.Pause() }
    }

    pub fn seek(&self, ms: i64) -> windows_core::Result<()> {
        self.shared.ended.store(false, Ordering::SeqCst);
        // SAFETY: a live engine.
        unsafe { self.engine.SetCurrentTime(ms.max(0) as f64 / 1000.0) }
    }

    pub fn set_muted(&self, muted: bool) -> windows_core::Result<()> {
        // SAFETY: a live engine.
        unsafe { self.engine.SetMuted(muted) }
    }

    pub fn ready(&self) -> bool {
        self.shared.ready.load(Ordering::SeqCst)
    }

    pub fn failed(&self) -> bool {
        self.shared.error.load(Ordering::SeqCst)
    }

    pub fn state(&self) -> PlayerState {
        // SAFETY: a live engine.
        let (position, duration, paused) = unsafe {
            (
                self.engine.GetCurrentTime(),
                self.engine.GetDuration(),
                self.engine.IsPaused().as_bool(),
            )
        };
        let ms = |s: f64| {
            if s.is_finite() && s >= 0.0 {
                (s * 1000.0) as i64
            } else {
                -1
            }
        };
        PlayerState {
            position_ms: ms(position),
            duration_ms: ms(duration),
            playing: !paused && !self.shared.ended.load(Ordering::SeqCst),
            error: self.failed(),
        }
    }

    /// The newest frame, as the caller's own reference.
    pub fn take_frame(&self) -> Option<Arc<Frame>> {
        lock(&self.shared.newest).clone()
    }
}

impl Drop for Player {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        // SAFETY: COM calls on live objects. Closing the stream wakes a
        // read waiting on a download, so Shutdown can't hang on it.
        unsafe {
            let _ = self.stream.Close();
            let _ = self.engine.Shutdown();
        }
        if let Some(render) = self.render.take() {
            let _ = render.join();
        }
    }
}

/// How many textures a player may have: one Flutter draws, one being
/// written, and room for Flutter to hold an old one a little longer.
const POOL: usize = 4;

fn render_loop(
    engine: Agile<IMFMediaEngine>,
    device: Agile<ID3D11Device>,
    context: Agile<ID3D11DeviceContext>,
    shared: Arc<Shared>,
    stop: Arc<AtomicBool>,
) {
    let (engine, device, context) = (engine.0, device.0, context.0);
    // SAFETY: balanced at the end of this function.
    let com = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
    // Paced by the display the device draws to, as the engine expects in
    // frame-server mode. A machine with no display (CI) ticks at 60 Hz.
    let output = vblank_output(&device);
    let mut pool: Vec<Arc<Frame>> = Vec::new();

    while !stop.load(Ordering::SeqCst) {
        match &output {
            // SAFETY: a live output.
            Some(output) if unsafe { output.WaitForVBlank() }.is_ok() => {}
            _ => thread::sleep(Duration::from_millis(16)),
        }
        let mut pts = 0i64;
        // S_FALSE means no new frame; the wrapper can't tell it from S_OK.
        // SAFETY: the vtable call the wrapper makes, keeping the HRESULT.
        let hr = unsafe {
            (Interface::vtable(&engine).OnVideoStreamTick)(Interface::as_raw(&engine), &mut pts)
        };
        if hr != S_OK {
            continue;
        }
        let (mut width, mut height) = (0u32, 0u32);
        // SAFETY: a live engine.
        if unsafe { engine.GetNativeVideoSize(Some(&mut width), Some(&mut height)) }.is_err()
            || width == 0
            || height == 0
        {
            continue;
        }
        let Some(frame) = free_frame(&device, &mut pool, &shared, width, height) else {
            continue;
        };
        let rect = RECT {
            left: 0,
            top: 0,
            right: width as i32,
            bottom: height as i32,
        };
        // SAFETY: a live engine and texture; the device is protected.
        let copied = unsafe {
            let copied = engine.TransferVideoFrame(&frame.texture, None, &rect, None);
            context.Flush();
            copied
        };
        if copied.is_ok() {
            *lock(&shared.newest) = Some(frame);
            shared.changed();
        }
    }
    drop(pool);
    if com.is_ok() {
        // SAFETY: paired with the CoInitializeEx above.
        unsafe { CoUninitialize() };
    }
}

fn vblank_output(device: &ID3D11Device) -> Option<IDXGIOutput> {
    // SAFETY: COM calls on a live device.
    unsafe {
        let adapter = device.cast::<IDXGIDevice>().ok()?.GetAdapter().ok()?;
        adapter.EnumOutputs(0).ok()
    }
}

/// A texture of this size nobody else holds (not Flutter, not the newest
/// frame), made if there's room in the pool.
fn free_frame(
    device: &ID3D11Device,
    pool: &mut Vec<Arc<Frame>>,
    shared: &Shared,
    width: u32,
    height: u32,
) -> Option<Arc<Frame>> {
    // A resize drops old sizes, except any Flutter is still drawing.
    pool.retain(|f| (f.width == width && f.height == height) || Arc::strong_count(f) > 1);
    let newest = lock(&shared.newest).clone();
    if let Some(free) = pool.iter().find(|f| {
        f.width == width
            && f.height == height
            && !newest.as_ref().is_some_and(|n| Arc::ptr_eq(n, f))
            && Arc::strong_count(f) == 1
    }) {
        return Some(free.clone());
    }
    if pool.len() >= POOL {
        return None;
    }
    let frame = Arc::new(new_frame(device, width, height).ok()?);
    pool.push(frame.clone());
    Some(frame)
}

fn new_frame(device: &ID3D11Device, width: u32, height: u32) -> windows_core::Result<Frame> {
    let desc = D3D11_TEXTURE2D_DESC {
        Width: width,
        Height: height,
        MipLevels: 1,
        ArraySize: 1,
        Format: DXGI_FORMAT_B8G8R8A8_UNORM,
        SampleDesc: DXGI_SAMPLE_DESC {
            Count: 1,
            Quality: 0,
        },
        Usage: D3D11_USAGE_DEFAULT,
        BindFlags: (D3D11_BIND_RENDER_TARGET.0 | D3D11_BIND_SHADER_RESOURCE.0) as u32,
        CPUAccessFlags: 0,
        // A legacy shared handle: what ANGLE opens for Flutter.
        MiscFlags: D3D11_RESOURCE_MISC_SHARED.0 as u32,
    };
    // SAFETY: COM calls on a live device with a valid description.
    unsafe {
        let mut texture = None;
        device.CreateTexture2D(&desc, None, Some(&mut texture))?;
        let texture: ID3D11Texture2D = texture.ok_or(windows::Win32::Foundation::E_FAIL)?;
        let handle = texture.cast::<IDXGIResource>()?.GetSharedHandle()?;
        Ok(Frame {
            texture,
            handle,
            width,
            height,
        })
    }
}
