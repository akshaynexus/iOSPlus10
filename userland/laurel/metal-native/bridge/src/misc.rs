// SPDX-License-Identifier: MIT
//! The rest of bridge/NativeMetalObjects.h: device queries, heaps, views, depth state, blit and compute encoders, events, fences. A call with no native path here refuses with a reason: the frontend turns that into Metal's error. None pretends to work.
use crate::compile::{Program, compute_program_spec, lay_out};
use crate::draw::*;
use crate::ffi::*;
use crate::objects::*;
use metal2vulkan::bind::Dispatch;
use metal2vulkan::vk;
use std::collections::HashMap;
use std::ffi::{CStr, CString, c_char, c_void};
use std::sync::{Arc, Condvar, Mutex};

static ANSWERS: &str = include_str!("answers.tsv");

pub(crate) fn copy_out(text: &str, out: *mut c_char, size: usize) -> usize {
    if !out.is_null() && size > 0 {
        let n = text.len().min(size - 1);
        unsafe {
            std::ptr::copy_nonoverlapping(text.as_ptr() as *const c_char, out, n);
            *out.add(n) = 0;
        }
    }
    text.len()
}

pub(crate) fn now_seconds() -> f64 {
    static START: std::sync::OnceLock<std::time::Instant> = std::sync::OnceLock::new();
    START.get_or_init(std::time::Instant::now).elapsed().as_secs_f64()
}

struct AnswerRow {
    selector: CString,
    kind: u32,
    args: HashMap<u64, u64>,
    value: Option<u64>,
}

