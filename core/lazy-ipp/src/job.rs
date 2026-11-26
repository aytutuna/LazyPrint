//! A job as the printer reports it.

use crate::codec::{Message, Value, tag};

/// The job-state of RFC 8011 5.3.7. A value the printer sends that is not listed reads as `Unknown`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum JobState {
    Unknown = 0,
    Pending = 3,
    PendingHeld = 4,
    Processing = 5,
    ProcessingStopped = 6,
    Canceled = 7,
    Aborted = 8,
    Completed = 9,
}

impl JobState {
    fn from_code(code: i32) -> JobState {
        match code {
            3 => JobState::Pending,
            4 => JobState::PendingHeld,
            5 => JobState::Processing,
            6 => JobState::ProcessingStopped,
            7 => JobState::Canceled,
            8 => JobState::Aborted,
            9 => JobState::Completed,
            _ => JobState::Unknown,
        }
    }
}

/// A job on a printer: `reasons` are its job-state-reasons, `impressions` the sides printed so far.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Job {
    pub id: i32,
    pub state: JobState,
    pub reasons: Vec<String>,
    pub impressions: i32,
}

impl Job {
    /// The printer is done with it, one way or another.
    pub fn is_finished(&self) -> bool {
        matches!(
            self.state,
            JobState::Canceled | JobState::Aborted | JobState::Completed
        )
    }

    /// The job a Print-Job or Get-Job-Attributes response describes; `id` is used when it names none.
    pub fn from_message(message: &Message, id: Option<i32>) -> Option<Job> {
        let job_id = match message.first("job-id") {
            Some(Value::Integer(n)) => Some(*n),
            _ => id,
        }?;
        let state = match message.first("job-state") {
            Some(Value::Enum(code)) => JobState::from_code(*code),
            _ => JobState::Unknown,
        };
        let reasons = message
            .get("job-state-reasons")
            .map(|a| {
                a.values
                    .iter()
                    .filter_map(|v| match v {
                        Value::Keyword(k) => Some(k.clone()),
                        _ => None,
                    })
                    .collect()
            })
            .unwrap_or_default();
        let impressions = match message.first("job-impressions-completed") {
            Some(Value::Integer(n)) => *n,
            _ => 0,
        };
        Some(Job {
            id: job_id,
            state,
            reasons,
            impressions,
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum QueuedJobState {
    Waiting,
    Held,
    Printing,
    Stopped,
}

/// A job in a printer's queue. `pages` is 0 when the queue does not say; `can_cancel` is set when
/// the job is the user's own.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct QueuedJob {
    pub id: i32,
    pub name: String,
    pub owner: String,
    pub state: QueuedJobState,
    pub pages: i32,
    pub can_cancel: bool,
}

/// The jobs of a Get-Jobs response that are still to print, in the printer's order.
pub fn queued_jobs(response: &Message, user_name: &str) -> Vec<QueuedJob> {
    let mut jobs = vec![];
    for group in response
        .groups
        .iter()
        .filter(|g| g.tag == tag::JOB_ATTRIBUTES)
    {
        let value = |name: &str| {
            group
                .attributes
                .iter()
                .find(|a| a.name == name)
                .and_then(|a| a.values.first())
        };
        let text = |name: &str| match value(name) {
            Some(Value::Name(s) | Value::Text(s)) => Some(s.clone()),
            _ => None,
        };
        let number = |name: &str| match value(name) {
            Some(Value::Integer(n) | Value::Enum(n)) => Some(*n),
            _ => None,
        };
        let Some(id) = number("job-id") else { continue };
        let state = match number("job-state") {
            Some(3) => QueuedJobState::Waiting,
            Some(4) => QueuedJobState::Held,
            Some(5) => QueuedJobState::Printing,
            Some(6) => QueuedJobState::Stopped,
            _ => continue,
        };
        let owner = text("job-originating-user-name").unwrap_or_default();
        jobs.push(QueuedJob {
            id,
            name: text("job-name").unwrap_or_default(),
            can_cancel: owner.to_lowercase() == user_name.to_lowercase(),
            owner,
            state,
            pages: number("job-impressions-completed").unwrap_or(0),
        });
    }
    jobs
}
