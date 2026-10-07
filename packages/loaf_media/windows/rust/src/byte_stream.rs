//! Media Foundation's own hook for reading media from somewhere other than
//! a URL it understands: an `IMFByteStream`. This one reads a download as it
//! arrives, through `loaf_streams`. A read past what has arrived waits for
//! the bytes, and fails if the download does.

use std::collections::HashMap;
use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Mutex, PoisonError};
use std::thread;

use loaf_streams::{ReadError, Reader};
use windows::Win32::Foundation::{E_FAIL, E_INVALIDARG, E_NOTIMPL, E_POINTER, S_OK};
use windows::Win32::Media::MediaFoundation::{
    IMFAsyncCallback, IMFAsyncResult, IMFByteStream, IMFByteStream_Impl, MFBYTESTREAM_IS_READABLE,
    MFBYTESTREAM_IS_SEEKABLE, MFBYTESTREAM_SEEK_ORIGIN, MFCreateAsyncResult, MFInvokeCallback,
    msoBegin, msoCurrent,
};
use windows::Win32::System::Com::{COINIT_MULTITHREADED, CoInitializeEx, CoUninitialize};
use windows_core::{BOOL, IUnknown, Interface, Ref, implement};

/// A pointer Media Foundation promises stays valid until the read's
/// callback has run.
struct Buffer(*mut u8);
// SAFETY: the caller of BeginRead keeps the buffer alive and untouched until
// its callback, and only the worker writes it in between.
unsafe impl Send for Buffer {}

/// Media Foundation's objects are free-threaded.
struct Agile<T>(T);
// SAFETY: IMFAsyncResult from MFCreateAsyncResult is free-threaded.
unsafe impl<T> Send for Agile<T> {}

struct Job {
    buffer: Buffer,
    len: u32,
    offset: u64,
    result: Agile<IMFAsyncResult>,
}

#[implement(IMFByteStream)]
pub struct LoafByteStream {
    reader: Arc<Reader>,
    position: Arc<Mutex<u64>>,
    /// Bytes each finished BeginRead read, by its result, for EndRead.
    done: Arc<Mutex<HashMap<usize, u32>>>,
    /// The worker running BeginRead's reads in order. None once closed.
    jobs: Mutex<Option<Sender<Job>>>,
}

impl LoafByteStream {
    pub fn create(reader: Reader) -> IMFByteStream {
        let reader = Arc::new(reader);
        let position = Arc::new(Mutex::new(0));
        let done = Arc::new(Mutex::new(HashMap::new()));
        let (tx, rx) = mpsc::channel::<Job>();
        {
            let (reader, position, done) = (reader.clone(), position.clone(), done.clone());
            thread::spawn(move || {
                // SAFETY: balanced below; MTA so callbacks may run here.
                let com = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
                for job in rx {
                    let (status, n) = match read_into(&reader, job.buffer.0, job.len, job.offset) {
                        Ok(n) => (S_OK, n),
                        Err(hr) => (hr, 0),
                    };
                    if status.is_ok() {
                        *lock(&position) = job.offset + u64::from(n);
                    }
                    lock(&done).insert(job.result.0.as_raw() as usize, n);
                    // SAFETY: the result is a live IMFAsyncResult.
                    unsafe {
                        let _ = job.result.0.SetStatus(status);
                        let _ = MFInvokeCallback(&job.result.0);
                    }
                }
                if com.is_ok() {
                    // SAFETY: paired with the CoInitializeEx above.
                    unsafe { CoUninitialize() };
                }
            });
        }
        LoafByteStream {
            reader,
            position,
            done,
            jobs: Mutex::new(Some(tx)),
        }
        .into()
    }
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Reads up to [len] bytes at [offset] into [buffer]: as many as have
/// arrived, waiting for at least one. Zero at the end.
fn read_into(
    reader: &Reader,
    buffer: *mut u8,
    len: u32,
    offset: u64,
) -> Result<u32, windows_core::HRESULT> {
    if len == 0 {
        return Ok(0);
    }
    if buffer.is_null() {
        return Err(E_POINTER);
    }
    match reader.read_at(offset, len as usize) {
        Ok(bytes) => {
            let n = bytes.len().min(len as usize);
            // SAFETY: [buffer] holds [len] bytes, and n <= len.
            unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), buffer, n) };
            Ok(n as u32)
        }
        Err(ReadError::Eos) => Ok(0),
        Err(ReadError::Flushing | ReadError::Failed) => Err(E_FAIL),
    }
}

