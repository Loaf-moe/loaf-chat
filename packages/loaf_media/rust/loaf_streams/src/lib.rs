//! The downloads players are reading, by file id. Dart reports each one's
//! progress over the channel (`stream.begin`, `stream.progress`,
//! `stream.end`); the other end is `lib/src/streams.dart`.
//!
//! Shared by both players that read a download as it arrives: `loafsrc` on
//! Linux (`linux/rust/`) and the `IMFByteStream` on Windows
//! (`windows/rust/`). A read past what has arrived waits for it here.

#![cfg_attr(
    not(test),
    deny(clippy::unwrap_used, clippy::expect_used, clippy::panic)
)]

use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, OnceLock, PoisonError};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReadError {
    /// Past the end of a finished download.
    Eos,
    /// GStreamer is flushing this reader (`unlock`) until `unlock_stop`.
    Flushing,
    /// The download failed, the stream ended, or the file can't be read.
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Progress {
    pub received: u64,
    pub total: Option<u64>,
    pub complete: bool,
    pub failed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnknownStream(pub String);

impl std::fmt::Display for UnknownStream {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "no stream {}", self.0)
    }
}

impl std::error::Error for UnknownStream {}

/// A poisoned lock only means another thread panicked holding it; the
/// state is plain numbers that are never left half-written, so carrying on
/// beats taking the player down too.
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

struct State {
    path: PathBuf,
    /// Bumped when Dart begins the stream again: a retried download writes
    /// a new `.part`, which readers must open afresh.
    generation: u64,
    received: u64,
    total: Option<u64>,
    complete: bool,
    failed: bool,
    /// Dart let go of the stream: nothing will ever arrive.
    ended: bool,
    /// Readers GStreamer is flushing. Kept under the same lock as the
    /// progress so that `unlock` can't slip in between a reader checking
    /// and starting to wait.
    flushing: HashSet<u64>,
}

/// One growing file. Readers wait on [cond] for progress, failure, the
/// end, or a flush.
pub struct Stream {
    state: Mutex<State>,
    cond: Condvar,
}

impl Stream {
    fn new(path: PathBuf, progress: Progress) -> Stream {
        Stream {
            state: Mutex::new(State {
                path,
                generation: 0,
                received: progress.received,
                total: progress.total,
                complete: progress.complete,
                failed: progress.failed,
                ended: false,
                flushing: HashSet::new(),
            }),
            cond: Condvar::new(),
        }
    }

    fn change(&self, f: impl FnOnce(&mut State)) {
        f(&mut lock(&self.state));
        self.cond.notify_all();
    }

    fn update(&self, progress: Progress) {
        self.change(|state| {
            state.received = progress.received;
            state.total = progress.total;
            state.complete = progress.complete;
            state.failed = progress.failed;
        });
    }

    /// The size, once the server or the sender has said.
    pub fn total(&self) -> Option<u64> {
        lock(&self.state).total
    }
}

fn registry() -> &'static Mutex<HashMap<String, Arc<Stream>>> {
    static REGISTRY: OnceLock<Mutex<HashMap<String, Arc<Stream>>>> = OnceLock::new();
    REGISTRY.get_or_init(Default::default)
}

/// Dart starts reporting a download, or begins it again after a retry.
pub fn begin(id: &str, path: PathBuf, progress: Progress) {
    let mut streams = lock(registry());
    match streams.get(id) {
        Some(stream) => stream.change(|state| {
            state.path = path;
            state.generation += 1;
            state.received = progress.received;
            state.total = progress.total;
            state.complete = progress.complete;
            state.failed = progress.failed;
        }),
        None => {
            streams.insert(id.to_owned(), Arc::new(Stream::new(path, progress)));
        }
    }
}

pub fn progress(id: &str, progress: Progress) -> Result<(), UnknownStream> {
    lookup(id)
        .ok_or_else(|| UnknownStream(id.to_owned()))?
        .update(progress);
    Ok(())
}

/// Nobody plays the file any more. Readers still holding the stream fail
/// rather than wait for bytes that won't come.
pub fn end(id: &str) -> Result<(), UnknownStream> {
    let stream = lock(registry())
        .remove(id)
        .ok_or_else(|| UnknownStream(id.to_owned()))?;
    stream.change(|state| state.ended = true);
    Ok(())
}

pub fn lookup(id: &str) -> Option<Arc<Stream>> {
    lock(registry()).get(id).cloned()
}

struct Open {
    generation: u64,
    file: File,
}

