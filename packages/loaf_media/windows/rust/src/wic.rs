//! Windows Imaging Component, for pictures Flutter's own codecs refuse:
//! HEIC from an iPhone, AVIF. WIC decodes whatever the machine has codecs
//! for (the HEIF and AV1 extensions, where installed).

use windows::Win32::Graphics::Imaging::{
    CLSID_WICImagingFactory, GUID_WICPixelFormat32bppPRGBA, IWICBitmapSource, IWICImagingFactory,
    WICBitmapDitherTypeNone, WICBitmapInterpolationModeFant, WICBitmapPaletteTypeCustom,
    WICDecodeMetadataCacheOnDemand,
};
use windows::Win32::System::Com::{CLSCTX_INPROC_SERVER, CoCreateInstance};
use windows_core::Interface;

pub struct Decoded {
    pub width: u32,
    pub height: u32,
    /// Premultiplied RGBA, rows packed: what Flutter's decodeImageFromPixels
    /// takes as rgba8888.
    pub pixels: Vec<u8>,
}

/// Decodes the first frame of [bytes], scaled down to at most [max_width]
/// when given. Orientation is left as decoded: HEIF and AVIF carry theirs
/// in the container, which WIC applies, and EXIF's would turn them twice.
pub fn decode(bytes: &[u8], max_width: Option<u32>) -> windows_core::Result<Decoded> {
    // SAFETY: COM calls on live objects; [bytes] outlives the stream.
    unsafe {
        let factory: IWICImagingFactory =
            CoCreateInstance(&CLSID_WICImagingFactory, None, CLSCTX_INPROC_SERVER)?;
        let stream = factory.CreateStream()?;
        stream.InitializeFromMemory(bytes)?;
        let decoder = factory.CreateDecoderFromStream(
            &stream,
            std::ptr::null(),
            WICDecodeMetadataCacheOnDemand,
        )?;
        let mut source: IWICBitmapSource = decoder.GetFrame(0)?.cast()?;

        let (mut width, mut height) = (0u32, 0u32);
        source.GetSize(&mut width, &mut height)?;
        if let Some(max) = max_width.filter(|max| *max > 0 && *max < width) {
            let scaled_height =
                ((u64::from(height) * u64::from(max)) / u64::from(width)).max(1) as u32;
            let scaler = factory.CreateBitmapScaler()?;
            scaler.Initialize(&source, max, scaled_height, WICBitmapInterpolationModeFant)?;
            source = scaler.cast()?;
            (width, height) = (max, scaled_height);
        }

        let converter = factory.CreateFormatConverter()?;
        converter.Initialize(
            &source,
            &GUID_WICPixelFormat32bppPRGBA,
            WICBitmapDitherTypeNone,
            None,
            0.0,
            WICBitmapPaletteTypeCustom,
        )?;
        let stride = width * 4;
        let mut pixels = vec![0u8; stride as usize * height as usize];
        converter.CopyPixels(std::ptr::null(), stride, &mut pixels)?;
        Ok(Decoded {
            width,
            height,
            pixels,
        })
    }
}