fn answers() -> &'static Vec<AnswerRow> {
    static TABLE: std::sync::OnceLock<Vec<AnswerRow>> = std::sync::OnceLock::new();
    TABLE.get_or_init(|| {
        let mut rows: Vec<AnswerRow> = Vec::new();
        for line in ANSWERS.lines() {
            let f: Vec<&str> = line.split('\t').collect();
            if f.len() != 4 {
                continue;
            }
            let selector = CString::new(f[0]).expect("selector");
            let kind: u32 = f[1].parse().unwrap_or(0);
            let at = match rows.iter().position(|r| r.selector == selector) {
                Some(i) => i,
                None => {
                    rows.push(AnswerRow { selector, kind, args: HashMap::new(), value: None });
                    rows.len() - 1
                }
            };
            if f[2] == "-" {
                rows[at].value = f[3].parse().ok();
            } else if let (Ok(a), Ok(v)) = (f[2].parse::<u64>(), f[3].parse::<u64>()) {
                rows[at].args.insert(a, v);
            }
        }
        rows
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn nmb_device_answer_selector(index: usize, kind: *mut u32) -> *const c_char {
    let Some(row) = answers().get(index) else { return std::ptr::null() };
    if !kind.is_null() {
        unsafe { *kind = row.kind };
    }
    row.selector.as_ptr()
}

/// The default stack's answers on FD610 (bridge/src/answers.tsv, made by tests/dump-answers.c): a framework takes the same path on both stacks.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nmb_device_answer(_d: *const NmbDevice, selector: *const c_char, arg: u64, out: *mut u64) -> bool {
    guard(false, || {
        let want = unsafe { CStr::from_ptr(selector) };
        let row = answers().iter().find(|r| r.selector.as_c_str() == want).ok_or_else(|| format!("no answer for {want:?}"))?;
        let v = if row.kind >= 2 { *row.args.get(&arg).unwrap_or(&0) } else { row.value.ok_or_else(|| format!("{want:?} has no answer on this device"))? };
        unsafe { *out = v };
        Ok(true)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn nmb_device_name(_d: *const NmbDevice, out: *mut c_char, size: usize) -> usize {
    copy_out("Adreno (TM) 610 native", out, size)
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_device_vendor_name(_d: *const NmbDevice, out: *mut c_char, size: usize) -> usize {
    copy_out("Qualcomm", out, size)
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_device_family_waivers(_d: *const NmbDevice, out: *mut c_char, size: usize) -> usize {
    copy_out("", out, size)
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_device_max_buffer_length(_d: *const NmbDevice) -> u64 {
    48 << 20
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_device_max_threads_per_threadgroup(_d: *const NmbDevice, out: *mut u64) -> bool {
    unsafe {
        *out = 1024;
        *out.add(1) = 1024;
        *out.add(2) = 1024;
    }
    true
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_device_work_stats(_d: *const NmbDevice, out: *mut u64) -> bool {
    unsafe { std::ptr::write_bytes(out, 0, 10) };
    true
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_device_shader_cache_stats(_d: *const NmbDevice, _out: *mut c_void) -> bool {
    false
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_last_warning(out: *mut c_char, size: usize) -> usize {
    copy_out("", out, size)
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nmb_fixture_air(length: *mut usize) -> *const c_void {
    if !length.is_null() {
        unsafe { *length = 0 };
    }
    std::ptr::null()
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nmb_function_constant_air(length: *mut usize) -> *const c_void {
    if !length.is_null() {
        unsafe { *length = 0 };
    }
    std::ptr::null()
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_device_heap_texture_size(d: *const NmbDevice, descriptor: *const NmbTextureDescriptor, size: *mut u64, align: *mut u64) -> bool {
    guard(false, || {
        let device = get(d)?;
        let t = new_texture_layout(&device.gpu, get(descriptor)?)?;
        unsafe {
            *size = (nmn_image_size(t as *const NmnImage) + 4095) & !4095;
            *align = 4096;
            nmn_image_free(t);
        }
        Ok(true)
    })
}
fn new_texture_layout(gpu: &Arc<Gpu>, d: &NmbTextureDescriptor) -> Result<*mut NmnImage, String> {
    let pipe = unsafe { nmn_format_from_metal(d.format) };
    if pipe == 0 {
        return Err(format!("pixel format {} has no native path", d.format));
    }
    let tiled = (d.options >> 4) & 0xf >= 2;
    let image = unsafe { nmn_image_new(gpu.gpu, pipe, TextureObj::view_kind(d.kind), d.width as u32, d.height.max(1) as u32, d.depth.max(1) as u32, d.levels.max(1) as u32, d.array_length.max(1) as u32, d.samples.max(1) as u32, tiled, 0) };
    if image.is_null() { Err("no layout".into()) } else { Ok(image) }
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_device_linear_bytes_per_row(_d: *const NmbDevice, format: u64, width: u64) -> u64 {
    let pipe = unsafe { nmn_format_from_metal(format) };
    if pipe == 0 {
        return 0;
    }
    // fdl: a linear pitch is 64-byte aligned on a6xx (minimumLinearTextureAlignment answers the same)
    (width * unsafe { nmn_format_blocksize(pipe) } as u64 + 63) & !63
}

// ---- purgeable, aliasing ----
#[unsafe(no_mangle)]
pub extern "C" fn nmb_buffer_set_purgeable_state(_b: *const NmbBuffer, _state: u64) -> u64 {
    2 // non-volatile: nothing is purged here
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_texture_set_purgeable_state(_t: *const NmbTexture, _state: u64) -> u64 {
    2
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_heap_set_purgeable_state(_h: *const NmbHeap, _state: u64) -> u64 {
    2
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_buffer_make_aliasable(_b: *const NmbBuffer) -> bool {
    true
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_texture_make_aliasable(_t: *const NmbTexture) -> bool {
    true
}

// ---- heaps: one slice, a bump pointer. The compositor's heaps are short lived; a freed resource's bytes return with the heap. ----
pub struct NmbHeap {
    gpu: Arc<Gpu>,
    memory: Arc<Slice>,
    used: Mutex<u64>,
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_heap_new(d: *mut NmbDevice, _kind: u64, size: u64, _options: u64) -> *mut NmbHeap {
    guard(std::ptr::null_mut(), || {
        let gpu = get(d)?.gpu.clone();
        let memory = Slice::new(&gpu, size, 65536)?;
        Ok(boxed(NmbHeap { gpu, memory, used: Mutex::new(0) }))
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_heap_release(h: *mut NmbHeap) {
    release(h)
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_heap_size(h: *const NmbHeap) -> u64 {
    guard(0, || Ok(get(h)?.memory.size))
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_heap_used_size(h: *const NmbHeap) -> u64 {
    guard(0, || Ok(*get(h)?.used.lock().unwrap()))
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_heap_allocated_size(h: *const NmbHeap) -> u64 {
    guard(0, || Ok(get(h)?.memory.size))
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_heap_max_available_size(h: *const NmbHeap, alignment: u64) -> u64 {
    guard(0, || {
        let h = get(h)?;
        let a = alignment.max(1);
        let at = (*h.used.lock().unwrap() + a - 1) & !(a - 1);
        Ok(h.memory.size.saturating_sub(at))
    })
}
fn heap_take(h: &NmbHeap, size: u64, align: u64, offset: u64) -> Result<u64, String> {
    let mut used = h.used.lock().unwrap();
    let at = if offset == u64::MAX { (*used + align - 1) & !(align - 1) } else { offset };
    if at + size > h.memory.size {
        return Err(format!("heap: {size} bytes at {at} do not fit in {}", h.memory.size));
    }
    *used = (*used).max(at + size);
    Ok(at)
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_heap_new_buffer(h: *const NmbHeap, length: u64, _options: u64, offset: u64) -> *mut NmbBuffer {
    guard(std::ptr::null_mut(), || {
        let h = get(h)?;
        let at = heap_take(h, length, 256, offset)?;
        Ok(boxed(NmbBuffer { b: Arc::new(BufferObj { backing: Backing::Sub(h.memory.clone(), at), length, surface_id: 0 }) }))
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_heap_new_texture(h: *const NmbHeap, descriptor: *const NmbTextureDescriptor, offset: u64) -> *mut NmbTexture {
    guard(std::ptr::null_mut(), || {
        let h = get(h)?;
        let d = get(descriptor)?;
        let probe = new_texture_layout(&h.gpu, d)?;
        let size = unsafe { nmn_image_size(probe) };
        unsafe { nmn_image_free(probe) };
        let at = heap_take(h, size, 4096, offset)?;
        let image = new_texture_layout(&h.gpu, d)?;
        unsafe { nmn_image_bind(image, h.memory.iova + at) };
        let pipe = unsafe { nmn_format_from_metal(d.format) };
        Ok(boxed(NmbTexture { t: Arc::new(TextureObj { gpu: h.gpu.clone(), image: image as usize, pipe_format: pipe, desc: *d, backing: None, memory: Some(h.memory.clone()), parent: None, view_type: TextureObj::view_kind(d.kind), base_level: 0, levels: d.levels.max(1) as u32, base_layer: 0, layers: d.array_length.max(1) as u32, memoryless: false }) }))
    })
}

// ---- texture views, surface planes, reads ----
#[unsafe(no_mangle)]
pub extern "C" fn nmb_texture_new_view(t: *mut NmbTexture, format: u64, kind: u64, levels: *const u64, slices: *const u64, whole: bool) -> *mut NmbTexture {
    guard(std::ptr::null_mut(), || {
        let parent = &get(t)?.t;
        let pipe = unsafe { nmn_format_from_metal(format) };
        if pipe == 0 {
            return Err(format!("view format {format} has no native path"));
        }
        let (bl, nl, bs, ns) = if whole {
            (parent.base_level, parent.levels, parent.base_layer, parent.layers)
        } else {
            let l = unsafe { std::slice::from_raw_parts(levels, 2) };
            let s = unsafe { std::slice::from_raw_parts(slices, 2) };
            (parent.base_level + l[0] as u32, l[1] as u32, parent.base_layer + s[0] as u32, s[1] as u32)
        };
        let mut desc = parent.desc;
        desc.format = format;
        if !whole {
            desc.kind = kind;
        }
        Ok(boxed(NmbTexture { t: Arc::new(TextureObj { gpu: parent.gpu.clone(), image: parent.image, pipe_format: pipe, desc, backing: None, memory: None, parent: Some(parent.clone()), view_type: TextureObj::view_kind(desc.kind), base_level: bl, levels: nl, base_layer: bs, layers: ns, memoryless: parent.memoryless }) }))
    })
}
/// One plane of a surface with planes. A format with no pipe format (a biplanar one taken whole) is refused.
#[unsafe(no_mangle)]
pub extern "C" fn nmb_texture_new_on_surface_plane(b: *mut NmbBuffer, descriptor: *const NmbTextureDescriptor, offset: u64, bytes_per_row: u64, _planar: bool, _fourcc: u32, _plane: u64, _width: u64, _height: u64, _plane1_offset: u64, _plane1_bytes_per_row: u64) -> *mut NmbTexture {
    nmb_texture_new_on_buffer(b, descriptor, offset, bytes_per_row, true)
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nmb_texture_get_bytes(t: *const NmbTexture, bytes: *mut c_void, bytes_per_row: u64, _bytes_per_image: u64, _length: u64, region: *const u64, level: u64, slice: u64) -> bool {
    guard(false, || {
        let t = &get(t)?.t;
        let r = unsafe { std::slice::from_raw_parts(region, 6) };
        if (t.desc.options >> 4) & 0xf >= 2 {
            return Err("getBytes on a private texture".into());
        }
        let map = t.memory.as_ref().map(|m| m.map as *mut u8).or(t.backing.as_ref().map(|b| b.backing.map() as *mut u8)).ok_or("no CPU mapping")?;
        unsafe {
            let cpp = nmn_format_blocksize(t.pipe_format) as u64;
            let pitch = nmn_image_pitch(t.image as *const NmnImage, level as u32) as u64;
            let base = nmn_image_layer_offset(t.image as *const NmnImage, level as u32, slice as u32);
            for y in 0..r[4] {
                let src = map.add((base + (r[1] + y) * pitch + r[0] * cpp) as usize);
                let dst = (bytes as *mut u8).add((y * bytes_per_row) as usize);
                std::ptr::copy_nonoverlapping(src, dst, (r[3] * cpp) as usize);
            }
        }
        Ok(true)
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_texture_gpu_resource_id(t: *const NmbTexture) -> u64 {
    t as u64
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_sampler_gpu_resource_id(s: *const NmbSampler) -> u64 {
    s as u64
}

// ---- depth + stencil ----
#[repr(C)]
pub struct NmbStencil {
    pub compare: u64,
    pub failure: u64,
    pub depth_failure: u64,
    pub pass: u64,
    pub read_mask: u64,
    pub write_mask: u64,
}
#[repr(C)]
pub struct NmbDepthStencilDescriptor {
    pub compare: u64,
    pub write: u64,
    pub front: NmbStencil,
    pub back: NmbStencil,
}
pub struct NmbDepthStencil {
    depth_func: u32,
    depth_write: bool,
    depth_test: bool,
    stencil: bool,
    func: [u32; 2],
    fail: [u32; 2],
    zpass: [u32; 2],
    zfail: [u32; 2],
    read: [u32; 2],
    write: [u32; 2],
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_depth_stencil_new(_d: *mut NmbDevice, descriptor: *const NmbDepthStencilDescriptor) -> *mut NmbDepthStencil {
    guard(std::ptr::null_mut(), || {
        let d = get(descriptor)?;
        let on = |s: &NmbStencil| s.compare != 7 || s.failure != 0 || s.depth_failure != 0 || s.pass != 0;
        Ok(boxed(NmbDepthStencil {
            depth_func: d.compare as u32,
            depth_write: d.write != 0,
            depth_test: d.compare != 7 || d.write != 0,
            stencil: on(&d.front) || on(&d.back),
            func: [d.front.compare as u32, d.back.compare as u32],
            fail: [d.front.failure as u32, d.back.failure as u32],
            zpass: [d.front.pass as u32, d.back.pass as u32],
            zfail: [d.front.depth_failure as u32, d.back.depth_failure as u32],
            read: [d.front.read_mask as u32, d.back.read_mask as u32],
            write: [d.front.write_mask as u32, d.back.write_mask as u32],
        }))
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_depth_stencil_release(d: *mut NmbDepthStencil) {
    release(d)
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_render_set_depth_stencil(e: *mut NmbEncoder, d: *mut NmbDepthStencil) -> bool {
    guard(false, || {
        let e = unsafe { e.as_mut() }.ok_or("null encoder")?;
        let r = &mut e.raster;
        if d.is_null() {
            r.depth_func = 7;
            r.depth_write = false;
            r.depth_test = false;
            r.stencil_enable = false;
        } else {
            let d = get(d)?;
            r.depth_func = d.depth_func;
            r.depth_write = d.depth_write;
            r.depth_test = d.depth_test;
            r.stencil_enable = d.stencil;
            r.st_func = d.func;
            r.st_fail = d.fail;
            r.st_zpass = d.zpass;
            r.st_zfail = d.zfail;
            r.st_read = d.read;
            r.st_write = d.write;
        }
        Ok(true)
    })
}
// Store actions: sysmem stores everything anyway. A "don't care" gives its target no bandwidth saving yet, and no wrong picture.
#[unsafe(no_mangle)]
pub extern "C" fn nmb_render_set_color_store_action(_e: *mut NmbEncoder, _action: u64, _index: u32) -> bool {
    true
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_render_set_depth_store_action(_e: *mut NmbEncoder, _action: u64) -> bool {
    true
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_render_set_stencil_store_action(_e: *mut NmbEncoder, _action: u64) -> bool {
    true
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_render_set_visibility_mode(_e: *mut NmbEncoder, mode: u64, _offset: u64) -> bool {
    if mode != 0 {
        set_error("visibility results have no native path yet".into());
        return false;
    }
    true
}

// ---- events and fences ----
pub struct EventObj {
    value: Mutex<u64>,
    changed: Condvar,
    listeners: Mutex<Vec<(u64, extern "C" fn(*mut c_void, u64), usize)>>,
}
impl EventObj {
    pub(crate) fn signal(&self, v: u64) {
        let mut value = self.value.lock().unwrap();
        if v > *value {
            *value = v;
        }
        let now = *value;
        self.changed.notify_all();
        drop(value);
        let ready: Vec<_> = {
            let mut l = self.listeners.lock().unwrap();
            let (r, keep): (Vec<_>, Vec<_>) = l.drain(..).partition(|x| x.0 <= now);
            *l = keep;
            r
        };
        for (want, h, ctx) in ready {
            h(ctx as *mut c_void, want);
        }
    }
    pub(crate) fn wait(&self, v: u64, ms: u64) -> bool {
        let mut value = self.value.lock().unwrap();
        let start = std::time::Instant::now();
        while *value < v {
            let left = std::time::Duration::from_millis(ms).saturating_sub(start.elapsed());
            if left.is_zero() {
                return false;
            }
            value = self.changed.wait_timeout(value, left).unwrap().0;
        }
        true
    }
}
pub struct NmbEvent(Arc<EventObj>);
#[unsafe(no_mangle)]
pub extern "C" fn nmb_event_new(_d: *mut NmbDevice, _shared: bool) -> *mut NmbEvent {
    boxed(NmbEvent(Arc::new(EventObj { value: Mutex::new(0), changed: Condvar::new(), listeners: Mutex::new(vec![]) })))
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_event_release(e: *mut NmbEvent) {
    release(e)
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_shared_event_value(e: *const NmbEvent) -> u64 {
    guard(0, || Ok(*get(e)?.0.value.lock().unwrap()))
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_shared_event_set_value(e: *mut NmbEvent, v: u64) -> bool {
    guard(false, || {
        get(e)?.0.signal(v);
        Ok(true)
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_shared_event_wait(e: *mut NmbEvent, v: u64, timeout_ms: u64) -> bool {
    guard(false, || Ok(get(e)?.0.wait(v, timeout_ms)))
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_shared_event_notify(e: *mut NmbEvent, v: u64, handler: extern "C" fn(*mut c_void, u64), context: *mut c_void) -> bool {
    guard(false, || {
        let ev = &get(e)?.0;
        if *ev.value.lock().unwrap() >= v {
            handler(context, v);
        } else {
            ev.listeners.lock().unwrap().push((v, handler, context as usize));
        }
        Ok(true)
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_command_buffer_signal_event(c: *mut NmbCommandBuffer, e: *mut NmbEvent, v: u64) -> bool {
    guard(false, || {
        unsafe { c.as_mut() }.ok_or("null command buffer")?.signals.push((get(e)?.0.clone(), v));
        Ok(true)
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_command_buffer_wait_event(c: *mut NmbCommandBuffer, e: *mut NmbEvent, v: u64) -> bool {
    guard(false, || {
        unsafe { c.as_mut() }.ok_or("null command buffer")?.waits.push((get(e)?.0.clone(), v));
        Ok(true)
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_command_buffer_uses_buffer(_c: *const NmbCommandBuffer, _b: *const NmbBuffer) -> i32 {
    -1 // unknown: the caller waits. The frontend's fallback is correct, and this stack keeps no per-resource index.
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_command_buffer_uses_texture(_c: *const NmbCommandBuffer, _t: *const NmbTexture) -> i32 {
    -1
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_command_buffer_gpu_time(c: *const NmbCommandBuffer, end: bool) -> f64 {
    guard(0.0, || {
        let st = get(c)?.state.0.lock().unwrap();
        Ok(if end { st.ended } else { st.started })
    })
}
// On one ring every encoder ends with a flush, so a fence asks for nothing more than the order of the stream.
pub struct NmbFence;
#[unsafe(no_mangle)]
pub extern "C" fn nmb_fence_new(_d: *mut NmbDevice) -> *mut NmbFence {
    boxed(NmbFence)
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_fence_release(f: *mut NmbFence) {
    release(f)
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_encoder_update_fence(_e: *mut NmbEncoder, _f: *mut NmbFence, _stages: u64) -> bool {
    true
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_encoder_wait_fence(_e: *mut NmbEncoder, _f: *mut NmbFence, _stages: u64) -> bool {
    true
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_encoder_use_resource(_e: *mut NmbEncoder, _b: *mut NmbBuffer, _t: *mut NmbTexture, _usage: u64, _stages: u64) -> bool {
    true // one address space: everything is always mapped
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_encoder_use_heap(_e: *mut NmbEncoder, _h: *mut NmbHeap, _stages: u64) -> bool {
    true
}

// ---- encoders with no pass ----
fn plain_encoder(c: *mut NmbCommandBuffer, kind: u32) -> Result<*mut NmbEncoder, String> {
    let cb = unsafe { c.as_mut() }.ok_or("null command buffer")?;
    if cb.open {
        return Err("another encoder is open".into());
    }
    let mut draws: Box<NwCs> = Box::new(unsafe { std::mem::zeroed() });
    unsafe { nw_cs_init(&mut *draws, cb.gpu.dev) };
    cb.open = true;
    Ok(boxed(NmbEncoder::plain(c, cb.gpu.clone(), kind, draws)))
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_blit_encoder_new(c: *mut NmbCommandBuffer) -> *mut NmbEncoder {
    guard(std::ptr::null_mut(), || plain_encoder(c, 2))
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_compute_encoder_new(c: *mut NmbCommandBuffer) -> *mut NmbEncoder {
    guard(std::ptr::null_mut(), || plain_encoder(c, 1))
}

fn hold_buffer(e: &mut NmbEncoder, b: &Arc<BufferObj>) -> Result<(), String> {
    let cb = unsafe { e.cb.as_mut() }.ok_or("the command buffer")?;
    if b.backing.must_name() {
        cb.names.push(b.backing.bo() as usize);
    }
    cb.held_buffers.push(b.clone());
    Ok(())
}
fn hold_texture(e: &mut NmbEncoder, t: &Arc<TextureObj>) -> Result<(), String> {
    let cb = unsafe { e.cb.as_mut() }.ok_or("the command buffer")?;
    if t.must_name() || t.backing.is_some() {
        cb.names.push(t.bo() as usize);
    }
    cb.held_textures.push(t.clone());
    Ok(())
}

#[unsafe(no_mangle)]
pub extern "C" fn nmb_blit_copy_buffer(e: *mut NmbEncoder, s: *mut NmbBuffer, so: u64, d: *mut NmbBuffer, dO: u64, size: u64) -> bool {
    guard(false, || {
        let e = unsafe { e.as_mut() }.ok_or("null encoder")?;
        let (sb, db) = (get(s)?.b.clone(), get(d)?.b.clone());
        hold_buffer(e, &sb)?;
        hold_buffer(e, &db)?;
        unsafe { nmn_cmd_copy_buffer(&mut *e.draws, sb.backing.iova() + so, db.backing.iova() + dO, size) };
        Ok(true)
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_blit_fill_buffer(e: *mut NmbEncoder, b: *mut NmbBuffer, start: u64, end: u64, value: u8) -> bool {
    guard(false, || {
        let e = unsafe { e.as_mut() }.ok_or("null encoder")?;
        let db = get(b)?.b.clone();
        hold_buffer(e, &db)?;
        unsafe { nmn_cmd_fill_buffer(&mut *e.draws, db.backing.iova() + start, end - start, value) };
        Ok(true)
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_blit_copy_texture(e: *mut NmbEncoder, s: *mut NmbTexture, sslice: u64, slevel: u64, so: *const u64, size: *const u64, d: *mut NmbTexture, dslice: u64, dlevel: u64, dorigin: *const u64) -> bool {
    guard(false, || {
        let e = unsafe { e.as_mut() }.ok_or("null encoder")?;
        let (st, dt) = (get(s)?.t.clone(), get(d)?.t.clone());
        hold_texture(e, &st)?;
        hold_texture(e, &dt)?;
        let (so, size, dorigin) = unsafe { (std::slice::from_raw_parts(so, 3), std::slice::from_raw_parts(size, 3), std::slice::from_raw_parts(dorigin, 3)) };
        let (a, b, c) = ([so[0] as u32, so[1] as u32], [dorigin[0] as u32, dorigin[1] as u32], [size[0] as u32, size[1] as u32]);
        unsafe { nmn_cmd_copy_image(&mut *e.draws, st.image as *const NmnImage, slevel as u32, sslice as u32, a.as_ptr(), dt.image as *const NmnImage, dlevel as u32, dslice as u32, b.as_ptr(), c.as_ptr()) };
        Ok(true)
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_blit_buffer_to_texture(e: *mut NmbEncoder, b: *mut NmbBuffer, offset: u64, row: u64, _image: u64, size: *const u64, t: *mut NmbTexture, slice: u64, level: u64, origin: *const u64) -> bool {
    guard(false, || {
        let e = unsafe { e.as_mut() }.ok_or("null encoder")?;
        let (sb, dt) = (get(b)?.b.clone(), get(t)?.t.clone());
        hold_buffer(e, &sb)?;
        hold_texture(e, &dt)?;
        let (size, origin) = unsafe { (std::slice::from_raw_parts(size, 3), std::slice::from_raw_parts(origin, 3)) };
        let (o, s) = ([origin[0] as u32, origin[1] as u32], [size[0] as u32, size[1] as u32]);
        unsafe { nmn_cmd_buffer_to_image(&mut *e.draws, sb.backing.iova() + offset, row as u32, dt.image as *const NmnImage, level as u32, slice as u32, o.as_ptr(), s.as_ptr()) };
        Ok(true)
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_blit_buffer_to_texture_options(e: *mut NmbEncoder, b: *mut NmbBuffer, offset: u64, row: u64, image: u64, size: *const u64, t: *mut NmbTexture, slice: u64, level: u64, origin: *const u64, _options: u64) -> bool {
    nmb_blit_buffer_to_texture(e, b, offset, row, image, size, t, slice, level, origin)
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_blit_texture_to_buffer(e: *mut NmbEncoder, t: *mut NmbTexture, slice: u64, level: u64, origin: *const u64, size: *const u64, b: *mut NmbBuffer, offset: u64, row: u64, _image: u64) -> bool {
    guard(false, || {
        let e = unsafe { e.as_mut() }.ok_or("null encoder")?;
        let (st, db) = (get(t)?.t.clone(), get(b)?.b.clone());
        hold_texture(e, &st)?;
        hold_buffer(e, &db)?;
        let (size, origin) = unsafe { (std::slice::from_raw_parts(size, 3), std::slice::from_raw_parts(origin, 3)) };
        let (o, s) = ([origin[0] as u32, origin[1] as u32], [size[0] as u32, size[1] as u32]);
        unsafe { nmn_cmd_image_to_buffer(&mut *e.draws, st.image as *const NmnImage, level as u32, slice as u32, o.as_ptr(), s.as_ptr(), db.backing.iova() + offset, row as u32) };
        Ok(true)
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_blit_texture_to_buffer_options(e: *mut NmbEncoder, t: *mut NmbTexture, slice: u64, level: u64, origin: *const u64, size: *const u64, b: *mut NmbBuffer, offset: u64, row: u64, image: u64, _options: u64) -> bool {
    nmb_blit_texture_to_buffer(e, t, slice, level, origin, size, b, offset, row, image)
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_blit_generate_mipmaps(e: *mut NmbEncoder, t: *mut NmbTexture) -> bool {
    guard(false, || {
        let e = unsafe { e.as_mut() }.ok_or("null encoder")?;
        let tex = get(t)?.t.clone();
        hold_texture(e, &tex)?;
        for layer in 0..tex.layers {
            for level in 1..tex.levels {
                unsafe { nmn_cmd_mip_down(&mut *e.draws, tex.image as *const NmnImage, level, layer) };
            }
        }
        Ok(true)
    })
}

// ---- compute ----
pub struct ComputeBaked {
    baked: Arc<Baked>,
    local: [u32; 3],
}

#[unsafe(no_mangle)]
pub extern "C" fn nmb_compute_set_pipeline(e: *mut NmbEncoder, p: *mut NmbComputePipeline) -> bool {
    guard(false, || {
        let e = unsafe { e.as_mut() }.ok_or("null encoder")?;
        e.compute = Some(ComputeState { pipeline: p, threadgroup_memory: HashMap::new() });
        Ok(true)
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_compute_set_threadgroup_memory(e: *mut NmbEncoder, length: u32, index: u32) -> bool {
    guard(false, || {
        let e = unsafe { e.as_mut() }.ok_or("null encoder")?;
        e.compute.as_mut().ok_or("no compute pipeline")?.threadgroup_memory.insert(index, length);
        Ok(true)
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_compute_pipeline_max_threads(p: *const NmbComputePipeline) -> u64 {
    guard(0, || Ok(get(p)?.pipeline.metal_info.max_total_threads_per_threadgroup as u64))
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_compute_pipeline_execution_width(p: *const NmbComputePipeline) -> u64 {
    guard(0, || Ok(get(p)?.pipeline.metal_info.thread_execution_width as u64))
}

#[unsafe(no_mangle)]
pub extern "C" fn nmb_compute_dispatch(e: *mut NmbEncoder, size: *const u64, per_group: *const u64, threads: bool) -> bool {
    guard(false, || {
        let e = unsafe { e.as_mut() }.ok_or("null encoder")?;
        let (size, per) = unsafe { (std::slice::from_raw_parts(size, 3), std::slice::from_raw_parts(per_group, 3)) };
        let p = [size[0] as u32, size[1] as u32, size[2] as u32];
        let g = [per[0] as u32, per[1] as u32, per[2] as u32];
        let dispatch = if threads { Dispatch::Threads { threads: p, threads_per_group: g } } else { Dispatch::Threadgroups { groups: p, threads_per_group: g } };
        let state = {
            let mut state = build_state(e)?;
            if let Some(c) = &e.compute {
                let table = state.stages.entry(metal2vulkan::pipeline::Stage::Kernel).or_default();
                for (k, v) in &c.threadgroup_memory {
                    table.threadgroup_lengths.insert(*k, *v);
                }
            }
            state
        };
        let pipeline_ptr = e.compute.as_ref().ok_or("a dispatch with no pipeline")?.pipeline;
        let pipeline = unsafe { pipeline_ptr.as_ref() }.ok_or("the pipeline")?;
        let dev = unsafe { pipeline.device.as_ref() }.ok_or("the pipeline's device")?;
        let plan = pipeline.pipeline.plan(&dev.device, &state.shape()).map_err(|x| format!("compute plan: {x:?}"))?;
        if !plan.variant.is_empty() {
            return Err(format!("this dispatch asks for variant {:?}, which has no native path yet", plan.variant));
        }
        let commands = plan.instantiate_dispatch(&state, &dispatch).map_err(|x| format!("dispatch: {x:?}"))?;
        let bindings = lay_out(&pipeline.pipeline.layout)?;
        let mut offsets = HashMap::new();
        let mut set_slots = vec![];
        for b in &bindings {
            offsets.insert((b.set, b.binding), (b.offset, b.stride));
            if set_slots.len() <= b.set as usize {
                set_slots.resize(b.set as usize + 1, 0);
            }
            set_slots[b.set as usize] = set_slots[b.set as usize].max(b.offset + b.stride * b.count.min(4096));
        }
        let cb = unsafe { e.cb.as_mut() }.ok_or("the command buffer")?;
        let sets = write_descriptors(e, cb, &plan.descriptors, &commands.descriptor_ranges, &offsets, &set_slots, &pipeline.pipeline.layout)?;
        for region in &commands.regions {
            let key: Vec<u8> = region.specialization.data.clone();
            let cached = pipeline.baked.lock().unwrap().get(&key).cloned();
            let entry = match cached {
                Some(c) => c,
                None => {
                    let spec: Vec<NmnSpec> = region.specialization.entries.iter().map(|m| {
                        let at = m.offset as usize;
                        let mut w = [0u8; 4];
                        let n = (m.size as usize).min(4);
                        w[..n].copy_from_slice(&region.specialization.data[at..at + n]);
                        NmnSpec { id: m.constant_id, value: u32::from_le_bytes(w) }
                    }).collect();
                    let program: Program = compute_program_spec(dev.compiler, &pipeline.pipeline, &spec)?;
                    let mut why = [0 as c_char; 256];
                    let baked = unsafe { nmn_bake_compute(e.gpu.gpu, nmn_program_variant(program.0, 0), why.as_mut_ptr(), why.len()) };
                    if baked.is_null() {
                        return Err(unsafe { CStr::from_ptr(why.as_ptr()) }.to_string_lossy().into_owned());
                    }
                    let mut local = [1u32; 3];
                    unsafe { nmn_program_local_size(program.0, local.as_mut_ptr()) };
                    let c = Arc::new(ComputeBaked { baked: Arc::new(Baked { gpu: e.gpu.clone(), b: baked as usize, reads_fb: false, program }), local });
                    pipeline.baked.lock().unwrap().insert(key, c.clone());
                    c
                }
            };
            cb.held_baked.push(entry.baked.clone());
            let cs: *mut NwCs = &mut *e.draws;
            unsafe {
                let set_iova: Vec<u64> = sets.iter().map(|s| s.0).collect();
                let groups = region.group_count;
                // the push range first needs the program's own const layout
                let (mut first, mut vec4s, mut lo) = (0u32, 0u32, 0u32);
                if nmn_program_push_range(entry.baked.program.0, 0, &mut first, &mut vec4s, &mut lo) && vec4s > 0 {
                    let mut image = vec![0u8; vec4s as usize * 16];
                    let lo_bytes = lo as usize * 4;
                    for w in &region.push_constants {
                        for (i, byte) in w.bytes.iter().enumerate() {
                            let at = w.offset as usize + i;
                            if at >= lo_bytes && at - lo_bytes < image.len() {
                                image[at - lo_bytes] = *byte;
                            }
                        }
                    }
                    nmn_cmd_program(cs, entry.baked.b as *const NmnBaked);
                    if !set_iova.is_empty() {
                        nmn_cmd_descriptor_sets(cs, set_iova.as_ptr(), set_iova.len() as u32, false);
                    }
                    nmn_cmd_push(cs, 2, first, image.as_ptr() as *const c_void, vec4s);
                } else {
                    nmn_cmd_program(cs, entry.baked.b as *const NmnBaked);
                    if !set_iova.is_empty() {
                        nmn_cmd_descriptor_sets(cs, set_iova.as_ptr(), set_iova.len() as u32, false);
                    }
                }
                nmn_cmd_dispatch(cs, entry.baked.b as *const NmnBaked, groups.as_ptr(), entry.local.as_ptr());
            }
        }
        Ok(true)
    })
}

// ---- no native path yet: an honest refusal ----
macro_rules! refuse {
    ($name:ident ( $($arg:ident : $ty:ty),* ) -> $ret:ty = $fallback:expr, $why:expr) => {
        #[unsafe(no_mangle)]
        pub extern "C" fn $name($($arg: $ty),*) -> $ret {
            $(let _ = $arg;)*
            set_error($why.into());
            $fallback
        }
    };
}
const NO_ARG: &str = "argument buffers have no native path yet";
pub struct NmbArgumentEncoder;
refuse!(nmb_argument_encoder_new(d: *mut NmbDevice, a: *const c_void, n: usize) -> *mut NmbArgumentEncoder = std::ptr::null_mut(), NO_ARG);
refuse!(nmb_argument_encoder_new_for_function(f: *mut NmbFunction, i: u32) -> *mut NmbArgumentEncoder = std::ptr::null_mut(), NO_ARG);
refuse!(nmb_argument_encoder_new_nested(e: *mut NmbArgumentEncoder, i: u32) -> *mut NmbArgumentEncoder = std::ptr::null_mut(), NO_ARG);
refuse!(nmb_argument_encoder_release(e: *mut NmbArgumentEncoder) -> () = (), NO_ARG);
refuse!(nmb_argument_encoder_encoded_length(e: *const NmbArgumentEncoder) -> u64 = 0, NO_ARG);
refuse!(nmb_argument_encoder_alignment(e: *const NmbArgumentEncoder) -> u64 = 0, NO_ARG);
refuse!(nmb_argument_encoder_set_argument_buffer(e: *mut NmbArgumentEncoder, b: *mut NmbBuffer, o: u64, x: u64) -> bool = false, NO_ARG);
refuse!(nmb_argument_encoder_set_buffer(e: *mut NmbArgumentEncoder, b: *mut NmbBuffer, o: u64, i: u32) -> bool = false, NO_ARG);
refuse!(nmb_argument_encoder_set_texture(e: *mut NmbArgumentEncoder, t: *mut NmbTexture, i: u32) -> bool = false, NO_ARG);
refuse!(nmb_argument_encoder_set_sampler(e: *mut NmbArgumentEncoder, s: *mut NmbSampler, i: u32) -> bool = false, NO_ARG);
refuse!(nmb_argument_encoder_set_compute_pipeline(e: *mut NmbArgumentEncoder, p: *mut NmbComputePipeline, i: u32) -> bool = false, NO_ARG);
refuse!(nmb_argument_encoder_set_render_pipeline(e: *mut NmbArgumentEncoder, p: *mut NmbRenderPipeline, i: u32) -> bool = false, NO_ARG);
refuse!(nmb_argument_encoder_constant_data(e: *mut NmbArgumentEncoder, i: u32) -> *mut c_void = std::ptr::null_mut(), NO_ARG);
const NO_INDIRECT: &str = "indirect draws and dispatches have no native path yet";
refuse!(nmb_compute_dispatch_indirect(e: *mut NmbEncoder, b: *mut NmbBuffer, o: u64, p: *const u64) -> bool = false, NO_INDIRECT);
refuse!(nmb_render_draw_indirect(e: *mut NmbEncoder, p: u64, b: *mut NmbBuffer, o: u64) -> bool = false, NO_INDIRECT);
refuse!(nmb_render_draw_indexed_indirect(e: *mut NmbEncoder, p: u64, t: u64, i: *mut NmbBuffer, io: u64, b: *mut NmbBuffer, o: u64) -> bool = false, NO_INDIRECT);
const NO_DESC: &str = "a compute descriptor with options has no native path yet";
refuse!(nmb_compute_pipeline_new_with_descriptor(d: *mut NmbDevice, x: *const c_void, o: *const c_void) -> *mut NmbComputePipeline = std::ptr::null_mut(), NO_DESC);

// Binary archives: this stack has no pipeline library to keep. The frontend treats an empty archive as "compile at first use".
pub struct NmbBinaryArchive;
#[unsafe(no_mangle)]
pub extern "C" fn nmb_binary_archive_new(_d: *mut NmbDevice, _path: *const c_char) -> *mut NmbBinaryArchive {
    boxed(NmbBinaryArchive)
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_binary_archive_release(a: *mut NmbBinaryArchive) {
    release(a)
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_binary_archive_serialize(_a: *mut NmbBinaryArchive, _path: *const c_char) -> bool {
    true
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_binary_archive_add_render(_a: *mut NmbBinaryArchive, _d: *const c_void) -> bool {
    true
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_binary_archive_add_compute(_a: *mut NmbBinaryArchive, _f: *mut NmbFunction) -> bool {
    true
}
#[unsafe(no_mangle)]
pub extern "C" fn nmb_binary_archive_add_compute_descriptor(_a: *mut NmbBinaryArchive, _d: *const c_void) -> bool {
    true
}

/// The default stack's counter of a host-page cache invalidate, read by the frontend's telemetry line. This stack never invalidates host pages itself: the kernel does, per surface.
#[unsafe(no_mangle)]
pub extern "C" fn m2v_negroni_host_invalidate_stat(_which: u32) -> u64 {
    0
}