/// One source's view of a stream.
pub struct Reader {
    stream: Arc<Stream>,
    /// This reader's key in the stream's flushing set.
    key: u64,
    /// Opened on the first read and kept: the download renames
    /// `<name>.part` to `<name>` when it completes, and an open descriptor
    /// follows the file through the rename where a path would not.
    file: Mutex<Option<Open>>,
}

impl Reader {
    pub fn new(stream: Arc<Stream>) -> Reader {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        Reader {
            stream,
            key: NEXT.fetch_add(1, Ordering::Relaxed),
            file: Mutex::new(None),
        }
    }

    pub fn total(&self) -> Option<u64> {
        self.stream.total()
    }

    /// Up to [len] bytes at [offset], waiting until the download has them.
    /// Bytes before `received` never change, so they are read after the
    /// lock is let go.
    pub fn read_at(&self, offset: u64, len: usize) -> Result<Vec<u8>, ReadError> {
        let (path, generation, n) = {
            let mut state = lock(&self.stream.state);
            loop {
                if state.failed || state.ended {
                    return Err(ReadError::Failed);
                }
                if state.flushing.contains(&self.key) {
                    return Err(ReadError::Flushing);
                }
                if offset < state.received {
                    let n = (state.received - offset).min(len as u64) as usize;
                    break (state.path.clone(), state.generation, n);
                }
                if state.complete {
                    return Err(ReadError::Eos);
                }
                state = self
                    .stream
                    .cond
                    .wait(state)
                    .unwrap_or_else(PoisonError::into_inner);
            }
        };

        let mut open = lock(&self.file);
        let file = match open.take() {
            Some(current) if current.generation == generation => current,
            _ => Open {
                generation,
                file: open_download(&path).map_err(|e| {
                    eprintln!("[loaf media] can't open {}: {e}", path.display());
                    ReadError::Failed
                })?,
            },
        };
        let mut buf = vec![0; n];
        let read = read_exact_at(&file.file, &mut buf, offset);
        *open = Some(file);
        read.map_err(|e| {
            eprintln!("[loaf media] can't read {}: {e}", path.display());
            ReadError::Failed
        })?;
        Ok(buf)
    }

    /// GStreamer's `unlock`: a blocked read returns now, and reads fail
    /// until [unflush].
    pub fn flush(&self) {
        self.stream.change(|state| {
            state.flushing.insert(self.key);
        });
    }

    /// GStreamer's `unlock_stop`.
    pub fn unflush(&self) {
        self.stream.change(|state| {
            state.flushing.remove(&self.key);
        });
    }
}

impl Drop for Reader {
    fn drop(&mut self) {
        lock(&self.stream.state).flushing.remove(&self.key);
    }
}

/// Fills [buf] from [offset] without moving a shared cursor, so readers on
/// other threads never disturb each other.
#[cfg(unix)]
fn read_exact_at(file: &File, buf: &mut [u8], offset: u64) -> io::Result<()> {
    use std::os::unix::fs::FileExt;
    file.read_exact_at(buf, offset)
}

/// Windows' positional read may return short; this one doesn't.
#[cfg(windows)]
fn read_exact_at(file: &File, mut buf: &mut [u8], mut offset: u64) -> io::Result<()> {
    use std::os::windows::fs::FileExt;
    while !buf.is_empty() {
        match file.seek_read(buf, offset) {
            Ok(0) => return Err(io::ErrorKind::UnexpectedEof.into()),
            Ok(n) => {
                buf = &mut buf[n..];
                offset += n as u64;
            }
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e),
        }
    }
    Ok(())
}

