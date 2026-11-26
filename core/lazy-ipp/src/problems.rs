//! printer-state-reasons as problems a user can act on. The words are the same as in the Swift
//! and C# twins.
//! Required Notice: Copyright (c) 2026 Alazy Inc. (https://alazy.app)

/// A problem a printer reports: `title` says what is wrong, `advice` what to do.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Problem {
    pub title: String,
    pub advice: String,
    pub is_error: bool,
}

fn problem(title: &str, advice: &str, is_error: bool) -> Problem {
    Problem {
        title: title.into(),
        advice: advice.into(),
        is_error,
    }
}

/// The state reasons a user can act on, errors first and each kind once. A reason ending
/// "-error" stops jobs, "-warning" and "-report" do not; one without a suffix is an error
/// (RFC 8011 5.4.12) unless it ends in "-low" or "-needed"; "none" is nothing. A printer that does
/// not answer is "Printer offline", which is not an IPP reason. Reasons not known are left out,
/// except an unknown "-error", which becomes "Printer error" with the printer's own `message` as
/// the advice.
pub fn describe(reasons: &[String], message: Option<&str>, reachable: bool) -> Vec<Problem> {
    if !reachable {
        return vec![problem(
            "Printer offline",
            "Check that the printer is on and on the same network.",
            true,
        )];
    }
    let mut problems: Vec<Problem> = vec![];
    for reason in reasons.iter().filter(|r| *r != "none") {
        let (name, is_error) = severity(reason);
        let found = known(name, is_error).or_else(|| {
            reason.ends_with("-error").then(|| {
                let message = message.unwrap_or_default().trim();
                let advice = if message.is_empty() {
                    "Check the printer's display."
                } else {
                    message
                };
                problem("Printer error", advice, true)
            })
        });
        if let Some(found) = found
            && !problems.contains(&found)
        {
            problems.push(found);
        }
    }
    let (errors, others): (Vec<_>, Vec<_>) = problems.into_iter().partition(|p| p.is_error);
    errors.into_iter().chain(others).collect()
}

fn severity(reason: &str) -> (&str, bool) {
    if let Some(name) = reason.strip_suffix("-error") {
        return (name, true);
    }
    if let Some(name) = reason.strip_suffix("-warning") {
        return (name, false);
    }
    if let Some(name) = reason.strip_suffix("-report") {
        return (name, false);
    }
    let warning = reason.ends_with("-low") || reason.ends_with("-needed");
    (reason, !warning)
}

fn known(name: &str, e: bool) -> Option<Problem> {
    Some(match name {
        "media-empty" | "media-needed" => problem(
            "Out of paper",
            "Load paper in the tray, then press Resume.",
            e,
        ),
        "media-jam" => problem("Paper jam", "Clear the jammed paper, then press Resume.", e),
        "cover-open" | "door-open" => problem(
            "Cover open",
            "Close the cover or door, then press Resume.",
            e,
        ),
        "marker-supply-empty" => problem(
            "Ink empty",
            "Replace the empty cartridge, then press Resume.",
            e,
        ),
        "marker-supply-low" => problem("Ink low", "Order a new cartridge soon.", e),
        "toner-empty" => problem(
            "Toner empty",
            "Replace the toner cartridge, then press Resume.",
            e,
        ),
        "toner-low" => problem("Toner low", "Order a new toner cartridge soon.", e),
        "marker-waste-full" => problem(
            "Waste tank full",
            "Have the printer's waste ink pad or tank replaced.",
            e,
        ),
        "paused" => problem("Printer paused", "Press Resume on the printer.", e),
        "output-area-full" => problem("Output tray full", "Empty the output tray.", e),
        "document-format" | "document-unprintable" => problem(
            "Printer can't print this file",
            "Try another printer, or print it from another app.",
            e,
        ),
        "document-access" => problem("Printer couldn't read the file", "Try printing again.", e),
        "job-canceled-at-device" | "job-canceled-by-user" => problem(
            "Canceled at the printer",
            "The job was canceled from the printer's screen. Print again if you still need it.",
            e,
        ),
        "aborted-by-system" => problem(
            "Printer stopped the job",
            "Check the printer's display, then print again.",
            e,
        ),
        "job-completed-with-errors" => problem(
            "Printed with errors",
            "Check the pages that came out.",
            false,
        ),
        _ => return None,
    })
}
