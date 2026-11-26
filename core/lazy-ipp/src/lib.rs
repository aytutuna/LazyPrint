//! IPP for Lazy Print: the message codec and the requests a printer is sent.
//! Required Notice: Copyright (c) 2026 Alazy Inc. (https://alazy.app)

pub mod codec;
pub mod requests;
pub mod status;

pub use codec::{Attribute, BadMessage, Group, Message, Operation, Value, Version, tag};
