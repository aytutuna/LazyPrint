//! How long to keep asking a printer that answers as busy.

use std::time::Duration;

/// The wait starts at `initial_delay`, grows by `multiplier` up to `max_delay`, and retrying stops
/// once another wait would pass `give_up_after` since the first attempt.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetryPolicy {
    pub initial_delay: Duration,
    pub multiplier: f64,
    pub max_delay: Duration,
    pub give_up_after: Duration,
}

impl Default for RetryPolicy {
    fn default() -> Self {
        RetryPolicy {
            initial_delay: Duration::from_millis(500),
            multiplier: 1.5,
            max_delay: Duration::from_secs(5),
            give_up_after: Duration::from_secs(60),
        }
    }
}

impl RetryPolicy {
    /// The wait before retry number `retry` (0-based). A Retry-After the printer sent replaces the
    /// computed wait, kept within `[initial_delay, max_delay]`.
    pub fn delay_before(&self, retry: u32, retry_after: Option<Duration>) -> Duration {
        if let Some(asked) = retry_after {
            return asked.max(self.initial_delay).min(self.max_delay);
        }
        let seconds = self.initial_delay.as_secs_f64() * self.multiplier.powi(retry as i32);
        if seconds >= self.max_delay.as_secs_f64() {
            self.max_delay
        } else {
            Duration::from_secs_f64(seconds)
        }
    }
}

/// The HTTP status that is retried: 503 Service Unavailable.
pub fn is_retryable_http(status: u16) -> bool {
    status == 503
}

/// The IPP status that is retried: server-error-busy (0x0507).
pub fn is_retryable_ipp(status: u16) -> bool {
    status == crate::status::SERVER_ERROR_BUSY
}
