// SPDX-License-Identifier: MIT
//! A pipeline of the translator -> a program of nmn_shader.c.
use crate::ffi::*;
use metal2vulkan::pipeline::{ComputePipeline, PipelineLayout, RenderPipeline, StageModule};
use metal2vulkan::vk;
use std::ffi::{CStr, CString, c_char};

/// Slots of 16 dwords, in the order of the translator's layout, as tu_descriptor_set.cc lays a set out: sampler 1, combined 2, the others 1.
pub fn lay_out(layout: &PipelineLayout) -> Result<Vec<NmnBinding>, String> {
    let mut out = Vec::new();
    for set in &layout.sets {
        let mut offset = 0u32;
        for b in &set.bindings {
            let (kind, stride) = match b.ty {
                vk::DescriptorType::SAMPLER => (NMN_DESC_SAMPLER, 1),
                vk::DescriptorType::COMBINED_IMAGE_SAMPLER => (NMN_DESC_COMBINED, 2),
                vk::DescriptorType::SAMPLED_IMAGE
                | vk::DescriptorType::STORAGE_IMAGE
                | vk::DescriptorType::UNIFORM_TEXEL_BUFFER
                | vk::DescriptorType::STORAGE_TEXEL_BUFFER
                | vk::DescriptorType::INPUT_ATTACHMENT => (NMN_DESC_IMAGE, 1),
                vk::DescriptorType::UNIFORM_BUFFER | vk::DescriptorType::UNIFORM_BUFFER_DYNAMIC => (NMN_DESC_UBO, 1),
                vk::DescriptorType::STORAGE_BUFFER | vk::DescriptorType::STORAGE_BUFFER_DYNAMIC => (NMN_DESC_SSBO, 1),
                other => return Err(format!("descriptor type {other:?} has no slot rule")),
            };
            out.push(NmnBinding { set: set.set, binding: b.binding, kind, offset, stride, count: b.count });
            offset = offset.checked_add(stride.checked_mul(b.count).ok_or("descriptor count")?).ok_or("descriptor offset")?;
        }
    }
    Ok(out)
}

pub struct Stage {
    entry: CString,
    spec: Vec<NmnSpec>,
    spirv: std::sync::Arc<[u32]>,
    stage: u32,
}

impl Stage {
    pub fn new(module: &StageModule, stage: u32) -> Result<Stage, String> {
        let spec = module.specialization.constants.iter().map(|c| NmnSpec { id: c.id, value: c.default as u32 }).collect();
        Ok(Stage { entry: CString::new(module.entry_point.as_str()).map_err(|_| "entry name")?, spec, spirv: module.spirv.clone(), stage })
    }

    pub fn with(mut self, over: &[NmnSpec]) -> Stage {
        for o in over {
            if let Some(s) = self.spec.iter_mut().find(|s| s.id == o.id) {
                s.value = o.value;
            }
        }
        self
    }

    pub fn input(&self) -> NmnStageInput {
        NmnStageInput { stage: self.stage, spirv: self.spirv.as_ptr(), words: self.spirv.len(), entry: self.entry.as_ptr(), spec: self.spec.as_ptr(), spec_count: self.spec.len() as u32 }
    }
}

pub struct Program(pub *mut NmnProgram);
// SAFETY: a finished program is read only.
unsafe impl Send for Program {}
unsafe impl Sync for Program {}
impl Drop for Program {
    fn drop(&mut self) {
        unsafe { nmn_program_free(self.0) }
    }
}

impl Program {
    pub fn stage_info(&self, stage: u32) -> Option<NmnStageInfo> {
        let mut info = NmnStageInfo::default();
        unsafe { nmn_program_info(self.0, stage, &mut info) }.then_some(info)
    }
}

fn why_text(why: &[c_char]) -> String {
    unsafe { CStr::from_ptr(why.as_ptr()) }.to_string_lossy().into_owned()
}

