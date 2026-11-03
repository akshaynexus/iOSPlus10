// SPDX-License-Identifier: MIT
//! The `native` Metal stack: the C ABI of ios-flame's bridge (bridge/NativeMetalObjects.h), with no Vulkan under it. The frontend does not change.
//! Function and descriptor handling follows NativeMetalObjects.rs (ios-flame, MIT). Compile: the metal2vulkan crate (AIR -> SPIR-V) + shader/nmn_shader.c (SPIR-V -> ir3).
#![allow(clippy::missing_safety_doc)]

mod compile;
mod diskcache;
mod ffi;
mod flight;
mod draw;
mod misc;
mod objects;

pub use draw::*;
pub use misc::*;
pub use objects::*;
