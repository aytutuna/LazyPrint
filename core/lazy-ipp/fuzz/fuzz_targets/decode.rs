#![no_main]

use lazy_ipp::capabilities::Capabilities;
use lazy_ipp::job::{Job, queued_jobs};
use lazy_ipp::Message;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Ok((message, offset)) = Message::decode(data) else {
        return;
    };
    assert!(offset <= data.len());
    // What was read writes back to something that reads as the same message.
    let (again, _) = Message::decode(&message.encode()).expect("an encoded message decodes");
    assert_eq!(again, message);
    // Whatever a printer sent, reading it as capabilities and jobs must not fail.
    let _ = Capabilities::from_message(&message);
    let _ = Job::from_message(&message, None);
    let _ = queued_jobs(&message, "user");
});