/// The `.part` file, or the finished file if the download completed and
/// renamed it before this reader first opened it.
///
/// On Windows, `File::open` shares read, write and delete, and that is what
/// lets Dart rename the `.part` and evict old files while a player still
/// holds them open: a handle that withheld delete would block both.
fn open_download(path: &Path) -> io::Result<File> {
    match File::open(path) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            let done = path
                .to_str()
                .and_then(|p| p.strip_suffix(".part"))
                .ok_or(e)?;
            File::open(done)
        }
        opened => opened,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::io::Write;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::mpsc;
    use std::thread;
    use std::time::Duration;

    /// Deterministic bytes, so any read can be checked against its offset.
    fn bytes(len: usize) -> Vec<u8> {
        (0..len).map(|i| (i.wrapping_mul(31) % 251) as u8).collect()
    }

    /// A fresh id and `.part` path per test: the registry is process-wide
    /// and tests run in parallel.
    fn fixture(name: &str) -> (String, PathBuf) {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let n = NEXT.fetch_add(1, Ordering::Relaxed);
        let id = format!("{name}-{}-{n}", std::process::id());
        let dir = std::env::temp_dir().join("loaf_media_rs_tests");
        fs::create_dir_all(&dir).unwrap();
        (id.clone(), dir.join(format!("{id}.mp4.part")))
    }

    fn arrived(received: u64, total: u64) -> Progress {
        Progress {
            received,
            total: Some(total),
            complete: false,
            failed: false,
        }
    }

    /// Runs [f] on a thread and hands back its result, or None if it is
    /// still blocked after [timeout].
    fn spawn<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> mpsc::Receiver<T> {
        let (tx, rx) = mpsc::channel();
        thread::spawn(move || {
            let _ = tx.send(f());
        });
        rx
    }

    const LONG: Duration = Duration::from_secs(5);
    const SHORT: Duration = Duration::from_millis(150);

    fn reader(id: &str) -> Reader {
        Reader::new(lookup(id).expect("the stream was begun"))
    }

    #[test]
    fn fill_waits_past_the_download_and_wakes_on_progress() {
        let (id, path) = fixture("wait");
        let data = bytes(1500);
        fs::write(&path, &data).unwrap();
        begin(&id, path, arrived(500, 1500));

        let r = reader(&id);
        let rx = spawn(move || r.read_at(1000, 500));
        assert!(rx.recv_timeout(SHORT).is_err(), "it waits for the bytes");

        progress(&id, arrived(1500, 1500)).unwrap();
        assert_eq!(
            rx.recv_timeout(LONG).unwrap(),
            Ok(data[1000..1500].to_vec())
        );
    }

    #[test]
    fn fail_wakes_a_blocked_fill() {
        let (id, path) = fixture("fail");
        fs::write(&path, bytes(500)).unwrap();
        begin(&id, path, arrived(500, 1500));

        let r = reader(&id);
        let rx = spawn(move || r.read_at(1000, 500));
        assert!(rx.recv_timeout(SHORT).is_err());

        let mut failed = arrived(500, 1500);
        failed.failed = true;
        progress(&id, failed).unwrap();
        assert_eq!(rx.recv_timeout(LONG).unwrap(), Err(ReadError::Failed));
    }

    #[test]
    fn flush_wakes_a_blocked_fill_and_unflush_resumes() {
        let (id, path) = fixture("flush");
        let data = bytes(1500);
        fs::write(&path, &data).unwrap();
        begin(&id, path, arrived(500, 1500));

        let r = Arc::new(reader(&id));
        let blocked = Arc::clone(&r);
        let rx = spawn(move || blocked.read_at(1000, 500));
        assert!(rx.recv_timeout(SHORT).is_err());

        // GStreamer's unlock: the streaming thread must come back now.
        r.flush();
        assert_eq!(rx.recv_timeout(LONG).unwrap(), Err(ReadError::Flushing));
        assert_eq!(
            r.read_at(0, 10),
            Err(ReadError::Flushing),
            "until unlock_stop"
        );

        // unlock_stop: reads work again, and wait again.
        r.unflush();
        assert_eq!(r.read_at(0, 10), Ok(data[0..10].to_vec()));
        let again = Arc::clone(&r);
        let rx = spawn(move || again.read_at(1000, 500));
        assert!(rx.recv_timeout(SHORT).is_err());
        progress(&id, arrived(1500, 1500)).unwrap();
        assert_eq!(
            rx.recv_timeout(LONG).unwrap(),
            Ok(data[1000..1500].to_vec())
        );
    }

    #[test]
    fn complete_reads_the_tail_then_eos() {
        let (id, path) = fixture("tail");
        let data = bytes(1200);
        fs::write(&path, &data).unwrap();
        // The size was never said: the end is only known on completion.
        begin(
            &id,
            path,
            Progress {
                received: 1000,
                total: None,
                complete: false,
                failed: false,
            },
        );

        let r = reader(&id);
        let rx = spawn(move || (r.read_at(1000, 4096), r.read_at(1200, 4096)));
        assert!(rx.recv_timeout(SHORT).is_err());

        progress(
            &id,
            Progress {
                received: 1200,
                total: None,
                complete: true,
                failed: false,
            },
        )
        .unwrap();
        let (tail, end) = rx.recv_timeout(LONG).unwrap();
        assert_eq!(tail, Ok(data[1000..1200].to_vec()));
        assert_eq!(end, Err(ReadError::Eos));
    }

    #[test]
    fn end_with_readers_fails_them() {
        let (id, path) = fixture("end");
        fs::write(&path, bytes(100)).unwrap();
        begin(&id, path, arrived(100, 1000));

        let r = reader(&id);
        let rx = spawn(move || r.read_at(500, 100));
        assert!(rx.recv_timeout(SHORT).is_err());

        end(&id).unwrap();
        assert_eq!(rx.recv_timeout(LONG).unwrap(), Err(ReadError::Failed));
        assert!(lookup(&id).is_none(), "the registry let go of it");
        assert!(progress(&id, arrived(200, 1000)).is_err());
    }

    #[test]
    fn a_renamed_file_is_still_read() {
        let (id, path) = fixture("rename");
        let data = bytes(1000);
        fs::write(&path, &data).unwrap();
        begin(&id, path.clone(), arrived(1000, 1000));

        // Opened before the rename: the descriptor follows the file.
        let early = reader(&id);
        assert_eq!(early.read_at(0, 10), Ok(data[0..10].to_vec()));

        let done = path.with_extension("");
        fs::rename(&path, &done).unwrap();
        let mut complete = arrived(1000, 1000);
        complete.complete = true;
        progress(&id, complete).unwrap();
        assert_eq!(early.read_at(990, 10), Ok(data[990..1000].to_vec()));

        // Opened after it: the `.part` is gone, the finished file is there.
        let late = reader(&id);
        assert_eq!(late.read_at(500, 10), Ok(data[500..510].to_vec()));
    }

    #[test]
    fn a_retried_download_is_opened_afresh() {
        let (id, path) = fixture("retry");
        let data = bytes(1000);
        fs::write(&path, &data[..400]).unwrap();
        begin(&id, path.clone(), arrived(400, 1000));
        let r = reader(&id);
        assert_eq!(r.read_at(0, 10), Ok(data[0..10].to_vec()));

        // The retry writes a new `.part` in the old one's place.
        fs::remove_file(&path).unwrap();
        fs::write(&path, &data).unwrap();
        begin(&id, path, arrived(1000, 1000));
        assert_eq!(r.read_at(600, 400), Ok(data[600..1000].to_vec()));
    }

    #[test]
    fn threaded_stress() {
        let (id, path) = fixture("stress");
        const TOTAL: usize = 1 << 20;
        let data = Arc::new(bytes(TOTAL));
        fs::write(&path, b"").unwrap();
        begin(&id, path.clone(), arrived(0, TOTAL as u64));
        let stream = lookup(&id).unwrap();

        let readers: Vec<_> = (0..8u64)
            .map(|n| {
                let stream = Arc::clone(&stream);
                let data = Arc::clone(&data);
                spawn(move || {
                    let r = Reader::new(stream);
                    let mut seed = 0x9e37_79b9_7f4a_7c15_u64 ^ (n + 1);
                    for _ in 0..200 {
                        seed ^= seed << 13;
                        seed ^= seed >> 7;
                        seed ^= seed << 17;
                        let offset = (seed % TOTAL as u64) as usize;
                        let len = 1 + (seed >> 32) as usize % 65536;
                        let got = r
                            .read_at(offset as u64, len)
                            .map_err(|e| format!("reader {n} at {offset}+{len}: {e:?}"))?;
                        if got.is_empty() || got.len() > len {
                            return Err(format!(
                                "reader {n} at {offset}+{len}: {} bytes",
                                got.len()
                            ));
                        }
                        if got != data[offset..offset + got.len()] {
                            return Err(format!("reader {n} at {offset}+{len}: wrong bytes"));
                        }
                    }
                    Ok(())
                })
            })
            .collect();

        let writer_id = id.clone();
        let writer_data = Arc::clone(&data);
        let writer = spawn(move || {
            let mut file = fs::OpenOptions::new().append(true).open(&path).unwrap();
            let mut seed = 0x2545_f491_4f6c_dd1d_u64;
            let mut written = 0;
            while written < TOTAL {
                seed ^= seed << 13;
                seed ^= seed >> 7;
                seed ^= seed << 17;
                let chunk = (1 + seed as usize % 40_000).min(TOTAL - written);
                file.write_all(&writer_data[written..written + chunk])
                    .unwrap();
                written += chunk;
                let mut p = arrived(written as u64, TOTAL as u64);
                p.complete = written == TOTAL;
                progress(&writer_id, p).unwrap();
                thread::sleep(Duration::from_micros(200));
            }
        });

        writer.recv_timeout(LONG).expect("the writer finished");
        for rx in readers {
            let outcome = rx.recv_timeout(LONG).expect("no reader hangs");
            assert_eq!(outcome, Ok(()));
        }
        end(&id).unwrap();
    }
}
