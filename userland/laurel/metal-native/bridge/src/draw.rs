// SPDX-License-Identifier: MIT
//! Resources, command buffers and encoders behind bridge/NativeMetalObjects.h: what the compositor needs, on the PM4 layer (pm4/nmn_pm4.cc). What is not here is refused: nmb_last_error says so, and the frontend turns a refusal into Metal's error.
use crate::ffi::*;
use crate::objects::*;
use metal2vulkan::bind::{BindState, BoundBuffer, BoundSampler, BoundTexture, DrawCall, SamplerDescriptor, StageTable, TextureFacts, WriteSource};
use metal2vulkan::metal::{PixelFormat, PrimitiveType, TextureType};
use metal2vulkan::pipeline::Stage;
use metal2vulkan::vk;
use std::collections::HashMap;
use std::ffi::{c_char, c_void};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};

const SLOT_BYTES: usize = 64;
const SHARED: u64 = 0;
const MEMORYLESS: u64 = 3;

pub(crate) struct Gpu {
    pub dev: *mut NwDevice,
    pub gpu: *mut NmnGpu,
    zero: Mutex<NwSlice>,
    transient: Mutex<HashMap<(u32, u32, u32), Arc<Slice>>>,
    neutrals: Mutex<HashMap<u32, Arc<TextureObj>>>,
    pub names_total: AtomicU64,
}
// SAFETY: nw_device has its own lock; nmn_gpu is read only after creation but for private memory, which grows under bake's caller.
unsafe impl Send for Gpu {}
unsafe impl Sync for Gpu {}

impl Gpu {
    pub fn open() -> Result<Arc<Gpu>, String> {
        let mut why = [0 as c_char; 256];
        let text = |w: &[c_char]| unsafe { std::ffi::CStr::from_ptr(w.as_ptr()) }.to_string_lossy().into_owned();
        unsafe {
            let mut ctx = std::ptr::null_mut();
            let ops = nmn_platform_ops(&mut ctx, why.as_mut_ptr(), why.len());
            if ops.is_null() {
                return Err(text(&why));
            }
            let dev = nw_device_open(ops, ctx, why.as_mut_ptr(), why.len());
            if dev.is_null() {
                return Err(text(&why));
            }
            let gpu = nmn_gpu_new(dev, why.as_mut_ptr(), why.len());
            if gpu.is_null() {
                nw_device_close(dev);
                return Err(text(&why));
            }
            let mut zero = NwSlice::empty();
            if !nw_slice_new(dev, 65536, 4096, &mut zero) {
                return Err("no GPU memory for the zero buffer".into());
            }
            Ok(Arc::new(Gpu { dev, gpu, zero: Mutex::new(zero), transient: Mutex::new(HashMap::new()), neutrals: Mutex::new(HashMap::new()), names_total: AtomicU64::new(0) }))
        }
    }
    fn zero_iova(&self) -> u64 {
        self.zero.lock().unwrap().iova
    }
    fn neutral_image(self: &Arc<Gpu>, key: u32, _kind: u32, layers: u32) -> Result<Arc<TextureObj>, String> {
        let mut map = self.neutrals.lock().unwrap();
        if let Some(t) = map.get(&key) {
            return Ok(t.clone());
        }
        let metal_kind = match key { 1 => 0u64, 2 => 5, 3 => 7, _ => 2 };
        let d = NmbTextureDescriptor { kind: metal_kind, format: 70, width: 1, height: 1, depth: 1, levels: 1, samples: 1, array_length: 1, usage: 1, options: 0 };
        let _ = layers;
        let t = new_texture(self, &d, None)?;
        map.insert(key, t.clone());
        Ok(t)
    }
}

pub(crate) struct Slice {
    gpu: Arc<Gpu>,
    s: Mutex<NwSlice>,
    pub iova: u64,
    pub map: usize,
    pub size: u64,
    bo: usize,
}
impl Slice {
    pub(crate) fn new(gpu: &Arc<Gpu>, size: u64, align: u64) -> Result<Arc<Slice>, String> {
        let mut s = NwSlice::empty();
        if !unsafe { nw_slice_new(gpu.dev, size.max(1), align, &mut s) } {
            return Err(format!("no GPU memory for {size} bytes"));
        }
        Ok(Arc::new(Slice { gpu: gpu.clone(), iova: s.iova, map: s.map as usize, size, bo: s.bo as usize, s: Mutex::new(s) }))
    }
    pub fn bo(&self) -> *mut NwBoHead {
        self.bo as *mut NwBoHead
    }
}
impl Drop for Slice {
    fn drop(&mut self) {
        let mut s = self.s.lock().unwrap();
        unsafe { nw_slice_free(self.gpu.dev, &mut *s) };
    }
}

/// Memory of a buffer: a slice of ours, an imported surface, or the caller's pages.
pub(crate) enum Backing {
    Slice(Arc<Slice>),
    Sub(Arc<Slice>, u64, Option<crate::misc::HeapRange>),
    Bo { gpu: Arc<Gpu>, bo: usize, offset: u64 },
}
impl Drop for Backing {
    fn drop(&mut self) {
        if let Backing::Bo { gpu, bo, .. } = self {
            unsafe { nw_bo_free(gpu.dev, *bo as *mut NwBoHead) };
        }
    }
}
impl Backing {
    pub(crate) fn iova(&self) -> u64 {
        match self {
            Backing::Slice(s) => s.iova,
            Backing::Sub(s, o, _) => s.iova + o,
            Backing::Bo { bo, offset, .. } => unsafe { (*(*bo as *mut NwBoHead)).iova + offset },
        }
    }
    pub(crate) fn bo(&self) -> *mut NwBoHead {
        match self {
            Backing::Slice(s) | Backing::Sub(s, _, _) => s.bo(),
            Backing::Bo { bo, .. } => *bo as *mut NwBoHead,
        }
    }
    pub(crate) fn map(&self) -> *mut c_void {
        match self {
            Backing::Slice(s) => s.map as *mut c_void,
            Backing::Sub(s, o, _) => (s.map as u64 + o) as *mut c_void,
            Backing::Bo { bo, offset, .. } => unsafe {
                let b = *bo as *mut NwBoHead;
                if (*b).map.is_null() { std::ptr::null_mut() } else { ((*b).map as *mut u8).add(*offset as usize) as *mut c_void }
            },
        }
    }
    pub(crate) fn must_name(&self) -> bool {
        match self {
            Backing::Slice(s) | Backing::Sub(s, _, _) => unsafe { (*s.bo()).kind == NW_BO_SCATTERED },
            Backing::Bo { .. } => true,
        }
    }
}

