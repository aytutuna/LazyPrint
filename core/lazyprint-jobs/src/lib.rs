// Required Notice: Copyright (c) 2026 Alazy Inc. (https://alazy.app)

//! From settings to sheets to a job: the printable area on a printer's paper, the layout the settings ask for and the
//! passes a printer without two-sided printing needs.

mod document;
mod job;
mod ticket;

pub use document::*;
pub use job::*;
pub use ticket::*;
