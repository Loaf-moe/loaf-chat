//! `loafsrc`: a GStreamer source for `loaf-media://<id>` that reads a
//! download while it arrives. A read past what has arrived waits for it,
//! which is what lets `playbin` start before the file is whole.

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use gst::glib;
use gst::prelude::*;
use gst::subclass::prelude::*;
use gst_base::prelude::*;
use gst_base::subclass::prelude::*;

use crate::streams::{self, ReadError, Reader};

const SCHEME: &str = "loaf-media";

glib::wrapper! {
    pub struct LoafSrc(ObjectSubclass<imp::LoafSrc>)
        @extends gst_base::BaseSrc, gst::Element, gst::Object,
        @implements gst::URIHandler;
}

/// Makes `loafsrc` known to this process, so `playbin` picks it for the
/// scheme.
pub fn register() -> Result<(), glib::BoolError> {
    gst::Element::register(None, "loafsrc", gst::Rank::PRIMARY, LoafSrc::static_type())
}

/// The file id in `loaf-media://<id>`. Apple's player asks for
/// `loaf-media:///<id>`, with the id in the path, so both are taken.
fn parse(uri: &str) -> Option<&str> {
    let rest = uri.strip_prefix(SCHEME)?.strip_prefix("://")?;
    let id = rest.trim_start_matches('/');
    (!id.is_empty() && !id.contains('/')).then_some(id)
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct LoafSrc {
        id: Mutex<Option<String>>,
        /// From `start` to `stop`. Shared so `unlock`, on another thread,
        /// can wake a `fill` blocked on it.
        reader: Mutex<Option<Arc<Reader>>>,
    }

    impl LoafSrc {
        fn reader(&self) -> Option<Arc<Reader>> {
            lock(&self.reader).clone()
        }
    }

    #[glib::object_subclass]
    impl ObjectSubclass for LoafSrc {
        const NAME: &'static str = "LoafSrc";
        type Type = super::LoafSrc;
        type ParentType = gst_base::BaseSrc;
        type Interfaces = (gst::URIHandler,);
    }

    impl ObjectImpl for LoafSrc {
        fn constructed(&self) {
            self.parent_constructed();
            // Offsets are bytes into the file, for the demuxer to pull.
            self.obj().set_format(gst::Format::Bytes);
        }
    }

    impl GstObjectImpl for LoafSrc {}

    impl ElementImpl for LoafSrc {
        fn metadata() -> Option<&'static gst::subclass::ElementMetadata> {
            static METADATA: std::sync::LazyLock<gst::subclass::ElementMetadata> =
                std::sync::LazyLock::new(|| {
                    gst::subclass::ElementMetadata::new(
                        "Loaf media source",
                        "Source/File",
                        "Reads a Loaf download while it arrives",
                        "Loaf Chat",
                    )
                });
            Some(&*METADATA)
        }

        fn pad_templates() -> &'static [gst::PadTemplate] {
            static TEMPLATES: std::sync::LazyLock<Vec<gst::PadTemplate>> =
                std::sync::LazyLock::new(|| {
                    // Without a template the element can't be built; a
                    // failure here is a GStreamer too broken to play anyway.
                    gst::PadTemplate::new(
                        "src",
                        gst::PadDirection::Src,
                        gst::PadPresence::Always,
                        &gst::Caps::new_any(),
                    )
                    .map(|t| vec![t])
                    .unwrap_or_default()
                });
            TEMPLATES.as_ref()
        }
    }

    impl URIHandlerImpl for LoafSrc {
        const URI_TYPE: gst::URIType = gst::URIType::Src;

        fn protocols() -> &'static [&'static str] {
            &[SCHEME]
        }

        fn uri(&self) -> Option<String> {
            lock(&self.id).as_ref().map(|id| format!("{SCHEME}://{id}"))
        }

        fn set_uri(&self, uri: &str) -> Result<(), glib::Error> {
            let id = parse(uri).ok_or_else(|| {
                glib::Error::new(
                    gst::URIError::BadUri,
                    &format!("not a Loaf media uri: {uri}"),
                )
            })?;
            *lock(&self.id) = Some(id.to_owned());
            Ok(())
        }
    }

    impl BaseSrcImpl for LoafSrc {
        fn start(&self) -> Result<(), gst::ErrorMessage> {
            let id = lock(&self.id)
                .clone()
                .ok_or_else(|| gst::error_msg!(gst::ResourceError::Settings, ["no uri was set"]))?;
            // Dart begins the stream before it asks for a player, so a
            // missing one is a bug or a stream already ended.
            let stream = streams::lookup(&id).ok_or_else(|| {
                gst::error_msg!(gst::ResourceError::NotFound, ["no download for {}", id])
            })?;
            *lock(&self.reader) = Some(Arc::new(Reader::new(stream)));
            Ok(())
        }

        fn stop(&self) -> Result<(), gst::ErrorMessage> {
            *lock(&self.reader) = None;
            Ok(())
        }

        fn is_seekable(&self) -> bool {
            true
        }

        fn size(&self) -> Option<u64> {
            self.reader()?.total()
        }

        fn fill(
            &self,
            offset: u64,
            length: u32,
            buffer: &mut gst::BufferRef,
        ) -> Result<gst::FlowSuccess, gst::FlowError> {
            let reader = self.reader().ok_or(gst::FlowError::Flushing)?;
            let bytes = match reader.read_at(offset, length as usize) {
                Ok(bytes) => bytes,
                Err(ReadError::Eos) => return Err(gst::FlowError::Eos),
                Err(ReadError::Flushing) => return Err(gst::FlowError::Flushing),
                Err(ReadError::Failed) => {
                    gst::element_imp_error!(
                        self,
                        gst::ResourceError::Read,
                        ["the download failed"]
                    );
                    return Err(gst::FlowError::Error);
                }
            };
            {
                let mut map = buffer.map_writable().map_err(|_| gst::FlowError::Error)?;
                map.get_mut(..bytes.len())
                    .ok_or(gst::FlowError::Error)?
                    .copy_from_slice(&bytes);
            }
            buffer.set_size(bytes.len());
            Ok(gst::FlowSuccess::Ok)
        }

        fn query(&self, query: &mut gst::QueryRef) -> bool {
            // Push only, still seekable, as network sources do. Offered
            // pull, typefinding peeks at the file's last bytes for tags and
            // qtdemux probes past `mdat` for more atoms, and both reads wait
            // for the end of the download, so nothing would play until the
            // file was whole. Pushed, they take the bytes as they come, and
            // a file with its index at the end is still reached by seeking.
            if let gst::QueryViewMut::Scheduling(q) = query.view_mut() {
                q.set(gst::SchedulingFlags::SEEKABLE, 1, -1, 0);
                q.add_scheduling_modes([gst::PadMode::Push]);
                return true;
            }
            BaseSrcImplExt::parent_query(self, query)
        }

        fn unlock(&self) -> Result<(), gst::ErrorMessage> {
            if let Some(reader) = self.reader() {
                reader.flush();
            }
            Ok(())
        }

        fn unlock_stop(&self) -> Result<(), gst::ErrorMessage> {
            if let Some(reader) = self.reader() {
                reader.unflush();
            }
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::parse;

    #[test]
    fn the_id_is_the_host_or_the_path() {
        assert_eq!(parse("loaf-media://t1"), Some("t1"));
        assert_eq!(parse("loaf-media:///t1"), Some("t1"));
        assert_eq!(parse("loaf-media://"), None);
        assert_eq!(parse("file:///t1"), None);
        assert_eq!(parse("loaf-media://a/b"), None);
    }
}