pub fn render_program(compiler: *mut NmnCompiler, p: &RenderPipeline) -> Result<Program, String> {
    render_program_spec(compiler, p, &[])
}

/// With the plan's specialization values over each stage's defaults.
pub fn render_program_spec(compiler: *mut NmnCompiler, p: &RenderPipeline, over: &[NmnSpec]) -> Result<Program, String> {
    let bindings = lay_out(&p.layout)?;
    let push = p.layout.push_constants.iter().map(|r| r.offset + r.size).max().unwrap_or(0);
    let layout = NmnLayout { bindings: bindings.as_ptr(), binding_count: bindings.len() as u32, push_bytes: push };
    let mut vertex = None;
    let mut fragment = None;
    for m in &p.stages {
        match m.stage {
            vk::ShaderStage::VERTEX => vertex = Some(Stage::new(m, 0)?.with(over)),
            vk::ShaderStage::FRAGMENT => fragment = Some(Stage::new(m, 1)?.with(over)),
            other => return Err(format!("stage {other:?} has no native path")),
        }
    }
    let vertex = vertex.ok_or("a render pipeline with no vertex stage")?;
    let vi = vertex.input();
    let fi = fragment.as_ref().map(Stage::input);
    let mut why = [0 as c_char; 256];
    let program = unsafe { nmn_program_render(compiler, &layout, &vi, fi.as_ref().map_or(std::ptr::null(), |f| f as *const _), why.as_mut_ptr(), why.len()) };
    if program.is_null() {
        return Err(why_text(&why));
    }
    Ok(Program(program))
}

pub fn compute_program(compiler: *mut NmnCompiler, p: &ComputePipeline) -> Result<Program, String> {
    compute_program_spec(compiler, p, &[])
}

pub fn compute_program_spec(compiler: *mut NmnCompiler, p: &ComputePipeline, over: &[NmnSpec]) -> Result<Program, String> {
    let bindings = lay_out(&p.layout)?;
    let push = p.layout.push_constants.iter().map(|r| r.offset + r.size).max().unwrap_or(0);
    let layout = NmnLayout { bindings: bindings.as_ptr(), binding_count: bindings.len() as u32, push_bytes: push };
    let stage = Stage::new(&p.stage, 2)?.with(over);
    let input = stage.input();
    let mut why = [0 as c_char; 256];
    let program = unsafe { nmn_program_compute(compiler, &layout, &input, 0, 0, 0, why.as_mut_ptr(), why.len()) };
    if program.is_null() {
        return Err(why_text(&why));
    }
    Ok(Program(program))
}

/// The vertex format of the translator's input state -> Mesa's pipe format (pipe_format numbers come from nmn_pm4's Metal table: the translator speaks Vulkan formats).
pub fn vertex_format_pipe(f: vk::Format) -> Option<u32> {
    let metal = match f {
        vk::Format::R32G32B32A32_SFLOAT => 125,
        vk::Format::R16G16B16A16_SFLOAT => 115,
        vk::Format::R32G32_SFLOAT => 105,
        vk::Format::R16G16_SFLOAT => 65,
        vk::Format::R32_SFLOAT => 55,
        vk::Format::R8G8B8A8_UNORM => 70,
        vk::Format::B8G8R8A8_UNORM => 80,
        vk::Format::R32G32B32A32_UINT => 123,
        vk::Format::R32G32B32A32_SINT => 124,
        vk::Format::R16G16B16A16_UINT => 113,
        vk::Format::R32G32_UINT => 103,
        vk::Format::R32_UINT => 53,
        _ => return None,
    };
    Some(unsafe { nmn_format_from_metal(metal) })
}

pub fn vertex_format_is_float(f: vk::Format) -> bool {
    !matches!(f, vk::Format::R32G32B32A32_UINT | vk::Format::R32G32B32A32_SINT | vk::Format::R16G16B16A16_UINT | vk::Format::R32G32_UINT | vk::Format::R32_UINT)
}
