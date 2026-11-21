//! Video surfaces for the wgpu renderer: I420 frames drawn straight from their
//! planes, converted to RGB in `fs_surface`.
//!
//! Each stream keeps three `R8Unorm` textures (Y at full size, U and V at half)
//! for as long as it is painted every frame. A frame's planes are uploaded only
//! when its generation is newer than the last one uploaded for the stream, so a
//! window repainting at its refresh rate re-uploads a 30 fps stream 30 times a
//! second, not 144. The decoder's stride goes to `write_texture` as it is; wgpu
//! stages the rows into its own upload buffer, which is the only CPU copy
//! between the decoder and the GPU.

use collections::FxHashMap;
use gpui::{PaintSurface, ScaledPixels, VideoFrame, YuvMatrix, YuvRange};
use std::num::NonZeroU64;

/// `SurfaceParams` in `shaders.wgsl`.
#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
pub(crate) struct SurfaceParams {
    bounds: [f32; 4],
    content_mask: [f32; 4],
    /// Rows of the 3×4 matrix taking `(y, u, v, 1)` to RGB.
    yuv_to_rgb: [[f32; 4]; 3],
}

pub(crate) const SURFACE_PARAMS_SIZE: u64 = std::mem::size_of::<SurfaceParams>() as u64;

const MIN_PARAM_SLOTS: u64 = 8;

struct StreamTextures {
    width: u32,
    height: u32,
    uploaded_generation: u64,
    planes: [wgpu::Texture; 3],
    bind_group: wgpu::BindGroup,
}

/// Textures and per-draw parameters for every stream in the current scene.
pub(crate) struct VideoResources {
    sampler: wgpu::Sampler,
    params: wgpu::Buffer,
    param_slots: u64,
    param_stride: u64,
    streams: FxHashMap<u64, StreamTextures>,
}

impl VideoResources {
    pub(crate) fn new(device: &wgpu::Device) -> Self {
        let param_stride = SURFACE_PARAMS_SIZE
            .next_multiple_of(u64::from(device.limits().min_uniform_buffer_offset_alignment));
        Self {
            sampler: device.create_sampler(&wgpu::SamplerDescriptor {
                label: Some("video_sampler"),
                address_mode_u: wgpu::AddressMode::ClampToEdge,
                address_mode_v: wgpu::AddressMode::ClampToEdge,
                mag_filter: wgpu::FilterMode::Linear,
                min_filter: wgpu::FilterMode::Linear,
                ..Default::default()
            }),
            params: params_buffer(device, MIN_PARAM_SLOTS * param_stride),
            param_slots: MIN_PARAM_SLOTS,
            param_stride,
            streams: FxHashMap::default(),
        }
    }

    pub(crate) fn bind_group_layout(device: &wgpu::Device) -> wgpu::BindGroupLayout {
        let plane = |binding| wgpu::BindGroupLayoutEntry {
            binding,
            visibility: wgpu::ShaderStages::FRAGMENT,
            ty: wgpu::BindingType::Texture {
                sample_type: wgpu::TextureSampleType::Float { filterable: true },
                view_dimension: wgpu::TextureViewDimension::D2,
                multisampled: false,
            },
            count: None,
        };
        device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("surfaces_layout"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::VERTEX_FRAGMENT,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: true,
                        min_binding_size: NonZeroU64::new(SURFACE_PARAMS_SIZE),
                    },
                    count: None,
                },
                plane(1),
                plane(2),
                plane(3),
                wgpu::BindGroupLayoutEntry {
                    binding: 4,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                    count: None,
                },
            ],
        })
    }

    /// Uploads what changed and writes each surface's parameters. Call once
    /// per frame, before encoding, with the scene's surfaces in draw order; a
    /// surface's slot is its index in that slice.
    pub(crate) fn prepare(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        layout: &wgpu::BindGroupLayout,
        surfaces: &[PaintSurface],
    ) {
        let needed = surfaces.len() as u64;
        if needed > self.param_slots {
            self.param_slots = needed.next_power_of_two();
            self.params = params_buffer(device, self.param_slots * self.param_stride);
            // Every bind group points at the old buffer.
            self.streams.clear();
        }

        self.streams
            .retain(|id, _| surfaces.iter().any(|s| s.frame.stream().as_u64() == *id));

        for (slot, surface) in surfaces.iter().enumerate() {
            let frame = &surface.frame;
            let id = frame.stream().as_u64();
            let (width, height) = (frame.width(), frame.height());
            let stale = self
                .streams
                .get(&id)
                .is_none_or(|t| t.width != width || t.height != height);
            if stale {
                let planes = [
                    plane_texture(device, width, height),
                    plane_texture(device, width / 2, height / 2),
                    plane_texture(device, width / 2, height / 2),
                ];
                let bind_group = self.bind_group(device, layout, &planes);
                self.streams.insert(
                    id,
                    StreamTextures {
                        width,
                        height,
                        uploaded_generation: 0,
                        planes,
                        bind_group,
                    },
                );
            }
            let Some(textures) = self.streams.get_mut(&id) else {
                continue;
            };
            if textures.uploaded_generation != frame.generation() {
                upload(queue, &textures.planes, frame);
                textures.uploaded_generation = frame.generation();
            }

            let params = SurfaceParams {
                bounds: bounds(surface.bounds),
                content_mask: bounds(surface.content_mask.bounds),
                yuv_to_rgb: yuv_to_rgb(frame.matrix(), frame.range()),
            };
            queue.write_buffer(
                &self.params,
                slot as u64 * self.param_stride,
                bytemuck::bytes_of(&params),
            );
        }
    }

    /// Draws one surface prepared by [`Self::prepare`]. The caller has set the
    /// surfaces pipeline and the globals bind group.
    pub(crate) fn draw(&self, slot: usize, surface: &PaintSurface, pass: &mut wgpu::RenderPass<'_>) {
        let Some(textures) = self.streams.get(&surface.frame.stream().as_u64()) else {
            return;
        };
        let offset = slot as u64 * self.param_stride;
        // `prepare` sized the buffer for every slot, so the offset fits in a u32
        // unless the scene holds millions of surfaces.
        let Ok(offset) = u32::try_from(offset) else {
            return;
        };
        pass.set_bind_group(1, &textures.bind_group, &[offset]);
        pass.draw(0..4, 0..1);
    }

    fn bind_group(
        &self,
        device: &wgpu::Device,
        layout: &wgpu::BindGroupLayout,
        planes: &[wgpu::Texture; 3],
    ) -> wgpu::BindGroup {
        let views = planes.each_ref().map(|t| t.create_view(&Default::default()));
        device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("video_bind_group"),
            layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::Buffer(wgpu::BufferBinding {
                        buffer: &self.params,
                        offset: 0,
                        size: NonZeroU64::new(SURFACE_PARAMS_SIZE),
                    }),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::TextureView(&views[0]),
                },
                wgpu::BindGroupEntry {
                    binding: 2,
                    resource: wgpu::BindingResource::TextureView(&views[1]),
                },
                wgpu::BindGroupEntry {
                    binding: 3,
                    resource: wgpu::BindingResource::TextureView(&views[2]),
                },
                wgpu::BindGroupEntry {
                    binding: 4,
                    resource: wgpu::BindingResource::Sampler(&self.sampler),
                },
            ],
        })
    }
}

