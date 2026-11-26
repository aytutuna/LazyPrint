use crate::{SheetPlan, SheetSide, turned_side};
use serde::{Deserialize, Serialize};

/// How a printer's paper path takes the stack back, learnt once per printer with one sheet (the two-sided check).
/// The defaults are the usual path.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct PaperPath {
    /// The user turns the stack over to reload it (false: reloads it as it lies).
    pub turn_stack_over: bool,
    /// Backs come out upside down unless turned 180 degrees.
    pub turn_backs: bool,
    /// The two-sided check was printed and answered.
    pub checked: bool,
}

impl Default for PaperPath {
    fn default() -> Self {
        Self {
            turn_stack_over: true,
            turn_backs: false,
            checked: false,
        }
    }
}

/// The sides of one pass, in the order sent to the printer.
#[derive(Clone, Debug, PartialEq)]
pub struct DuplexPass {
    pub sides: Vec<SheetSide>,
    /// Indices in `sides` of blank backs that get the near-white dot.
    pub marked: Vec<usize>,
}

/// The answer to "Do the arrows on both sides point to the same edge?".
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DuplexCheckAnswer {
    SameEdge,
    OppositeEdges,
    BothOnOneSide,
}

/// The fronts, then the backs. Sheets stack in the output tray in printing order and the tray feeds its top sheet
/// first: turning the stack over puts the first sheet on top, so the backs go in sheet order; reloading it as it
/// lies puts the last sheet on top, so they go in reverse, and each blank back then is marked so a driver that skips
/// blank pages cannot put the backs out of step. Every front gets a back, and the backs are turned 180 degrees when
/// `turn_backs`.
pub fn manual_passes(plan: &SheetPlan, path: &PaperPath) -> (DuplexPass, DuplexPass) {
    let fronts = plan.sheets.iter().map(|s| s.front.clone()).collect();
    let mut backs: Vec<SheetSide> = plan
        .sheets
        .iter()
        .map(|s| s.back.clone().unwrap_or_default())
        .map(|back| {
            if path.turn_backs {
                turned_side(&back, plan.area.paper)
            } else {
                back
            }
        })
        .collect();
    let mut marked = Vec::new();
    if !path.turn_stack_over {
        backs.reverse();
        marked = backs
            .iter()
            .enumerate()
            .filter(|(_, b)| b.placements.is_empty())
            .map(|(i, _)| i)
            .collect();
    }
    (
        DuplexPass {
            sides: fronts,
            marked: Vec::new(),
        },
        DuplexPass {
            sides: backs,
            marked,
        },
    )
}

/// The answer turned into a paper path. The same edge keeps it, opposite edges turn the backs, and both numbers on
/// one side means the stack must be reloaded the other way: the check runs again.
pub fn learn_paper_path(answer: DuplexCheckAnswer, path: PaperPath) -> PaperPath {
    match answer {
        DuplexCheckAnswer::SameEdge => PaperPath {
            checked: true,
            ..path
        },
        DuplexCheckAnswer::OppositeEdges => PaperPath {
            turn_backs: !path.turn_backs,
            checked: true,
            ..path
        },
        DuplexCheckAnswer::BothOnOneSide => PaperPath {
            turn_stack_over: !path.turn_stack_over,
            checked: false,
            ..path
        },
    }
}

/// What to do with the printed fronts.
pub fn reload_instruction(sheets: usize, path: &PaperPath) -> String {
    if path.turn_stack_over {
        let s = if sheets == 1 { "" } else { "s" };
        format!(
            "Take the {sheets} printed sheet{s} out. Turn the stack over and put it back in the tray, top edge first."
        )
    } else {
        "Put the stack back in the tray as it is, top edge first.".into()
    }
}
