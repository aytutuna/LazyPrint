#![no_main]

use lazy_ipp::txt::TxtRecord;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let text = String::from_utf8_lossy(data);
    let attributes: Vec<&str> = text.lines().collect();
    let _ = TxtRecord::parse(&attributes);
});