// The trait's signatures are COM's, raw pointers and all; Media Foundation
// is the only caller, and it passes what IMFByteStream promises.
#[allow(clippy::not_unsafe_ptr_arg_deref)]
impl IMFByteStream_Impl for LoafByteStream_Impl {
    fn GetCapabilities(&self) -> windows_core::Result<u32> {
        Ok(MFBYTESTREAM_IS_READABLE | MFBYTESTREAM_IS_SEEKABLE)
    }

    /// Unknown until the server says; Media Foundation reads -1 as unknown.
    fn GetLength(&self) -> windows_core::Result<u64> {
        Ok(self.reader.total().unwrap_or(u64::MAX))
    }

    fn SetLength(&self, _: u64) -> windows_core::Result<()> {
        Err(E_NOTIMPL.into())
    }

    fn GetCurrentPosition(&self) -> windows_core::Result<u64> {
        Ok(*lock(&self.position))
    }

    fn SetCurrentPosition(&self, position: u64) -> windows_core::Result<()> {
        *lock(&self.position) = position;
        Ok(())
    }

    fn IsEndOfStream(&self) -> windows_core::Result<BOOL> {
        let at = *lock(&self.position);
        Ok(self.reader.total().is_some_and(|total| at >= total).into())
    }

    fn Read(&self, pb: *mut u8, cb: u32, pcbread: *mut u32) -> windows_core::Result<()> {
        if pcbread.is_null() {
            return Err(E_POINTER.into());
        }
        let mut position = lock(&self.position);
        let n = read_into(&self.reader, pb, cb, *position)?;
        *position += u64::from(n);
        // SAFETY: checked non-null above.
        unsafe { *pcbread = n };
        Ok(())
    }

    fn BeginRead(
        &self,
        pb: *mut u8,
        cb: u32,
        pcallback: Ref<IMFAsyncCallback>,
        punkstate: Ref<IUnknown>,
    ) -> windows_core::Result<()> {
        let callback = pcallback.ok()?;
        // SAFETY: plain COM calls with live arguments.
        let result = unsafe { MFCreateAsyncResult(None, callback, punkstate.as_ref())? };
        let job = Job {
            buffer: Buffer(pb),
            len: cb,
            offset: *lock(&self.position),
            result: Agile(result),
        };
        match lock(&self.jobs).as_ref() {
            Some(jobs) => jobs.send(job).map_err(|_| E_FAIL.into()),
            None => Err(E_FAIL.into()),
        }
    }

    fn EndRead(&self, presult: Ref<IMFAsyncResult>) -> windows_core::Result<u32> {
        let result = presult.ok()?;
        let n = lock(&self.done).remove(&(result.as_raw() as usize));
        // SAFETY: a live IMFAsyncResult.
        unsafe { result.GetStatus()? };
        n.ok_or_else(|| E_INVALIDARG.into())
    }

    fn Write(&self, _: *const u8, _: u32) -> windows_core::Result<u32> {
        Err(E_NOTIMPL.into())
    }

    fn BeginWrite(
        &self,
        _: *const u8,
        _: u32,
        _: Ref<IMFAsyncCallback>,
        _: Ref<IUnknown>,
    ) -> windows_core::Result<()> {
        Err(E_NOTIMPL.into())
    }

    fn EndWrite(&self, _: Ref<IMFAsyncResult>) -> windows_core::Result<u32> {
        Err(E_NOTIMPL.into())
    }

    fn Seek(
        &self,
        origin: MFBYTESTREAM_SEEK_ORIGIN,
        offset: i64,
        _: u32,
    ) -> windows_core::Result<u64> {
        let mut position = lock(&self.position);
        let base = match origin {
            o if o == msoBegin => 0,
            o if o == msoCurrent => *position as i64,
            _ => return Err(E_INVALIDARG.into()),
        };
        let to = base
            .checked_add(offset)
            .filter(|to| *to >= 0)
            .ok_or(E_INVALIDARG)?;
        *position = to as u64;
        Ok(*position)
    }

    fn Flush(&self) -> windows_core::Result<()> {
        Ok(())
    }

    /// Wakes any read waiting on bytes, fails every read after, and lets
    /// the worker finish.
    fn Close(&self) -> windows_core::Result<()> {
        self.reader.flush();
        lock(&self.jobs).take();
        Ok(())
    }
}
