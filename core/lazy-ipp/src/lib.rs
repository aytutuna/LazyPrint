//! IPP for Lazy Print: the message codec, the requests a printer is sent and what it answers.
//! Required Notice: Copyright (c) 2026 Alazy Inc. (https://alazy.app)

pub mod address;
pub mod capabilities;
pub mod codec;
pub mod formats;
pub mod job;
pub mod requests;
pub mod retry;
pub mod status;
pub mod txt;

pub use codec::{Attribute, BadMessage, Group, Message, Operation, Value, Version, tag};
