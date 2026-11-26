use crate::Placement;
use serde::{Deserialize, Serialize};

const USAGE: &str = "Type pages like 1-3, 5";

/// The pages typed (0-based, in the order typed, repeats kept), or what is wrong with them in words for the user.
pub type PageRangeResult = Result<Vec<usize>, String>;

/// Parses "1-3, 5, 8-": single pages, ranges, an open range to the last page and a descending range ("5-2" is
/// 5, 4, 3, 2), separated by commas, semicolons or spaces, with a hyphen, en dash or em dash in a range, counted
/// from 1. A page past `page_count` is an error ("Page 9 is past the end (8 pages)").
pub fn parse_page_range(text: &str, page_count: usize) -> PageRangeResult {
    let normal = tighten_dashes(&text.replace(['–', '—'], "-"));
    let page_count = i64::try_from(page_count).unwrap_or(i64::MAX);
    let mut pages = Vec::new();
    for item in normal.split([',', ';']) {
        let item = item.trim();
        let parts: Vec<&str> = if item.is_empty() {
            vec![""]
        } else {
            item.split_whitespace().collect()
        };
        for part in parts {
            let (first, last) = match part.find('-') {
                None => {
                    let n = number(part).ok_or(USAGE)?;
                    (n, n)
                }
                Some(dash) => {
                    let first = number(&part[..dash]).ok_or(USAGE)?;
                    let end = &part[dash + 1..];
                    let last = if end.is_empty() {
                        first.max(page_count)
                    } else {
                        number(end).ok_or(USAGE)?
                    };
                    (first, last)
                }
            };
            let (low, high) = (first.min(last), first.max(last));
            if high > page_count {
                let past = if low > page_count { low } else { high };
                let plural = if page_count == 1 { "" } else { "s" };
                return Err(format!(
                    "Page {past} is past the end ({page_count} page{plural})"
                ));
            }
            if last >= first {
                pages.extend((first..=last).map(|p| (p - 1) as usize));
            } else {
                pages.extend((last..=first).rev().map(|p| (p - 1) as usize));
            }
        }
    }
    Ok(pages)
}

/// Removes the white space around every hyphen.
fn tighten_dashes(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut pending = String::new();
    let mut after_dash = false;
    for c in text.chars() {
        if c.is_whitespace() {
            if !after_dash {
                pending.push(c);
            }
        } else if c == '-' {
            pending.clear();
            out.push('-');
            after_dash = true;
        } else {
            out.push_str(&pending);
            pending.clear();
            out.push(c);
            after_dash = false;
        }
    }
    out.push_str(&pending);
    out
}

fn number(text: &str) -> Option<i64> {
    if text.is_empty() || !text.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    // A number that does not fit an int is not a page either.
    text.parse::<i32>().ok().filter(|&n| n >= 1).map(i64::from)
}

/// The pages placed, numbered over the documents in turn: "Page 3", "Pages 3–4", "Pages 1, 8". `page_counts` is the
/// pages of each document. Nothing placed is "Blank".
pub fn page_label(placements: &[Placement], page_counts: &[usize]) -> String {
    let mut numbers: Vec<usize> = placements
        .iter()
        .map(|p| page_counts.iter().take(p.page.document).sum::<usize>() + p.page.index + 1)
        .collect();
    numbers.sort_unstable();
    numbers.dedup();
    if numbers.is_empty() {
        return "Blank".into();
    }
    let mut runs: Vec<(usize, usize)> = Vec::new();
    for &n in &numbers {
        match runs.last_mut() {
            Some(run) if run.1 + 1 == n => run.1 = n,
            _ => runs.push((n, n)),
        }
    }
    let text: Vec<String> = runs
        .iter()
        .map(|&(from, to)| {
            if from == to {
                from.to_string()
            } else {
                format!("{from}–{to}")
            }
        })
        .collect();
    format!(
        "{}{}",
        if numbers.len() == 1 {
            "Page "
        } else {
            "Pages "
        },
        text.join(", ")
    )
}

/// Every page, or only those whose number is odd or even.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PageSelection {
    #[default]
    All,
    Odd,
    Even,
}

/// `pages` (0-based places in the run of all documents) cut down to the odd or even page numbers (page 1 is odd, so
/// index 0), then turned around when `reverse`. Done before the pages are laid out on sheets.
pub fn pick_pages(pages: &[usize], selection: PageSelection, reverse: bool) -> Vec<usize> {
    let mut kept: Vec<usize> = pages
        .iter()
        .copied()
        .filter(|i| match selection {
            PageSelection::All => true,
            PageSelection::Odd => i % 2 == 0,
            PageSelection::Even => i % 2 == 1,
        })
        .collect();
    if reverse {
        kept.reverse();
    }
    kept
}

/// The most copies asked for at once.
pub const MAX_COPIES: i32 = 99;

/// How a number of copies is asked of a printer.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CopiesPlan {
    /// The copy count the print job asks the printer for.
    pub ticket_copies: i32,
    /// How many times the pages are put in the job, one after the other (collated).
    pub document_repeats: i32,
}

pub fn clamp_copies(count: i32) -> i32 {
    count.clamp(1, MAX_COPIES)
}

/// The printer makes the copies (collated) when it says it can make that many and, for more than one page, that it
/// collates; otherwise, and when it does not say, the pages are put in the job that many times, so the copies come
/// out in order whatever the printer does.
pub fn plan_copies(
    requested: i32,
    max_copy_count: Option<i32>,
    page_count: usize,
    can_collate: bool,
) -> CopiesPlan {
    let count = clamp_copies(requested);
    if count == 1 {
        return CopiesPlan {
            ticket_copies: 1,
            document_repeats: 1,
        };
    }
    let printer_makes_them =
        max_copy_count.is_some_and(|max| max >= count) && (page_count <= 1 || can_collate);
    if printer_makes_them {
        CopiesPlan {
            ticket_copies: count,
            document_repeats: 1,
        }
    } else {
        CopiesPlan {
            ticket_copies: 1,
            document_repeats: count,
        }
    }
}