fn params_buffer(device: &wgpu::Device, size: u64) -> wgpu::Buffer {
    device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("video_params"),
        size,
        usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: false,
    })
}

fn plane_texture(device: &wgpu::Device, width: u32, height: u32) -> wgpu::Texture {
    device.create_texture(&wgpu::TextureDescriptor {
        label: Some("video_plane"),
        size: wgpu::Extent3d {
            width,
            height,
            depth_or_array_layers: 1,
        },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: wgpu::TextureFormat::R8Unorm,
        usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
        view_formats: &[],
    })
}

fn upload(queue: &wgpu::Queue, planes: &[wgpu::Texture; 3], frame: &VideoFrame) {
    for (index, texture) in planes.iter().enumerate() {
        let (data, stride) = frame.plane(index);
        let rows = texture.height();
        // `VideoStream::frame` checked `data.len() >= stride * rows`.
        let len = (stride as usize) * (rows as usize);
        queue.write_texture(
            wgpu::TexelCopyTextureInfo {
                texture,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            &data[..len],
            wgpu::TexelCopyBufferLayout {
                offset: 0,
                bytes_per_row: Some(stride),
                rows_per_image: Some(rows),
            },
            texture.size(),
        );
    }
}

fn bounds(b: gpui::Bounds<ScaledPixels>) -> [f32; 4] {
    [b.origin.x.0, b.origin.y.0, b.size.width.0, b.size.height.0]
}

/// Rows of the matrix taking normalized `(y, u, v, 1)` to gamma-encoded RGB.
pub(crate) fn yuv_to_rgb(matrix: YuvMatrix, range: YuvRange) -> [[f32; 4]; 3] {
    let (kr, kb) = match matrix {
        YuvMatrix::Bt601 => (0.299_f32, 0.114_f32),
        YuvMatrix::Bt709 => (0.2126, 0.0722),
    };
    let kg = 1.0 - kr - kb;
    let (y_scale, y_offset, c_scale) = match range {
        YuvRange::Limited => (255.0 / 219.0, 16.0 / 255.0, 255.0 / 224.0),
        YuvRange::Full => (1.0, 0.0, 1.0),
    };
    let c_offset = 128.0 / 255.0;

    // RGB from Y' and centred Cb, Cr.
    let r_cr = 2.0 * (1.0 - kr);
    let g_cb = -2.0 * kb * (1.0 - kb) / kg;
    let g_cr = -2.0 * kr * (1.0 - kr) / kg;
    let b_cb = 2.0 * (1.0 - kb);

    // Fold the range scaling and offsets into each row.
    let row = |cb: f32, cr: f32| {
        [
            y_scale,
            cb * c_scale,
            cr * c_scale,
            -y_scale * y_offset - (cb + cr) * c_scale * c_offset,
        ]
    };
    [row(0.0, r_cr), row(g_cb, g_cr), row(b_cb, 0.0)]
}