pub struct NmbBuffer {
    pub(crate) b: Arc<BufferObj>,
}
pub(crate) struct BufferObj {
    pub(crate) backing: Backing,
    pub(crate) length: u64,
    pub(crate) surface_id: u32,
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nmb_buffer_new(d: *mut NmbDevice, length: u64, _options: u64, bytes: *const c_void) -> *mut NmbBuffer {
    guard(std::ptr::null_mut(), || {
        let gpu = &get(d)?.gpu;
        let s = Slice::new(gpu, length, 256)?;
        unsafe {
            if bytes.is_null() {
                std::ptr::write_bytes(s.map as *mut u8, 0, length as usize);
            } else {
                std::ptr::copy_nonoverlapping(bytes as *const u8, s.map as *mut u8, length as usize);
            }
        }
        Ok(boxed(NmbBuffer { b: Arc::new(BufferObj { backing: Backing::Slice(s), length, surface_id: 0 }) }))
    })
}

/// The frontend says which IOSurface a CPU range is, before it asks for a buffer over that range (native_bridge_metal_set_surface_hook).
/// A surface comes in by its ID: the kernel keeps its pool pages and its display fence. Other ranges come in as the caller's pages.
static NOTED_SURFACES: Mutex<Vec<(usize, u64, u32)>> = Mutex::new(Vec::new());

#[unsafe(no_mangle)]
pub extern "C" fn nmn_note_surface(base: *const c_void, bytes: u64, surface: u32) {
    let mut l = NOTED_SURFACES.lock().unwrap();
    l.retain(|x| x.0 != base as usize);
    l.push((base as usize, bytes, surface));
    if l.len() > 256 {
        l.remove(0);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nmb_buffer_new_no_copy(d: *mut NmbDevice, pointer: *mut c_void, length: u64, _options: u64) -> *mut NmbBuffer {
    guard(std::ptr::null_mut(), || {
        let gpu = &get(d)?.gpu;
        let surface = NOTED_SURFACES.lock().unwrap().iter().find(|x| x.0 == pointer as usize && x.1 >= length).map(|x| x.2);
        if let Some(id) = surface {
            let mut offset = 0u32;
            let mut row = 0u32;
            let bo = unsafe { nw_bo_import_surface(gpu.dev, id, &mut offset, &mut row) };
            if !bo.is_null() {
                unsafe { (*bo).map = pointer };
                return Ok(boxed(NmbBuffer { b: Arc::new(BufferObj { backing: Backing::Bo { gpu: gpu.clone(), bo: bo as usize, offset: offset as u64 }, length, surface_id: id }) }));
            }
            // a surface the kernel takes no import by ID of: its mapping in this process is whole pages too, as in Turnip's redwood_drm_host_import
        }
        // the kernel takes whole pages of this process (hostPages: its PAGE_MASK, 16 KiB here); the caller's range can start and end inside one, as Metal allows for newBufferWithBytesNoCopy on this device [V log: 6400 bytes at 0x...9c00]
        let page = (unsafe { libc::sysconf(libc::_SC_PAGESIZE) } as u64).max(4096);
        let first = pointer as u64 & !(page - 1);
        let whole = ((pointer as u64 + length + page - 1) & !(page - 1)) - first;
        let bo = unsafe { nw_bo_import_host(gpu.dev, first as *mut c_void, whole, false) };
        if bo.is_null() {
            return Err(format!("the kernel refused the host pages {first:#x} + {whole}: {}", unsafe { std::ffi::CStr::from_ptr(nw_last_refusal(gpu.dev)) }.to_string_lossy()));
        }
        Ok(boxed(NmbBuffer { b: Arc::new(BufferObj { backing: Backing::Bo { gpu: gpu.clone(), bo: bo as usize, offset: pointer as u64 - first }, length, surface_id: surface.unwrap_or(0) }) }))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn nmb_buffer_release(b: *mut NmbBuffer) {
    release(b)
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_buffer_contents(b: *const NmbBuffer) -> *mut c_void {
    guard(std::ptr::null_mut(), || Ok(get(b)?.b.backing.map()))
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_buffer_length(b: *const NmbBuffer) -> u64 {
    guard(0, || Ok(get(b)?.b.length))
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_buffer_gpu_address(b: *const NmbBuffer) -> u64 {
    guard(0, || Ok(get(b)?.b.backing.iova()))
}

// ---- textures ----

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct NmbTextureDescriptor {
    pub kind: u64,
    pub format: u64,
    pub width: u64,
    pub height: u64,
    pub depth: u64,
    pub levels: u64,
    pub samples: u64,
    pub array_length: u64,
    pub usage: u64,
    pub options: u64,
}

pub(crate) struct TextureObj {
    pub(crate) gpu: Arc<Gpu>,
    pub(crate) image: usize,
    pub(crate) pipe_format: u32,
    pub(crate) desc: NmbTextureDescriptor,
    pub(crate) backing: Option<Arc<BufferObj>>, // over a buffer or a surface
    pub(crate) memory: Option<Arc<Slice>>,
    pub(crate) heap: Option<crate::misc::HeapRange>, // in a heap: `memory` is the heap's, and the image starts here in it
    pub(crate) parent: Option<Arc<TextureObj>>,
    pub(crate) view_type: u32,
    pub(crate) base_level: u32,
    pub(crate) levels: u32,
    pub(crate) base_layer: u32,
    pub(crate) layers: u32,
    pub(crate) memoryless: bool,
    pub(crate) shadow: Option<Shadow>,
}
/// A texture over a buffer whose rows the GPU cannot read as they lie: an a6xx reads a pitch of 64 bytes at least (fdl6_layout), and a caller may choose 16. The image lies in this copy, with an aligned pitch, and each command buffer that reads the texture copies the rows first.
/// Limit [I]: the buffer's content as the CPU sees it when the draw is encoded. A GPU write to that buffer in the same command buffer is not seen; a render or blit target with such rows is refused.
pub(crate) struct Shadow {
    pub(crate) copy: Arc<Slice>,
    pub(crate) offset: u64,
    pub(crate) row: u64,
    pub(crate) pitch: u64,
    pub(crate) line: u64,
    pub(crate) rows: u64,
}
impl Drop for TextureObj {
    fn drop(&mut self) {
        if self.parent.is_none() {
            unsafe { nmn_image_free(self.image as *mut NmnImage) };
        }
    }
}
impl TextureObj {
    fn storage_mode(d: &NmbTextureDescriptor) -> u64 {
        (d.options >> 4) & 0xf
    }
    pub(crate) fn must_name(&self) -> bool {
        if let Some(p) = &self.parent {
            return p.must_name();
        }
        self.backing.as_ref().is_some_and(|b| b.backing.must_name()) || self.memory.as_ref().is_some_and(|m| unsafe { (*m.bo()).kind == NW_BO_SCATTERED })
    }
    pub(crate) fn bo(&self) -> *mut NwBoHead {
        if let Some(p) = &self.parent {
            return p.bo();
        }
        if let Some(b) = &self.backing {
            return b.backing.bo();
        }
        self.memory.as_ref().map_or(std::ptr::null_mut(), |m| m.bo())
    }
    /// Width and height of a level of this view, counted from its first level.
    pub(crate) fn level_size(&self, level: u64) -> (u64, u64) {
        let l = self.base_level as u64 + level;
        ((self.desc.width >> l).max(1), (self.desc.height >> l).max(1))
    }
    /// The shadow of this texture or of the texture this view is of.
    pub(crate) fn shadow(&self) -> Option<&Shadow> {
        match &self.parent {
            Some(p) => p.shadow(),
            None => self.shadow.as_ref(),
        }
    }
    pub(crate) fn root_id(&self) -> usize {
        match &self.parent {
            Some(p) => p.root_id(),
            None => self as *const TextureObj as usize,
        }
    }
    /// Where the CPU reads and writes this image's first byte: its own memory (a heap's, at its place in the heap) or its buffer. A view's is its parent's: one image.
    pub(crate) fn cpu_base(&self) -> Option<*mut u8> {
        if let Some(p) = &self.parent {
            return p.cpu_base();
        }
        if let Some(m) = &self.memory {
            return Some((m.map as u64 + self.heap.as_ref().map_or(0, |h| h.at)) as *mut u8);
        }
        self.backing.as_ref().map(|b| b.backing.map() as *mut u8)
    }
    /// The buffer that holds what the CPU wrote (a shadow's source).
    pub(crate) fn root_backing(&self) -> Option<&Arc<BufferObj>> {
        match &self.parent {
            Some(p) => p.root_backing(),
            None => self.backing.as_ref(),
        }
    }
    pub(crate) fn view_kind(metal: u64) -> u32 {
        // MTLTextureType: 0 1D, 1 1D array, 2 2D, 3 2D array, 4 2D MS, 5 cube, 6 cube array, 7 3D, 8 2D MS array, 9 buffer
        match metal {
            0 | 1 => NMN_IMAGE_1D,
            5 | 6 => NMN_IMAGE_CUBE,
            7 => NMN_IMAGE_3D,
            _ => NMN_IMAGE_2D,
        }
    }
    fn facts(&self) -> Result<TextureFacts, String> {
        let t = TextureType::try_from(self.desc.kind as u32).map_err(|_| format!("texture type {}", self.desc.kind))?;
        let f = PixelFormat::try_from(self.desc.format as u32).map_err(|_| format!("pixel format {}", self.desc.format))?;
        let mut facts = TextureFacts::new(t, f);
        facts.sample_count = self.desc.samples.max(1) as u32;
        facts.array_length = self.desc.array_length.max(1) as u32;
        facts.mipmap_level_count = self.desc.levels.max(1) as u32;
        Ok(facts)
    }
}

pub struct NmbTexture {
    pub(crate) t: Arc<TextureObj>,
}

pub(crate) fn new_texture(gpu: &Arc<Gpu>, d: &NmbTextureDescriptor, over: Option<(&Arc<BufferObj>, u64, u64)>) -> Result<Arc<TextureObj>, String> {
    let pipe = unsafe { nmn_format_from_metal(d.format) };
    if pipe == 0 {
        return Err(format!("pixel format {} has no native path", d.format));
    }
    let kind = TextureObj::view_kind(d.kind);
    let mode = TextureObj::storage_mode(d);
    // private and memoryless render targets take the GPU's own layout; everything the CPU can touch stays linear, so replace and getBytes are plain copies
    let tiled = over.is_none() && mode >= 2;
    // a row this GPU cannot read as it lies: the image gets its own memory, with an aligned pitch
    // ... or a first byte it cannot name: a base address is in units of 64 bytes, and the low bits are lost (icons moved by 4 pixels, over host pages that start inside a page)
    let unaligned = over.is_some_and(|o| o.2 & 63 != 0 || (o.0.backing.iova() + o.1) & 63 != 0);
    let stride = over.map_or(0, |o| if unaligned { ((o.2 + 63) & !63) as u32 } else { o.2 as u32 });
    let layers = if d.kind == 5 || d.kind == 6 { (d.array_length.max(1) * 6) as u32 } else { d.array_length.max(1) as u32 };
    let image = unsafe { nmn_image_new(gpu.gpu, pipe, kind, d.width as u32, d.height.max(1) as u32, d.depth.max(1) as u32, d.levels.max(1) as u32, layers, d.samples.max(1) as u32, tiled, stride) };
    if image.is_null() {
        return Err(format!("no layout for a texture of format {} {} x {}, {} levels, row bytes {}", d.format, d.width, d.height, d.levels, stride));
    }
    let size = unsafe { nmn_image_size(image) };
    let mut memory = None;
    let mut backing = None;
    let mut shadow = None;
    let memoryless = mode == MEMORYLESS && over.is_none();
    if let (Some((b, offset, row)), true) = (over, unaligned) {
        if d.levels.max(1) != 1 || d.kind == 7 || d.array_length.max(1) != 1 {
            unsafe { nmn_image_free(image) };
            return Err(format!("a texture of more than one level or layer over rows of {row} bytes has no native path yet"));
        }
        let copy = Slice::new(gpu, size, 4096)?;
        unsafe { nmn_image_bind(image, copy.iova) };
        let cpp = unsafe { nmn_format_blocksize(pipe) } as u64;
        shadow = Some(Shadow { copy, offset, row, pitch: stride as u64, line: (d.width * cpp).min(row), rows: d.height.max(1) });
        backing = Some(b.clone());
    } else if let Some((b, offset, _)) = over {
        unsafe { nmn_image_bind(image, b.backing.iova() + offset) };
        backing = Some(b.clone());
    } else if memoryless {
        // One backing for each size and format: a memoryless texture's content is undefined between encoders, by Metal's rule. It is allocated at the first use of the pass, and a pass that never writes it binds nothing at all.
        let key = (pipe, d.width as u32, d.height as u32);
        let mut map = gpu.transient.lock().unwrap();
        let m = match map.get(&key) {
            Some(m) => m.clone(),
            None => {
                let m = Slice::new(gpu, size, 4096)?;
                map.insert(key, m.clone());
                m
            }
        };
        unsafe { nmn_image_bind(image, m.iova) };
        memory = Some(m);
    } else {
        let m = Slice::new(gpu, size, 4096)?;
        unsafe { nmn_image_bind(image, m.iova) };
        memory = Some(m);
    }
    let levels = d.levels.max(1) as u32;
    Ok(Arc::new(TextureObj { gpu: gpu.clone(), image: image as usize, pipe_format: pipe, desc: *d, backing, memory, heap: None, parent: None, view_type: kind, base_level: 0, levels, base_layer: 0, layers, memoryless, shadow }))
}

#[unsafe(no_mangle)]
pub extern "C" fn nmb_texture_new(d: *mut NmbDevice, descriptor: *const NmbTextureDescriptor) -> *mut NmbTexture {
    guard(std::ptr::null_mut(), || Ok(boxed(NmbTexture { t: new_texture(&get(d)?.gpu, get(descriptor)?, None)? })))
}

#[unsafe(no_mangle)]
pub extern "C" fn nmb_texture_new_on_buffer(b: *mut NmbBuffer, descriptor: *const NmbTextureDescriptor, offset: u64, bytes_per_row: u64, _iosurface: bool) -> *mut NmbTexture {
    guard(std::ptr::null_mut(), || {
        let buffer = &get(b)?.b;
        let gpu = match &buffer.backing {
            Backing::Slice(s) | Backing::Sub(s, _, _) => s.gpu.clone(),
            Backing::Bo { gpu, .. } => gpu.clone(),
        };
        Ok(boxed(NmbTexture { t: new_texture(&gpu, get(descriptor)?, Some((buffer, offset, bytes_per_row)))? }))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn nmb_texture_new_linear(b: *mut NmbBuffer, descriptor: *const NmbTextureDescriptor, offset: u64, bytes_per_row: u64, _bytes_per_image: u64) -> *mut NmbTexture {
    nmb_texture_new_on_buffer(b, descriptor, offset, bytes_per_row, false)
}

#[unsafe(no_mangle)]
pub extern "C" fn nmb_texture_release(t: *mut NmbTexture) {
    release(t)
}

#[unsafe(no_mangle)]
pub extern "C" fn nmb_texture_describe(t: *const NmbTexture, out: *mut NmbTextureDescriptor) {
    guard((), || {
        unsafe { *out = get(t)?.t.desc };
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nmb_texture_replace(t: *mut NmbTexture, region: *const u64, level: u64, slice: u64, bytes: *const c_void, bytes_per_row: u64, _bytes_per_image: u64, _length: u64) -> bool {
    guard(false, || {
        let t = &get(t)?.t;
        let r = unsafe { std::slice::from_raw_parts(region, 6) };
        if TextureObj::storage_mode(&t.desc) >= 2 {
            return Err("replaceRegion on a private texture".into());
        }
        let map = t.cpu_base().ok_or("no CPU mapping")?;
        let (level, slice) = (level as u32 + t.base_level, slice as u32 + t.base_layer);
        unsafe {
            let cpp = nmn_format_blocksize(t.pipe_format) as u64;
            // with a shadow, the buffer holds the truth, in the caller's rows at the caller's offset
            let (pitch, base) = match t.shadow() {
                Some(x) => (x.row, x.offset),
                None => (nmn_image_pitch(t.image as *const NmnImage, level) as u64, nmn_image_layer_offset(t.image as *const NmnImage, level, slice)),
            };
            for y in 0..r[4] {
                let dst = map.add((base + (r[1] + y) * pitch + r[0] * cpp) as usize);
                let src = (bytes as *const u8).add((y * bytes_per_row) as usize);
                std::ptr::copy_nonoverlapping(src, dst, (r[3] * cpp) as usize);
            }
        }
        Ok(true)
    })
}

// ---- samplers and depth state ----

pub struct NmbSampler {
    pub(crate) words: [u32; 16],
    pub(crate) desc: SamplerDescriptor,
}

#[repr(C)]
pub struct NmbSamplerDescriptor {
    pub min_filter: u64,
    pub mag_filter: u64,
    pub mip_filter: u64,
    pub s_address: u64,
    pub t_address: u64,
    pub r_address: u64,
    pub border_color: u64,
    pub normalized: u64,
    pub max_anisotropy: u64,
    pub compare: u64,
    pub lod_average: u64,
    pub lod_min: f32,
    pub lod_max: f32,
}

#[unsafe(no_mangle)]
pub extern "C" fn nmb_sampler_new(_d: *mut NmbDevice, descriptor: *const NmbSamplerDescriptor) -> *mut NmbSampler {
    guard(std::ptr::null_mut(), || {
        let s = get(descriptor)?;
        let state = NmnSamplerState { min_filter: s.min_filter as u32, mag_filter: s.mag_filter as u32, mip_filter: s.mip_filter as u32, s_address: s.s_address as u32, t_address: s.t_address as u32, r_address: s.r_address as u32, border_color: s.border_color as u32, normalized: s.normalized as u32, max_anisotropy: s.max_anisotropy as u32, compare: s.compare as u32, lod_min: s.lod_min, lod_max: s.lod_max };
        let mut words = [0u32; 16];
        unsafe { nmn_descriptor_sampler(&state, 0, words.as_mut_ptr()) };
        let mut desc = SamplerDescriptor::new();
        desc.normalized_coordinates = s.normalized != 0;
        desc.lod_min_clamp = s.lod_min;
        desc.lod_max_clamp = s.lod_max;
        Ok(boxed(NmbSampler { words, desc }))
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_sampler_release(s: *mut NmbSampler) {
    release(s)
}

// ---- queues and command buffers ----

pub struct NmbQueue {
    gpu: Arc<Gpu>,
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_queue_new(d: *mut NmbDevice) -> *mut NmbQueue {
    guard(std::ptr::null_mut(), || Ok(boxed(NmbQueue { gpu: get(d)?.gpu.clone() })))
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_queue_release(q: *mut NmbQueue) {
    release(q)
}

struct Upload {
    cur: Arc<Slice>,
    used: u64,
}

pub struct NmbCommandBuffer {
    pub(crate) gpu: Arc<Gpu>,
    pub(crate) cs: Box<NwCs>,
    pub(crate) held_textures: Vec<Arc<TextureObj>>,
    pub(crate) held_buffers: Vec<Arc<BufferObj>>,
    pub(crate) held_slices: Vec<Arc<Slice>>,
    pub(crate) held_baked: Vec<Arc<Baked>>,
    pub(crate) held_streams: Vec<Box<NwCs>>,
    pub(crate) names: Vec<usize>,
    pub(crate) shadows_done: Vec<usize>,
    upload: Option<Upload>,
    pub(crate) state: Arc<(Mutex<CbState>, Condvar)>,
    handlers: Vec<(extern "C" fn(*mut c_void), usize)>,
    scheduled: Vec<(extern "C" fn(*mut c_void), usize)>,
    pub(crate) open: bool,
    pub(crate) signals: Vec<(Arc<crate::misc::EventObj>, u64)>,
    pub(crate) waits: Vec<(Arc<crate::misc::EventObj>, u64)>,
}
#[derive(Default)]
pub(crate) struct CbState {
    pub(crate) status: u64,
    pub(crate) error: String,
    pub(crate) started: f64,
    pub(crate) ended: f64,
}

impl NmbCommandBuffer {
    pub(crate) fn upload(&mut self, bytes: u64, align: u64) -> Result<(u64, *mut u8), String> {
        const CHUNK: u64 = 64 * 1024;
        let need_new = match &self.upload {
            Some(u) => ((u.used + align - 1) & !(align - 1)) + bytes > u.cur.size,
            None => true,
        };
        if need_new {
            let s = Slice::new(&self.gpu, bytes.max(CHUNK), 4096)?;
            self.held_slices.push(s.clone());
            self.upload = Some(Upload { cur: s, used: 0 });
        }
        let u = self.upload.as_mut().unwrap();
        let at = (u.used + align - 1) & !(align - 1);
        u.used = at + bytes;
        Ok((u.cur.iova + at, (u.cur.map as u64 + at) as *mut u8))
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn nmb_command_buffer_new(q: *mut NmbQueue) -> *mut NmbCommandBuffer {
    guard(std::ptr::null_mut(), || {
        let gpu = get(q)?.gpu.clone();
        let mut cs: Box<NwCs> = Box::new(unsafe { std::mem::zeroed() });
        unsafe {
            nw_cs_init(&mut *cs, gpu.dev);
            nmn_cmd_init(&mut *cs, gpu.gpu);
        }
        Ok(boxed(NmbCommandBuffer { gpu, cs, held_textures: vec![], held_buffers: vec![], held_slices: vec![], held_baked: vec![], held_streams: vec![], names: vec![], shadows_done: vec![], upload: None, state: Arc::new((Mutex::new(CbState::default()), Condvar::new())), handlers: vec![], scheduled: vec![], open: false, signals: vec![], waits: vec![] }))
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn nmb_command_buffer_release(c: *mut NmbCommandBuffer) {
    if !c.is_null() {
        let b = unsafe { Box::from_raw(c) };
        drop(b);
    }
}
impl Drop for NmbCommandBuffer {
    fn drop(&mut self) {
        unsafe {
            nw_cs_finish(&mut *self.cs);
            for s in &mut self.held_streams {
                nw_cs_finish(&mut **s);
            }
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn nmb_command_buffer_on_completed(c: *mut NmbCommandBuffer, handler: extern "C" fn(*mut c_void), context: *mut c_void) -> bool {
    guard(false, || {
        unsafe { c.as_mut() }.ok_or("null command buffer")?.handlers.push((handler, context as usize));
        Ok(true)
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_command_buffer_on_scheduled(c: *mut NmbCommandBuffer, handler: extern "C" fn(*mut c_void), context: *mut c_void) -> bool {
    guard(false, || {
        unsafe { c.as_mut() }.ok_or("null command buffer")?.scheduled.push((handler, context as usize));
        Ok(true)
    })
}

/// What the waiting thread keeps alive until the fence: every resource the stream can read.
struct Retained {
    _t: Vec<Arc<TextureObj>>,
    _b: Vec<Arc<BufferObj>>,
    _s: Vec<Arc<Slice>>,
    _p: Vec<Arc<Baked>>,
    streams: Vec<Box<NwCs>>,
    cs: Box<NwCs>,
    gpu: Arc<Gpu>,
}
// SAFETY: the stream is not touched again until the fence; then the owner thread frees it.
unsafe impl Send for Retained {}
impl Drop for Retained {
    fn drop(&mut self) {
        unsafe {
            nw_cs_finish(&mut *self.cs);
            for s in &mut self.streams {
                nw_cs_finish(&mut **s);
            }
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn nmb_command_buffer_commit(c: *mut NmbCommandBuffer) -> bool {
    guard(false, || {
        let cb = unsafe { c.as_mut() }.ok_or("null command buffer")?;
        if cb.open {
            return Err("commit with an encoder open".into());
        }
        // an event wait in this stream: the kernel has no GPU-side wait for one, so the CPU waits before the stream goes (bounded; the frontend's shared-port events are not listed here)
        for (event, value) in cb.waits.drain(..) {
            event.wait(value, 100);
        }
        let mut fence = 0u32;
        unsafe {
            nw_cs_end_ib(&mut *cb.cs);
            let mut s: NwSubmit = std::mem::zeroed();
            nw_submit_begin(&mut s, cb.gpu.dev);
            nw_submit_stream(&mut s, &mut *cb.cs);
            for &b in &cb.names {
                nw_submit_name(&mut s, b as *mut NwBoHead);
            }
            let e = nw_submit_go(&mut s, &mut fence);
            crate::flight::line(&format!("submit fence={fence} errno {e}, {} names", s.name_count));
            if crate::flight::on() {
                let mut ibs = String::from("  ibs:");
                for i in 0..(*cb.cs).ib_count as usize {
                    let ib = &*(*cb.cs).ibs.add(i);
                    ibs.push_str(&format!(" {:#x}+{}", ib.iova, ib.dwords));
                }
                crate::flight::line(&ibs);
            }
            cb.gpu.names_total.fetch_add(s.name_count as u64, Ordering::Relaxed);
            nw_submit_end(&mut s);
            if e != 0 {
                let mut st = cb.state.0.lock().unwrap();
                st.status = 5;
                st.error = if e == libc::EFAULT {
                    // nothing reached the GPU: this frame is lost, the GPU stays on
                    let why = std::ffi::CStr::from_ptr(nw_last_refusal(cb.gpu.dev)).to_string_lossy().into_owned();
                    console_line(&format!("LAUREL METAL NATIVE: stream check: a submission refused: {why}"));
                    format!("stream check: {why}")
                } else {
                    format!("the kernel refused the submission: errno {e}")
                };
                cb.state.1.notify_all();
                return Err(st.error.clone());
            }
        }
        for (h, ctx) in cb.scheduled.drain(..) {
            h(ctx as *mut c_void);
        }
        let mut replacement: Box<NwCs> = Box::new(unsafe { std::mem::zeroed() });
        unsafe { nw_cs_init(&mut *replacement, cb.gpu.dev) };
        let cs = std::mem::replace(&mut cb.cs, replacement);
        let retained = Retained { _t: std::mem::take(&mut cb.held_textures), _b: std::mem::take(&mut cb.held_buffers), _s: std::mem::take(&mut cb.held_slices), _p: std::mem::take(&mut cb.held_baked), streams: std::mem::take(&mut cb.held_streams), cs, gpu: cb.gpu.clone() };
        let handlers = std::mem::take(&mut cb.handlers);
        let signals = std::mem::take(&mut cb.signals);
        let state = cb.state.clone();
        {
            let mut st = state.0.lock().unwrap();
            st.status = 2;
            st.started = crate::misc::now_seconds();
        }
        // One thread per command buffer that waits on the kernel's fence. The kernel sleeps in the wait, so a waiting thread costs no CPU.
        let spawned = std::thread::Builder::new().name("nmn-complete".into()).spawn(move || {
            let gpu = retained.gpu.clone();
            let mut e;
            loop {
                e = unsafe { nw_fence_wait(gpu.dev, fence, 5_000_000_000) };
                if e != libc::ETIMEDOUT {
                    break;
                }
            }
            drop(retained);
            if e == libc::ENODEV {
                mark_gpu_off();
            }
            for (event, value) in signals {
                event.signal(value);
            }
            {
                let mut st = state.0.lock().unwrap();
                st.ended = crate::misc::now_seconds();
                st.status = if e == 0 { 4 } else { 5 };
                if e != 0 {
                    st.error = format!("the GPU did not finish: errno {e}");
                }
            }
            state.1.notify_all();
            for (h, ctx) in handlers {
                h(ctx as *mut c_void);
            }
        });
        spawned.map_err(|e| format!("completion thread: {e}"))?;
        Ok(true)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn nmb_command_buffer_wait_scheduled(_c: *mut NmbCommandBuffer) -> bool {
    true // a commit hands the stream to the ring before it returns
}

#[unsafe(no_mangle)]
pub extern "C" fn nmb_command_buffer_wait(c: *mut NmbCommandBuffer, timeout_ms: u64) -> i32 {
    guard(1, || {
        let cb = get(c)?;
        let mut st = cb.state.0.lock().unwrap();
        let start = std::time::Instant::now();
        while st.status < 4 {
            if timeout_ms == 0 {
                st = cb.state.1.wait(st).unwrap();
            } else {
                let left = std::time::Duration::from_millis(timeout_ms).saturating_sub(start.elapsed());
                if left.is_zero() {
                    return Ok(1);
                }
                st = cb.state.1.wait_timeout(st, left).unwrap().0;
            }
        }
        Ok(0)
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_command_buffer_status(c: *const NmbCommandBuffer) -> u64 {
    guard(5, || Ok(get(c)?.state.0.lock().unwrap().status))
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_command_buffer_error(c: *const NmbCommandBuffer, out: *mut c_char, size: usize) -> usize {
    guard(0, || {
        let cb = get(c)?;
        let st = cb.state.0.lock().unwrap();
        let bytes = st.error.as_bytes();
        let n = bytes.len().min(size.saturating_sub(1));
        unsafe {
            std::ptr::copy_nonoverlapping(bytes.as_ptr() as *const c_char, out, n);
            if size > 0 {
                *out.add(n) = 0;
            }
        }
        Ok(n)
    })
}

// ---- render encoder ----

#[repr(C)]
pub struct NmbPassAttachment {
    pub texture: *mut NmbTexture,
    pub level: u64,
    pub slice: u64,
    pub depth_plane: u64,
    pub load: u64,
    pub store: u64,
    pub clear: [f64; 4],
    pub resolve_texture: *mut NmbTexture,
    pub resolve_level: u64,
    pub resolve_slice: u64,
    pub resolve_depth_plane: u64,
}
#[repr(C)]
pub struct NmbRenderPassDescriptor {
    pub colors: [NmbPassAttachment; 8],
    pub depth: NmbPassAttachment,
    pub stencil: NmbPassAttachment,
    pub width: u64,
    pub height: u64,
    pub array_length: u64,
    pub samples: u64,
    pub visibility: *mut NmbBuffer,
}

/// A baked program of one (pipeline, plan's specialization).
pub(crate) struct Baked {
    pub(crate) gpu: Arc<Gpu>,
    pub(crate) b: usize,
    pub(crate) reads_fb: bool,
    pub(crate) program: crate::compile::Program,
}
// SAFETY: read only after baking.
unsafe impl Send for Baked {}
unsafe impl Sync for Baked {}
impl Drop for Baked {
    fn drop(&mut self) {
        unsafe { nmn_baked_free(self.gpu.gpu, self.b as *mut NmnBaked) };
    }
}

#[derive(Clone)]
pub(crate) enum BoundBuf {
    Buffer(Arc<BufferObj>, u64),
    Bytes(Vec<u8>),
}

#[derive(Default)]
pub(crate) struct StageBindings {
    pub(crate) buffers: HashMap<u32, BoundBuf>,
    pub(crate) textures: HashMap<u32, Arc<TextureObj>>,
    pub(crate) samplers: HashMap<u32, ([u32; 16], SamplerDescriptor)>,
}

pub struct NmbEncoder {
    pub(crate) cb: *mut NmbCommandBuffer,
    pub(crate) gpu: Arc<Gpu>,
    pub(crate) kind: u32, // 0 render, 1 compute, 2 blit
    pass: Option<PassRecord>,
    pub(crate) draws: Box<NwCs>,
    pub(crate) stages: [StageBindings; 3],
    pipeline: Option<*const NmbRenderPipeline>,
    pub(crate) raster: NmnRaster,
    plan_cache: HashMap<(usize, Vec<u8>), Arc<PlanEntry>>,
    attachment_written: u32,
    target_dirty: bool, // a draw of this pass wrote an attachment since the last flush: a draw that reads the target needs that flush
    pub(crate) compute: Option<ComputeState>,
}

pub(crate) struct ComputeState {
    pub pipeline: *const NmbComputePipeline,
    pub threadgroup_memory: HashMap<u32, u32>,
}

struct PassRecord {
    colors: Vec<Option<(Arc<TextureObj>, u64, u64, u64, u64, [f64; 4])>>,
    depth: Option<(Arc<TextureObj>, u32, u32)>,
    depth_load: u64,
    clear_z: f64,
    stencil: Option<(Arc<TextureObj>, u32, u32)>,
    stencil_load: u64,
    clear_s: u32,
    w: u32,
    h: u32,
    samples: u32,
}

pub(crate) struct PlanEntry {
    plan: metal2vulkan::bind::BindingPlan,
    baked: Arc<Baked>,
    offsets: HashMap<(u32, u32), (u32, u32)>,
    set_slots: Vec<u32>,
    outputs: u32,
}

#[unsafe(no_mangle)]
pub extern "C" fn nmb_render_encoder_new(c: *mut NmbCommandBuffer, d: *const NmbRenderPassDescriptor) -> *mut NmbEncoder {
    guard(std::ptr::null_mut(), || {
        let cb = unsafe { c.as_mut() }.ok_or("null command buffer")?;
        if cb.open {
            return Err("another encoder is open".into());
        }
        let d = get(d)?;
        // a view's level and slice count from its own first level and slice: the image behind it is the parent's
        let mut colors = vec![];
        let mut smallest: Option<(u64, u64)> = None;
        let mut fit = |t: &TextureObj, level: u64| {
            let (w, h) = t.level_size(level);
            smallest = Some(smallest.map_or((w, h), |s: (u64, u64)| (s.0.min(w), s.1.min(h))));
        };
        for a in &d.colors {
            if a.texture.is_null() {
                colors.push(None);
            } else {
                let t = get(a.texture)?.t.clone();
                if t.shadow().is_some() {
                    return Err("a render target with rows the GPU cannot write has no native path".into());
                }
                fit(&t, a.level);
                let (level, layer) = (t.base_level as u64 + a.level, t.base_layer as u64 + a.slice + a.depth_plane);
                colors.push(Some((t, level, layer, a.load, a.store, a.clear)));
            }
        }
        for a in [&d.depth, &d.stencil] {
            if !a.texture.is_null() {
                fit(&get(a.texture)?.t, a.level);
            }
        }
        while colors.last().is_some_and(|c| c.is_none()) {
            colors.pop();
        }
        // depth and stencil: a level and a slice of their own; one texture for both when it is Depth32Float_Stencil8
        let plane = |a: &NmbPassAttachment| -> Result<Option<(Arc<TextureObj>, u32, u32)>, String> {
            if a.texture.is_null() {
                return Ok(None);
            }
            let t = get(a.texture)?.t.clone();
            let (level, layer) = (t.base_level + a.level as u32, t.base_layer + (a.slice + a.depth_plane) as u32);
            Ok(Some((t, level, layer)))
        };
        let depth = plane(&d.depth)?;
        let stencil = plane(&d.stencil)?;
        if let Some((t, ..)) = &depth {
            if t.pipe_format == unsafe { nmn_format_from_metal(253) } {
                return Err("a Stencil8 texture as the depth attachment".into());
            }
        }
        // Metal's renderTargetWidth and renderTargetHeight stay 0 unless the caller sets them, and CoreAnimation leaves them: 0 is the attachments' size. Taken as it is, w - 1 made a clear of 16384 x 16384 that ran past a small surface: the hang of the first compositor run (FAR 0x1008000, 0x1068000). A size above an attachment's is cut to it: a target must not be written past its end.
        let (w, h) = match smallest {
            Some((sw, sh)) => (if d.width == 0 { sw } else { d.width.min(sw) }, if d.height == 0 { sh } else { d.height.min(sh) }),
            None if d.width != 0 && d.height != 0 => (d.width, d.height),
            None => return Err("a pass with no attachment and no size".into()),
        };
        let (w, h) = (w as u32, h as u32);
        let mut draws: Box<NwCs> = Box::new(unsafe { std::mem::zeroed() });
        unsafe { nw_cs_init(&mut *draws, cb.gpu.dev) };
        cb.open = true;
        let raster = default_raster(w, h);
        Ok(boxed(NmbEncoder { cb: c, gpu: cb.gpu.clone(), kind: 0, pass: Some(PassRecord { colors, depth, depth_load: d.depth.load, clear_z: d.depth.clear[0], stencil, stencil_load: d.stencil.load, clear_s: d.stencil.clear[0] as u32, w, h, samples: d.samples.max(1) as u32 }), draws, stages: Default::default(), pipeline: None, raster, plan_cache: HashMap::new(), attachment_written: 0, target_dirty: true, compute: None }))
    })
}

impl NmbEncoder {
    pub(crate) fn plain(cb: *mut NmbCommandBuffer, gpu: Arc<Gpu>, kind: u32, draws: Box<NwCs>) -> NmbEncoder {
        NmbEncoder { cb, gpu, kind, pass: None, draws, stages: Default::default(), pipeline: None, raster: default_raster(1, 1), plan_cache: HashMap::new(), attachment_written: 0, target_dirty: false, compute: None }
    }
}

pub(crate) fn default_raster(w: u32, h: u32) -> NmnRaster {
    NmnRaster { lines: false, early_z: false, viewport: [0.0, 0.0, w as f64, h as f64, 0.0, 1.0], scissor: [0, 0, w, h], cull_mode: 0, winding: 0, fill_mode: 0, depth_bias: 0.0, slope_scale: 0.0, bias_clamp: 0.0, line_width: 1.0, blend_color: [0.0; 4], stencil_front: 0, stencil_back: 0, depth_func: 7, depth_write: false, depth_test: false, reads_framebuffer: false, pass_width: w, pass_height: h, stencil_enable: false, st_func: [7, 7], st_fail: [0, 0], st_zpass: [0, 0], st_zfail: [0, 0], st_read: [0xff, 0xff], st_write: [0xff, 0xff] }
}

fn stage_index(stage: u32) -> Result<usize, String> {
    if stage < 3 { Ok(stage as usize) } else { Err(format!("stage {stage}")) }
}

#[unsafe(no_mangle)]
pub extern "C" fn nmb_encoder_set_buffer(e: *mut NmbEncoder, stage: u32, b: *mut NmbBuffer, offset: u64, index: u32) -> bool {
    guard(false, || {
        let e = unsafe { e.as_mut() }.ok_or("null encoder")?;
        let s = stage_index(stage)?;
        if b.is_null() {
            e.stages[s].buffers.remove(&index);
        } else {
            e.stages[s].buffers.insert(index, BoundBuf::Buffer(get(b)?.b.clone(), offset));
        }
        Ok(true)
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_encoder_set_buffer_offset(e: *mut NmbEncoder, stage: u32, offset: u64, index: u32) -> bool {
    guard(false, || {
        let e = unsafe { e.as_mut() }.ok_or("null encoder")?;
        match e.stages[stage_index(stage)?].buffers.get_mut(&index) {
            Some(BoundBuf::Buffer(_, o)) => {
                *o = offset;
                Ok(true)
            }
            _ => Err("setBufferOffset on no buffer".into()),
        }
    })
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nmb_encoder_set_bytes(e: *mut NmbEncoder, stage: u32, bytes: *const c_void, length: usize, index: u32) -> bool {
    guard(false, || {
        let e = unsafe { e.as_mut() }.ok_or("null encoder")?;
        let data = unsafe { std::slice::from_raw_parts(bytes as *const u8, length) }.to_vec();
        e.stages[stage_index(stage)?].buffers.insert(index, BoundBuf::Bytes(data));
        Ok(true)
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_encoder_set_texture(e: *mut NmbEncoder, stage: u32, t: *mut NmbTexture, index: u32) -> bool {
    guard(false, || {
        let e = unsafe { e.as_mut() }.ok_or("null encoder")?;
        let s = stage_index(stage)?;
        if t.is_null() {
            e.stages[s].textures.remove(&index);
        } else {
            e.stages[s].textures.insert(index, get(t)?.t.clone());
        }
        Ok(true)
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_encoder_set_sampler(e: *mut NmbEncoder, stage: u32, x: *mut NmbSampler, index: u32) -> bool {
    guard(false, || {
        let e = unsafe { e.as_mut() }.ok_or("null encoder")?;
        let s = stage_index(stage)?;
        if x.is_null() {
            e.stages[s].samplers.remove(&index);
        } else {
            let x = get(x)?;
            e.stages[s].samplers.insert(index, (x.words, x.desc.clone()));
        }
        Ok(true)
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_render_set_pipeline(e: *mut NmbEncoder, p: *mut NmbRenderPipeline) -> bool {
    guard(false, || {
        unsafe { e.as_mut() }.ok_or("null encoder")?.pipeline = Some(p);
        Ok(true)
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_render_set_viewport(e: *mut NmbEncoder, v: *const f64) -> bool {
    guard(false, || {
        let e = unsafe { e.as_mut() }.ok_or("null encoder")?;
        e.raster.viewport.copy_from_slice(unsafe { std::slice::from_raw_parts(v, 6) });
        Ok(true)
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_render_set_scissor(e: *mut NmbEncoder, r: *const u64) -> bool {
    guard(false, || {
        let e = unsafe { e.as_mut() }.ok_or("null encoder")?;
        let r = unsafe { std::slice::from_raw_parts(r, 4) };
        e.raster.scissor = [r[0] as u32, r[1] as u32, r[2] as u32, r[3] as u32];
        Ok(true)
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_render_set_raster(e: *mut NmbEncoder, cull: u64, winding: u64, fill: u64) -> bool {
    guard(false, || {
        let e = unsafe { e.as_mut() }.ok_or("null encoder")?;
        e.raster.cull_mode = cull as u32;
        e.raster.winding = winding as u32;
        e.raster.fill_mode = fill as u32;
        Ok(true)
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_render_set_stencil_reference(e: *mut NmbEncoder, front: u32, back: u32) -> bool {
    guard(false, || {
        let e = unsafe { e.as_mut() }.ok_or("null encoder")?;
        e.raster.stencil_front = front;
        e.raster.stencil_back = back;
        Ok(true)
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_render_set_blend_color(e: *mut NmbEncoder, c: *const f32) -> bool {
    guard(false, || {
        let e = unsafe { e.as_mut() }.ok_or("null encoder")?;
        e.raster.blend_color.copy_from_slice(unsafe { std::slice::from_raw_parts(c, 4) });
        Ok(true)
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_render_set_depth_bias(e: *mut NmbEncoder, bias: f32, slope: f32, clamp: f32) -> bool {
    guard(false, || {
        let e = unsafe { e.as_mut() }.ok_or("null encoder")?;
        e.raster.depth_bias = bias;
        e.raster.slope_scale = slope;
        e.raster.bias_clamp = clamp;
        Ok(true)
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_render_set_line_width(e: *mut NmbEncoder, w: f32) -> bool {
    guard(false, || {
        unsafe { e.as_mut() }.ok_or("null encoder")?.raster.line_width = w;
        Ok(true)
    })
}

pub(crate) fn build_state(e: &NmbEncoder) -> Result<BindState, String> {
    let mut state = BindState::default();
    for (i, stage) in [Stage::Kernel, Stage::Vertex, Stage::Fragment].iter().enumerate() {
        let b = &e.stages[i];
        if b.buffers.is_empty() && b.textures.is_empty() && b.samplers.is_empty() {
            continue;
        }
        let mut table = StageTable::default();
        for (k, v) in &b.buffers {
            table.buffers.insert(
                *k,
                match v {
                    BoundBuf::Buffer(buf, offset) => BoundBuffer::Buffer { length: buf.length, offset: *offset, gpu_address: buf.backing.iova(), device_address: None, attribute_stride: None },
                    BoundBuf::Bytes(d) => BoundBuffer::Bytes { len: d.len() as u32, attribute_stride: None },
                },
            );
        }
        for (k, t) in &b.textures {
            table.textures.insert(*k, BoundTexture::Texture { facts: t.facts()?, resource_id: None });
        }
        for (k, s) in &b.samplers {
            table.samplers.insert(*k, BoundSampler::new(s.1.clone()));
        }
        state.stages.insert(*stage, table);
    }
    Ok(state)
}

/// The plan and the program for this shape. The second call for a shape is a hash lookup. No Vulkan pipeline exists: a specialization is one more ir3 compile, at most once.
fn plan_entry(e: &mut NmbEncoder, device_pipeline: &NmbRenderPipeline, state: &BindState) -> Result<Arc<PlanEntry>, String> {
    let shape = state.shape();
    let key = (device_pipeline as *const _ as usize, format!("{shape:?}").into_bytes());
    if let Some(p) = e.plan_cache.get(&key) {
        return Ok(p.clone());
    }
    let cached = device_pipeline.plans.lock().unwrap().get(&key.1).cloned();
    if let Some(p) = cached {
        e.plan_cache.insert(key, p.clone());
        return Ok(p);
    }
    let dev = unsafe { device_pipeline.device.as_ref() }.ok_or("the pipeline's device")?;
    let pipeline = &device_pipeline.pipeline;
    let plan = pipeline.plan(&dev.device, &shape).map_err(|x| format!("plan: {x:?}"))?;
    if !plan.variant.is_empty() {
        return Err(format!("this draw asks for pipeline variant {:?}, which has no native path yet", plan.variant));
    }
    let spec: Vec<NmnSpec> = plan.specialization.entries.iter().map(|m| {
        let at = m.offset as usize;
        let mut w = [0u8; 4];
        let n = (m.size as usize).min(4);
        w[..n].copy_from_slice(&plan.specialization.data[at..at + n]);
        NmnSpec { id: m.constant_id, value: u32::from_le_bytes(w) }
    }).collect();
    let program = crate::compile::cached_program(&dev.cache, dev.compiler, &device_pipeline.key, &spec, || crate::compile::render_program_spec(dev.compiler, pipeline, &spec))?;
    let bindings = crate::compile::lay_out(&pipeline.layout)?;
    let mut offsets = HashMap::new();
    let mut set_slots = vec![];
    for b in &bindings {
        offsets.insert((b.set, b.binding), (b.offset, b.stride));
        if set_slots.len() <= b.set as usize {
            set_slots.resize(b.set as usize + 1, 0);
        }
        // a heap array is counted only to the element a plan names: its full count is the profile's maximum
        set_slots[b.set as usize] = set_slots[b.set as usize].max(b.offset + b.stride * b.count.min(4096));
    }
    let fixed = fixed_state(device_pipeline, pipeline)?;
    let mut why = [0 as c_char; 256];
    let fs = unsafe { nmn_program_variant(program.0, 1) };
    let baked = unsafe { nmn_bake_render(e.gpu.gpu, nmn_program_variant(program.0, 0), fs, &fixed, why.as_mut_ptr(), why.len()) };
    if baked.is_null() {
        return Err(unsafe { std::ffi::CStr::from_ptr(why.as_ptr()) }.to_string_lossy().into_owned());
    }
    let reads_fb = program.stage_info(1).is_some_and(|i| i.reads_framebuffer);
    let outputs = program.stage_info(1).map_or(0, |i| i.color_outputs);
    // the file only: one line a program, at its first use in this process. The last of these before a GPU hang names the suspect; a hang's process is killed, so nothing later can say it
    {
        let f = program.stage_info(1).unwrap_or_default();
        file_line(&format!("native-metal: program {}: {} fragment instructions, {} texture reads, reads the target: {reads_fb}", device_pipeline.names, f.instructions, f.tex_ops));
    }
    let entry = Arc::new(PlanEntry { plan, baked: Arc::new(Baked { gpu: e.gpu.clone(), b: baked as usize, reads_fb, program }), offsets, set_slots, outputs });
    device_pipeline.plans.lock().unwrap().insert(key.1.clone(), entry.clone());
    e.plan_cache.insert(key, entry.clone());
    Ok(entry)
}

/// The descriptor's blend and vertex state, in the native program's terms.
fn fixed_state(p: &NmbRenderPipeline, r: &metal2vulkan::pipeline::RenderPipeline) -> Result<NmnFixed, String> {
    let mut f: NmnFixed = unsafe { std::mem::zeroed() };
    let d = &p.fixed;
    let mut count = 0;
    for (i, c) in d.colors.iter().enumerate() {
        if c.format == 0 {
            continue;
        }
        count = i as u32 + 1;
        f.blend[i] = NmnBlend { enable: c.blending != 0, src_rgb: c.source_rgb, dst_rgb: c.destination_rgb, op_rgb: c.rgb_operation, src_a: c.source_alpha, dst_a: c.destination_alpha, op_a: c.alpha_operation, write_mask: c.write_mask };
    }
    f.color_count = count;
    f.samples = d.samples;
    f.rasterizer_discard = r.graphics.rasterizer_discard;
    for a in &r.vertex_input.attributes {
        let i = a.location as usize;
        if i >= f.attrs.len() {
            return Err("vertex attribute location".into());
        }
        let Some(pipe) = crate::compile::vertex_format_pipe(a.format) else {
            return Err(format!("vertex format {:?} has no native path", a.format));
        };
        let binding = r.vertex_input.bindings.iter().find(|b| b.binding == a.binding);
        f.attrs[i] = NmnVertexAttr { pipe_format: pipe, offset: a.offset, binding: a.binding, instanced: binding.is_some_and(|b| b.input_rate == vk::VertexInputRate::INSTANCE), step_rate: 1, is_float: crate::compile::vertex_format_is_float(a.format) };
        f.attr_count = f.attr_count.max(i as u32 + 1);
    }
    Ok(f)
}

/// Descriptor sets in the upload ring: no pools, no updates, no copies. Returns each set's address and its words.
pub(crate) fn write_descriptors(e: &mut NmbEncoder, cb: &mut NmbCommandBuffer, descriptors: &[metal2vulkan::bind::DescriptorWrite], ranges: &[metal2vulkan::bind::DescriptorRange], offsets: &HashMap<(u32, u32), (u32, u32)>, set_slots_x: &[u32], layout: &metal2vulkan::pipeline::PipelineLayout) -> Result<Vec<(u64, *mut u32)>, String> {
    // descriptor sets in the upload ring: no pools, no updates, no copies
    let mut set_memory: Vec<(u64, *mut u32)> = vec![];
    for slots in set_slots_x {
        let (iova, map) = cb.upload((*slots as u64).max(1) * SLOT_BYTES as u64, 64)?;
        unsafe { std::ptr::write_bytes(map, 0, (*slots as usize).max(1) * SLOT_BYTES) };
        set_memory.push((iova, map as *mut u32));
    }
    for w in descriptors {
        let (offset, stride) = *offsets.get(&(w.set, w.binding)).ok_or("a descriptor with no slot")?;
        let at = (offset + stride * w.array_element) as usize;
        let slot = unsafe { set_memory.get(w.set as usize).ok_or("set")?.1.add(at * 16) };
        let range = ranges.iter().find(|r| r.set == w.set && r.binding == w.binding);
        match &w.source {
            WriteSource::Buffer { slot: s } | WriteSource::InlineBytes { slot: s } => {
                let bound = e.stages[stage_slot(s.stage)?].buffers.get(&s.index).cloned();
                let (iova, length) = match &bound {
                    Some(BoundBuf::Buffer(b, off)) => {
                        if b.backing.must_name() {
                            cb.names.push(b.backing.bo() as usize);
                        }
                        cb.held_buffers.push(b.clone());
                        let r = range.map(|r| r.range);
                        // a range past the buffer's end (the planner's whole size) stops at its end: the shader's bounds come from this descriptor
                        let at = r.map_or(*off, |r| r.offset);
                        let left = b.length.saturating_sub(at);
                        (b.backing.iova() + at, r.map_or(left, |r| r.range.min(left)))
                    }
                    Some(BoundBuf::Bytes(d)) => {
                        let (iova, map) = cb.upload((d.len() as u64).max(16), 64)?;
                        unsafe { std::ptr::copy_nonoverlapping(d.as_ptr(), map, d.len()) };
                        (iova, d.len() as u64)
                    }
                    None => (e.gpu.zero_iova(), 65536),
                };
                write_buffer_descriptor(e.gpu.dev, w.ty, iova, length, slot)?;
            }
            WriteSource::Texture { slot: s, view } => write_texture(e, cb, s.stage, s.index, Some(view), w.ty == vk::DescriptorType::STORAGE_IMAGE, slot)?,
            WriteSource::CombinedImageSampler { image, sampler } => {
                match image {
                    metal2vulkan::bind::ImageSource::Texture { slot: s, view } => write_texture(e, cb, s.stage, s.index, Some(view), false, slot)?,
                    metal2vulkan::bind::ImageSource::Neutral(metal2vulkan::bind::NeutralResource::Image { view_type, .. }) => write_neutral_image(e, *view_type, slot)?,
                    other => return Err(format!("image source {other:?} has no native path yet")),
                }
                let second = unsafe { slot.add(16) };
                match sampler {
                    metal2vulkan::bind::SamplerSource::Slot { slot: s, .. } => {
                        let x = e.stages[stage_slot(s.stage)?].samplers.get(&s.index).ok_or("no sampler bound")?;
                        unsafe { std::ptr::copy_nonoverlapping(x.0.as_ptr(), second, 16) };
                    }
                    metal2vulkan::bind::SamplerSource::Neutral(_) => write_neutral_sampler(second),
                    metal2vulkan::bind::SamplerSource::Immutable => {
                                                let d = layout.sets.iter().find(|x| x.set == w.set).and_then(|x| x.bindings.iter().find(|b| b.binding == w.binding)).and_then(|b| b.immutable_sampler.as_ref()).ok_or("an immutable sampler the layout does not name")?;
                        write_immutable_sampler(d, second);
                    }
                    other => return Err(format!("sampler source {other:?} has no native path yet")),
                }
            }
            WriteSource::Sampler { slot: s, .. } => {
                let x = e.stages[stage_slot(s.stage)?].samplers.get(&s.index).ok_or("no sampler bound")?;
                unsafe { std::ptr::copy_nonoverlapping(x.0.as_ptr(), slot, 16) };
            }
            WriteSource::Neutral(n) => match n {
                metal2vulkan::bind::NeutralResource::ZeroBuffer { .. } | metal2vulkan::bind::NeutralResource::Sink { .. } => write_buffer_descriptor(e.gpu.dev, w.ty, e.gpu.zero_iova(), 65536, slot)?,
                metal2vulkan::bind::NeutralResource::Sampler { .. } => write_neutral_sampler(slot),
                metal2vulkan::bind::NeutralResource::Image { view_type, .. } => write_neutral_image(e, *view_type, slot)?,
                other => return Err(format!("neutral resource {other:?} has no native path yet")),
            },
            WriteSource::Attachment { color_index } => {
                let pass = e.pass.as_ref().ok_or("an attachment outside a pass")?;
                let (t, level, layer, ..) = pass.colors.get(*color_index as usize).and_then(|c| c.as_ref()).ok_or("the fetched attachment is not bound")?;
                let identity = [0u8, 1, 2, 3];
                unsafe { nmn_descriptor_image(t.image as *const NmnImage, t.pipe_format, NMN_IMAGE_2D, *level as u32, 1, *layer as u32, 1, identity.as_ptr(), false, slot) };
                e.attachment_written |= 1 << color_index;
            }
            other => return Err(format!("descriptor source {other:?} has no native path yet")),
        }
    }

    Ok(set_memory)
}

/// One draw: the plan decides, this writes it.
fn emit_draw(e: &mut NmbEncoder, draw: DrawCall, index: Option<(Arc<BufferObj>, u64, bool, i32)>, arguments: Option<(Arc<BufferObj>, u64)>, primitive: u32, counts: (u32, u32, u32, u32)) -> Result<(), String> {
    let pipeline_ptr = e.pipeline.ok_or("a draw with no pipeline")?;
    let device_pipeline = unsafe { pipeline_ptr.as_ref() }.ok_or("the pipeline")?;
    let state = build_state(e)?;
    let entry = plan_entry(e, device_pipeline, &state)?;
    let commands = entry.plan.instantiate_draw(&state, &draw).map_err(|x| format!("draw: {x:?}"))?;
    // what a draw needs beside its descriptors and constants. Each of these fills memory or a pointer the shader reads: left out, the shader reads garbage and the GPU can fault. Refused, with the reason in the line
    if !commands.descriptor_bytes.is_empty() {
        return Err(format!("this draw uploads {} descriptor tables (argument or handle tables), which have no native path yet", commands.descriptor_bytes.len()));
    }
    if !commands.root_tables.is_empty() || !commands.push_holes.is_empty() {
        return Err(format!("this draw needs {} root tables and {} address holes in its constants, which have no native path yet", commands.root_tables.len(), commands.push_holes.len()));
    }
    if commands.indirect_needs_arguments {
        return Err("this indirect draw needs its arguments in the planner's hands, which has no native path yet".into());
    }
    if !commands.amplifications.is_empty() || commands.mesh_dispatch.is_some() || commands.tessellation_dispatch.is_some() || commands.mesh_arguments.is_some() || commands.object_fold.is_some() || commands.index_bounds_pass || commands.index_overrun.is_some() {
        return Err("this draw needs a pass before it (amplification, mesh, tessellation, an index check), which has no native path yet".into());
    }
    let cb = unsafe { e.cb.as_mut() }.ok_or("the command buffer")?;
    cb.held_baked.push(entry.baked.clone());

    let set_memory = write_descriptors(e, cb, &entry.plan.descriptors, &commands.descriptor_ranges, &entry.offsets, &entry.set_slots, &device_pipeline.pipeline.layout)?;
    let mark = if crate::flight::on() { crate::flight::next_mark(&cb.gpu) } else { None };
    if crate::flight::on() {
        let at = unsafe { e.draws.start_iova + (e.draws.cur as u64).wrapping_sub(e.draws.start as u64) };
        crate::flight::line(&format!("draw {} prim {primitive} counts {counts:?} at {at:#x} id {}", device_pipeline.names, mark.map_or(0, |m| m.1)));
        // lite: a program with no private memory stays one line: most draws
        let mut facts_lite = [0 as std::ffi::c_char; 8];
        if !crate::flight::lite() || unsafe { nmn_baked_describe(entry.baked.b as *const NmnBaked, facts_lite.as_mut_ptr(), facts_lite.len()) } {
        for (i, s) in set_memory.iter().enumerate() {
            crate::flight::line(&crate::flight::set_words(i, s.0, s.1, entry.set_slots.get(i).copied().unwrap_or(0)));
        }
        let mut facts = [0 as std::ffi::c_char; 400];
        let private = unsafe { nmn_baked_describe(entry.baked.b as *const NmnBaked, facts.as_mut_ptr(), facts.len()) };
        crate::flight::line(&format!("  program: {}", unsafe { std::ffi::CStr::from_ptr(facts.as_ptr()) }.to_string_lossy()));
        if private {
            // what such a large program reads: its uniform buffers, for a comparison of a draw that stops with one that ended
            for (i, m) in set_memory.iter().enumerate() {
                let slots = entry.set_slots.get(i).copied().unwrap_or(0) as usize;
                for slot in 0..slots.min(64) {
                    let w = unsafe { std::slice::from_raw_parts(m.1.add(slot * 16), 16) };
                    // a UBO descriptor: address, size in vec4 from bit 17; the rest 0
                    if w[1] >> 17 == 0 || w[1] & 0x1ffff != 0 || w[2..].iter().any(|x| *x != 0) {
                        continue;
                    }
                    let (iova, bytes) = (w[0] as u64, ((w[1] >> 17) as u64 * 16).min(512));
                    let bo = unsafe { nw_bo_of_address(cb.gpu.dev, iova, bytes) };
                    if bo.is_null() || unsafe { (*bo).map.is_null() } {
                        continue;
                    }
                    let data = unsafe { std::slice::from_raw_parts(((*bo).map as *const u8).add((iova - (*bo).iova) as usize), bytes as usize) };
                    crate::flight::line(&format!("  ubo {slot} {iova:#x}: {}", crate::flight::hex(data)));
                }
            }
        }
        for (k, b) in [("v", 1usize), ("f", 2)] {
            for (slot, t) in &e.stages[b].textures {
                crate::flight::line(&format!("  {k} texture {slot}: format {} {}x{} at {:#x}{}", t.desc.format, t.desc.width, t.desc.height, unsafe { nmn_image_iova(t.image as *const NmnImage) }, if t.memoryless { " memoryless" } else { "" }));
            }
        }
        for w in &commands.push_constants {
            crate::flight::line(&format!("  push at {} stages {:?}: {}", w.offset, w.stages, crate::flight::hex(&w.bytes)));
        }
            }
    }

    let cs: *mut NwCs = &mut *e.draws;
    unsafe {
        // In sysmem the fragment reads the target through the texture path while the pixels of the draws before it are in the CCU: Metal's rule is that it sees them. GRAS_SC_CNTL's per-overlap flush covers the primitives
        // of one draw. Without this: wrong pixels in blocks of a cache line (RenderBox's paths: stripes, no text). In GMEM Turnip has no such need; a Vulkan self-dependency does the same.
        if entry.baked.reads_fb && e.target_dirty {
            nmn_cmd_barrier(cs);
            e.target_dirty = false;
        }
        e.target_dirty |= entry.outputs != 0;
        // program first: its stream invalidates constants and state, and what follows is the draw's own
        nmn_cmd_program(cs, entry.baked.b as *const NmnBaked);
        let sets: Vec<u64> = set_memory.iter().map(|s| s.0).collect();
        if !sets.is_empty() {
            nmn_cmd_descriptor_sets(cs, sets.as_ptr(), sets.len() as u32, true);
        }
        let mut raster = e.raster;
        raster.reads_framebuffer = entry.baked.reads_fb;
        // MTLPrimitiveType: 1 line, 2 line strip. Turnip's register for lines at one sample: Bresenham, no polygon offset. The rectangular form is for MSAA; these draws marked each hang of 08:39 and 08:54
        raster.lines = primitive == 1 || primitive == 2;
        // a state's depth or stencil test acts only on a pass that has that attachment (Metal's rule)
        let (has_depth, has_stencil) = e.pass.as_ref().map_or((false, false), |p| (p.depth.is_some(), p.stencil.is_some()));
        raster.depth_test &= has_depth;
        raster.depth_write &= has_depth;
        raster.stencil_enable &= has_stencil;
        // tu6_build_depth_plane_z_mode: late when the fragment can be killed after it wrote, when the shader writes depth, and when no depth test runs
        let fs = entry.baked.program.stage_info(1);
        let stencil_writes = raster.stencil_enable && (0..2).any(|i| raster.st_write[i] != 0 && (raster.st_fail[i] != 0 || raster.st_zpass[i] != 0 || raster.st_zfail[i] != 0));
        let writes = (raster.depth_test && raster.depth_write) || stencil_writes;
        let stencil_only = e.pass.as_ref().and_then(|p| p.stencil.as_ref()).is_some_and(|x| x.0.pipe_format == nmn_format_from_metal(253));
        let (kill, late, early_tests) = fs.map_or((false, false, false), |i| (i.has_kill, i.no_early_z, i.early_tests));
        raster.early_z = early_tests || (raster.depth_test && !(kill && writes) && !late && !stencil_only);
        nmn_cmd_raster(cs, &raster);
        // the push range of each stage
        for w in &commands.push_constants {
            let stages = [(vk::ShaderStageFlags::VERTEX, 0u32), (vk::ShaderStageFlags::FRAGMENT, 1u32)];
            for (flag, stage) in stages {
                if !w.stages.contains(flag) {
                    continue;
                }
                let (mut first, mut vec4s, mut lo) = (0u32, 0u32, 0u32);
                if !nmn_program_push_range(entry.baked.program.0, stage, &mut first, &mut vec4s, &mut lo) || vec4s == 0 {
                    continue;
                }
                let mut image = vec![0u8; vec4s as usize * 16];
                let lo_bytes = lo as usize * 4;
                for (i, byte) in w.bytes.iter().enumerate() {
                    let at = w.offset as usize + i;
                    if at >= lo_bytes && at - lo_bytes < image.len() {
                        image[at - lo_bytes] = *byte;
                    }
                }
                nmn_cmd_push(cs, stage, first, image.as_ptr() as *const c_void, vec4s);
            }
        }
        // vertex buffers
        let mut iova = vec![];
        let mut size = vec![];
        let mut stride = vec![];
        for v in &entry.plan.vertex_buffers {
            let binding = v.binding as usize;
            if iova.len() <= binding {
                iova.resize(binding + 1, 0u64);
                size.resize(binding + 1, 0u32);
                stride.resize(binding + 1, 0u32);
            }
            let bound = e.stages[1].buffers.get(&v.buffer_index).cloned();
            let (mut address, length) = match &bound {
                Some(BoundBuf::Buffer(b, off)) => {
                    if b.backing.must_name() {
                        cb.names.push(b.backing.bo() as usize);
                    }
                    cb.held_buffers.push(b.clone());
                    (b.backing.iova() + off, b.length - off)
                }
                Some(BoundBuf::Bytes(d)) => {
                    let (a, map) = cb.upload((d.len() as u64).max(16), 64)?;
                    std::ptr::copy_nonoverlapping(d.as_ptr(), map, d.len());
                    (a, d.len() as u64)
                }
                None => (e.gpu.zero_iova(), 65536),
            };
            if let Some(o) = commands.buffer_offsets.iter().find(|o| o.0 == v.binding) {
                address = address - bound_offset(&bound) + o.1;
            }
            iova[binding] = address;
            size[binding] = length as u32;
            stride[binding] = commands.vertex_strides.iter().find(|s| s.0 == v.binding).map(|s| s.1).or_else(|| device_pipeline.pipeline.vertex_input.bindings.iter().find(|b| b.binding == v.binding).and_then(|b| match b.stride { metal2vulkan::pipeline::VertexStride::Static(s) => Some(s), _ => None })).unwrap_or(0);
        }
        nmn_cmd_vertex_buffers(cs, iova.as_ptr(), size.as_ptr(), stride.as_ptr(), iova.len() as u32);
        let (count, instances, first, first_instance) = counts;
        if let Some((a, at)) = &arguments {
            let (index_iova, max, wide) = match &index {
                Some((b, offset, wide, _)) => (b.backing.iova() + offset, ((b.length - offset) / if *wide { 4 } else { 2 }) as u32, *wide),
                None => (0, 0, false),
            };
            if a.backing.must_name() {
                cb.names.push(a.backing.bo() as usize);
            }
            nmn_cmd_draw_indirect(cs, primitive, a.backing.iova() + at, index_iova, max, wide);
            match mark {
                Some((word, id)) => nmn_cmd_progress(cs, word, id),
                None => nmn_cmd_draw_end(cs),
            }
            cb.held_buffers.push(a.clone());
            if let Some((b, ..)) = index {
                if b.backing.must_name() {
                    cb.names.push(b.backing.bo() as usize);
                }
                cb.held_buffers.push(b);
            }
            e.attachment_written |= entry.outputs;
            return Ok(());
        }
        match index {
            Some((b, offset, wide, base)) => {
                if b.backing.must_name() {
                    cb.names.push(b.backing.bo() as usize);
                }
                let cpp = if wide { 4 } else { 2 };
                nmn_cmd_draw_indexed(cs, primitive, count, instances, b.backing.iova() + offset, ((b.length - offset) / cpp) as u32, wide, base, first_instance);
                cb.held_buffers.push(b);
            }
            None => nmn_cmd_draw(cs, primitive, count, instances, first, first_instance),
        }
        match mark {
            Some((word, id)) => nmn_cmd_progress(cs, word, id),
            None => nmn_cmd_draw_end(cs),
        }
    }
    e.attachment_written |= entry.outputs;
    Ok(())
}

fn bound_offset(b: &Option<BoundBuf>) -> u64 {
    match b {
        Some(BoundBuf::Buffer(_, o)) => *o,
        _ => 0,
    }
}

fn stage_slot(s: Stage) -> Result<usize, String> {
    match s {
        Stage::Kernel => Ok(0),
        Stage::Vertex => Ok(1),
        Stage::Fragment => Ok(2),
        other => Err(format!("stage {other:?} has no native path")),
    }
}

/// A constexpr sampler of the shader, from the translator's Vulkan-shaped description.
fn write_immutable_sampler(d: &vk::SamplerDesc, slot: *mut u32) {
    let address = |m: vk::SamplerAddressMode| match m {
        vk::SamplerAddressMode::REPEAT => 2u32,
        vk::SamplerAddressMode::MIRRORED_REPEAT => 3,
        vk::SamplerAddressMode::CLAMP_TO_BORDER => 5,
        vk::SamplerAddressMode::MIRROR_CLAMP_TO_EDGE => 1,
        _ => 0,
    };
    let linear = |f: vk::Filter| u32::from(f == vk::Filter::LINEAR);
    let state = NmnSamplerState { min_filter: linear(d.min_filter), mag_filter: linear(d.mag_filter), mip_filter: if d.mipmap_mode == vk::SamplerMipmapMode::LINEAR { 2 } else { 1 }, s_address: address(d.address_mode_u), t_address: address(d.address_mode_v), r_address: address(d.address_mode_w), border_color: 0, normalized: 1, max_anisotropy: 1, compare: 0, lod_min: d.min_lod, lod_max: d.max_lod };
    unsafe { nmn_descriptor_sampler(&state, 0, slot) };
}

fn write_neutral_sampler(slot: *mut u32) {
    let state = NmnSamplerState { min_filter: 0, mag_filter: 0, mip_filter: 0, s_address: 0, t_address: 0, r_address: 0, border_color: 0, normalized: 1, max_anisotropy: 1, compare: 0, lod_min: 0.0, lod_max: 0.0 };
    unsafe { nmn_descriptor_sampler(&state, 0, slot) };
}

/// A slot the shader declares and nothing is bound to: one texel of zeros of the view's kind, kept for the device's life.
fn write_neutral_image(e: &NmbEncoder, view: vk::ImageViewType, slot: *mut u32) -> Result<(), String> {
    let (key, kind, layers) = match view {
        vk::ImageViewType::CUBE | vk::ImageViewType::CUBE_ARRAY => (2u32, NMN_IMAGE_CUBE, 6u32),
        vk::ImageViewType::TYPE_3D => (3, NMN_IMAGE_3D, 1),
        vk::ImageViewType::TYPE_1D | vk::ImageViewType::TYPE_1D_ARRAY => (1, NMN_IMAGE_1D, 1),
        _ => (0, NMN_IMAGE_2D, 1),
    };
    let t = e.gpu.neutral_image(key, kind, layers)?;
    let identity = [0u8, 1, 2, 3];
    unsafe { nmn_descriptor_image(t.image as *const NmnImage, t.pipe_format, kind, 0, 1, 0, layers, identity.as_ptr(), false, slot) };
    Ok(())
}

/// One line in metal.log only: for what is too many lines for the console.
pub(crate) fn file_line(text: &str) {
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new().append(true).open("/private/var/db/negronimetal/metal.log") {
        let name = std::env::current_exe().ok().and_then(|p| p.file_name().map(|n| n.to_string_lossy().into_owned())).unwrap_or_default();
        let _ = f.write_all(format!("NMTL[{} {}]: {}\n", std::process::id(), name, text).as_bytes());
    }
}

/// One line where the selector's lines go: the console (the USB log) and metal.log. Failure of a log is nothing.
pub(crate) fn console_line(text: &str) {
    use std::io::Write;
    let name = std::env::current_exe().ok().and_then(|p| p.file_name().map(|n| n.to_string_lossy().into_owned())).unwrap_or_default();
    let line = format!("NMTL[{} {}]: {}\n", std::process::id(), name, text);
    eprint!("{line}");
    for path in ["/dev/console", "/private/var/db/negronimetal/metal.log"] {
        if let Ok(mut f) = std::fs::OpenOptions::new().append(true).open(path) {
            let _ = f.write_all(line.as_bytes());
        }
    }
}

/// ENODEV from a fence: the kernel turned the GPU off (a hang), for every stack, until a reboot. The compositor reports it; the next start marks this build as failed (option_store.h). The kernel kills backboardd at a hang, often first [V logs 06:47:15, 06:49:22: no line of this function]: then the selector's own count and "no device" do it.
fn mark_gpu_off() {
    static DONE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
    if DONE.swap(true, Ordering::Relaxed) {
        return;
    }
    let compositor = std::env::current_exe().ok().is_some_and(|p| p.file_name().is_some_and(|n| n == "backboardd"));
    if compositor {
        // on the disk before the next start: option_store.h turns it into this build's mark
        let written = (|| -> std::io::Result<()> {
            use std::io::Write;
            let dir = "/private/var/db/negronimetal/stack";
            let mut f = std::fs::File::create(format!("{dir}/failed"))?;
            f.write_all(b"the kernel turned the GPU off\n")?;
            f.sync_all()?;
            std::fs::File::open(dir)?.sync_all()
        })();
        if let Err(x) = written {
            console_line(&format!("LAUREL METAL NATIVE: stack/failed cannot be written: {x}"));
        }
        console_line("LAUREL METAL NATIVE: off: the kernel turned the GPU off: the next start takes stack default");
    }
}

/// A descriptor's address reaches the GPU with no packet around it, so nw_stream_check cannot read it. It is checked where it is written.
pub(crate) fn check_descriptor_address(dev: *mut NwDevice, iova: u64, bytes: u64) -> Result<(), String> {
    if iova != 0 && unsafe { nw_bo_of_address(dev, iova, bytes.max(1)) }.is_null() {
        return Err(format!("stream check: a descriptor at {iova:#x} of {bytes} bytes: no live buffer holds it"));
    }
    Ok(())
}

fn write_buffer_descriptor(dev: *mut NwDevice, ty: vk::DescriptorType, iova: u64, length: u64, slot: *mut u32) -> Result<(), String> {
    check_descriptor_address(dev, iova, length)?;
    match ty {
        vk::DescriptorType::UNIFORM_BUFFER | vk::DescriptorType::UNIFORM_BUFFER_DYNAMIC => unsafe { nmn_descriptor_ubo(iova, length, slot) },
        vk::DescriptorType::STORAGE_BUFFER | vk::DescriptorType::STORAGE_BUFFER_DYNAMIC => unsafe { nmn_descriptor_ssbo(iova, length, slot) },
        other => return Err(format!("a buffer in descriptor type {other:?}")),
    }
    Ok(())
}

/// The plan's channel mapping (Metal's texture swizzle, and the swizzle a format's emulation needs), as Mesa's PIPE_SWIZZLE: x, y, z, w, 0, 1.
fn swizzle_of(view: Option<&metal2vulkan::bind::ImageViewDesc>) -> [u8; 4] {
    let mut out = [0u8, 1, 2, 3];
    if let Some(v) = view {
        let c = v.components;
        for (i, s) in [c.r, c.g, c.b, c.a].into_iter().enumerate() {
            out[i] = match s {
                vk::ComponentSwizzle::R => 0,
                vk::ComponentSwizzle::G => 1,
                vk::ComponentSwizzle::B => 2,
                vk::ComponentSwizzle::A => 3,
                vk::ComponentSwizzle::ZERO => 4,
                vk::ComponentSwizzle::ONE => 5,
                _ => i as u8,
            };
        }
    }
    out
}

fn write_texture(e: &NmbEncoder, cb: &mut NmbCommandBuffer, stage: Stage, index: u32, view: Option<&metal2vulkan::bind::ImageViewDesc>, storage: bool, slot: *mut u32) -> Result<(), String> {
    let t = e.stages[stage_slot(stage)?].textures.get(&index).ok_or("a texture slot with nothing bound")?.clone();
    let swizzle = swizzle_of(view);
    // the first level the view reaches, up to its last layer: a read past the buffer's end is a fault as a write is
    check_descriptor_address(e.gpu.dev, unsafe { nmn_image_iova(t.image as *const NmnImage) }, unsafe { nmn_image_extent(t.image as *const NmnImage, t.base_level, t.base_layer + t.layers.max(1) - 1) })?;
    unsafe { nmn_descriptor_image(t.image as *const NmnImage, t.pipe_format, t.view_type, t.base_level, t.levels, t.base_layer, t.layers, swizzle.as_ptr(), storage, slot) };
    if let Some(shadow) = t.shadow() {
        // the rows as the CPU sees them now, once in a command buffer: the image lies in the copy (Shadow). Without this the GPU read old memory: blank icons, masks of sparse dots
        if !cb.shadows_done.contains(&t.root_id()) {
            let source = t.root_backing().ok_or("a shadow with no buffer")?;
            let from = source.backing.map() as *const u8;
            if from.is_null() {
                return Err("a shadow over a buffer with no CPU mapping".into());
            }
            let fits = source.length.saturating_sub(shadow.offset);
            let rows = if shadow.row == 0 { 0 } else { shadow.rows.min((fits + shadow.row - shadow.line.min(fits)) / shadow.row) };
            for y in 0..rows {
                let start = y * shadow.row;
                unsafe { std::ptr::copy_nonoverlapping(from.add((shadow.offset + start) as usize), (shadow.copy.map as *mut u8).add((y * shadow.pitch) as usize), shadow.line.min(fits - start) as usize) };
            }
            cb.shadows_done.push(t.root_id());
        }
        if unsafe { (*shadow.copy.bo()).kind == NW_BO_SCATTERED } {
            cb.names.push(shadow.copy.bo() as usize);
        }
    } else if t.must_name() {
        cb.names.push(t.bo() as usize);
    }
    cb.held_textures.push(t);
    Ok(())
}

#[unsafe(no_mangle)]
pub extern "C" fn nmb_render_draw(e: *mut NmbEncoder, primitive: u64, start: u32, count: u32, instances: u32, base_instance: u32) -> bool {
    guard(false, || {
        let e = unsafe { e.as_mut() }.ok_or("null encoder")?;
        let draw = DrawCall::Primitives { vertex_start: start, vertex_count: count, instance_count: instances, base_instance };
        let _ = PrimitiveType::try_from(primitive as u32).map_err(|_| "primitive type")?;
        emit_draw(e, draw, None, None, primitive as u32, (count, instances, start, base_instance))?;
        Ok(true)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn nmb_render_draw_indexed(e: *mut NmbEncoder, primitive: u64, count: u32, index_type: u64, indices: *mut NmbBuffer, offset: u64, instances: u32, base_vertex: i32, base_instance: u32) -> bool {
    guard(false, || {
        let e = unsafe { e.as_mut() }.ok_or("null encoder")?;
        let b = get(indices)?.b.clone();
        let wide = index_type == 1;
        let it = if wide { vk::IndexType::UINT32 } else { vk::IndexType::UINT16 };
        let draw = DrawCall::Indexed { index_count: count, index_type: it, index_buffer: metal2vulkan::bind::IndexBufferRef::new(0, b.length), index_offset: offset, instance_count: instances, base_vertex, base_instance };
        emit_draw(e, draw, Some((b, offset, wide, base_vertex)), None, primitive as u32, (count, instances, 0, base_instance))?;
        Ok(true)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn nmb_render_draw_indirect(e: *mut NmbEncoder, primitive: u64, b: *mut NmbBuffer, offset: u64) -> bool {
    guard(false, || {
        let e = unsafe { e.as_mut() }.ok_or("null encoder")?;
        let a = get(b)?.b.clone();
        let draw = DrawCall::Indirect { indirect: metal2vulkan::bind::IndirectRef::new(0, offset), indexed: None };
        emit_draw(e, draw, None, Some((a, offset)), primitive as u32, (0, 0, 0, 0))?;
        Ok(true)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn nmb_render_draw_indexed_indirect(e: *mut NmbEncoder, primitive: u64, index_type: u64, indices: *mut NmbBuffer, index_offset: u64, b: *mut NmbBuffer, offset: u64) -> bool {
    guard(false, || {
        let e = unsafe { e.as_mut() }.ok_or("null encoder")?;
        let (i, a) = (get(indices)?.b.clone(), get(b)?.b.clone());
        let wide = index_type == 1;
        let it = if wide { vk::IndexType::UINT32 } else { vk::IndexType::UINT16 };
        let draw = DrawCall::Indirect { indirect: metal2vulkan::bind::IndirectRef::new(0, offset), indexed: Some((it, metal2vulkan::bind::IndexBufferRef::new(0, i.length), index_offset)) };
        emit_draw(e, draw, Some((i, index_offset, wide, 0)), Some((a, offset)), primitive as u32, (0, 0, 0, 0))?;
        Ok(true)
    })
}

/// A pass is written at the end of the encoder, when it is known which targets its programs write. A target that no program wrote and whose store is "don't care" is not bound: no memory, no bandwidth (doc section 3.3). The draws stream runs as IB1s of the submission, between the pass's begin and end.
#[unsafe(no_mangle)]
pub extern "C" fn nmb_encoder_end(e: *mut NmbEncoder) -> bool {
    guard(false, || {
        let enc = unsafe { Box::from_raw(e) };
        let mut enc = enc;
        let cb = unsafe { enc.cb.as_mut() }.ok_or("the command buffer")?;
        cb.open = false;
        if enc.kind == 2 || enc.kind == 1 {
            let draws = std::mem::replace(&mut enc.draws, Box::new(unsafe { std::mem::zeroed() }));
            unsafe {
                let mut d = draws;
                nw_cs_end_ib(&mut *d);
                let cs: *mut NwCs = &mut *cb.cs;
                // IB1s of the submission, not calls: a compute program's state is an IB2, and an a6xx has no third level
                nw_cs_append_ibs(cs, &*d);
                nmn_cmd_barrier(cs);
                cb.held_streams.push(d);
            }
            return Ok(true);
        }
        if let Some(pass) = enc.pass.take() {
            let mut p: NmnPass = unsafe { std::mem::zeroed() };
            p.width = pass.w;
            p.height = pass.h;
            p.samples = pass.samples;
            p.color_count = pass.colors.len() as u32;
            for (i, c) in pass.colors.iter().enumerate() {
                let Some((t, level, layer, load, store, clear)) = c else { continue };
                let written = enc.attachment_written & (1 << i) != 0;
                let keep = *load == 1 || *store != 0;
                if t.memoryless && !written {
                    continue;
                }
                if !written && !keep {
                    continue;
                }
                p.colors[i] = NmnColorTarget { image: t.image as *const NmnImage, pipe_format: t.pipe_format, level: *level as u32, layer: *layer as u32, clear: *load == 2, clear_value: *clear };
                if t.must_name() || t.backing.is_some() {
                    cb.names.push(t.bo() as usize);
                }
                cb.held_textures.push(t.clone());
            }
            if let Some((d, level, layer)) = &pass.depth {
                p.depth = d.image as *const NmnImage;
                p.depth_level = *level;
                p.depth_layer = *layer;
                p.clear_depth = pass.depth_load == 2;
                p.clear_z = pass.clear_z;
                if d.must_name() {
                    cb.names.push(d.bo() as usize);
                }
                cb.held_textures.push(d.clone());
            }
            if let Some((x, level, layer)) = &pass.stencil {
                p.stencil = x.image as *const NmnImage;
                p.stencil_level = *level;
                p.stencil_layer = *layer;
                p.clear_stencil = pass.stencil_load == 2;
                p.clear_s = pass.clear_s;
                if x.must_name() {
                    cb.names.push(x.bo() as usize);
                }
                cb.held_textures.push(x.clone());
            }
            let cs: *mut NwCs = &mut *cb.cs;
            unsafe {
                nmn_cmd_pass_begin(cs, enc.gpu.gpu, &p);
                nw_cs_end_ib(&mut *enc.draws);
                // IB1s of the submission, not calls: a draw calls its program's state as an IB2, and an a6xx has no third level
                nw_cs_append_ibs(cs, &*enc.draws);
                nmn_cmd_pass_end(cs, &p);
            }
        }
        // the stream of draws lives until the fence, with the command buffer
        let draws = std::mem::replace(&mut enc.draws, Box::new(unsafe { std::mem::zeroed() }));
        cb.held_streams.push(draws);
        Ok(true)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn nmb_encoder_discard(e: *mut NmbEncoder) {
    if !e.is_null() {
        let enc = unsafe { Box::from_raw(e) };
        if let Some(cb) = unsafe { enc.cb.as_mut() } {
            cb.open = false;
        }
    }
}
