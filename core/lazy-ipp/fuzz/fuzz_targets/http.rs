#![no_main]

use libfuzzer_sys::fuzz_target;
use std::io::Cursor;

fuzz_target!(|data: &[u8]| {
    let _ = lazy_ipp::http::read_response(&mut Cursor::new(data));
});
