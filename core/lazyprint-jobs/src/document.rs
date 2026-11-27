use lazyprint_layout::LayoutSize;

/// What a document is, as far as the job's printing rules care.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DocumentKind {
    Pdf { encrypted: bool },
    Photo,
    Imposed,
}

/// A document the user picked: its pages at the size the file shows them (a PDF page's /Rotate or a photo's
/// orientation applied, the user's turns not). `turns` are the user's quarter turns clockwise per page, 0 to 3; empty
/// means none turned.
#[derive(Clone, Debug, PartialEq)]
pub struct LoadedDocument {
    pub name: String,
    pub kind: DocumentKind,
    pub pages: Vec<LayoutSize>,
    pub turns: Vec<u8>,
}

impl LoadedDocument {
    pub fn new(name: &str, kind: DocumentKind, pages: Vec<LayoutSize>) -> Self {
        Self {
            name: name.to_string(),
            kind,
            pages,
            turns: Vec::new(),
        }
    }

    /// A page's size as the user's turns leave it: width and height swap for an odd turn.
    pub fn size(&self, page: usize) -> LayoutSize {
        let size = self.pages[page];
        if self.turns_of(page) % 2 == 1 {
            LayoutSize {
                width: size.height,
                height: size.width,
            }
        } else {
            size
        }
    }

    pub fn turns_of(&self, page: usize) -> u8 {
        self.turns.get(page).copied().unwrap_or(0)
    }

    /// The document with a page (every page for none) turned a quarter turn more: -1 left, 1 right, wrapping to 0 to 3.
    pub fn turned(&self, page: Option<usize>, quarter: i32) -> Self {
        let turns: Vec<u8> = (0..self.pages.len())
            .map(|i| {
                if page.is_none_or(|p| p == i) {
                    (i32::from(self.turns_of(i)) + quarter).rem_euclid(4) as u8
                } else {
                    self.turns_of(i)
                }
            })
            .collect();
        Self {
            turns: if turns.iter().any(|&t| t != 0) {
                turns
            } else {
                Vec::new()
            },
            ..self.clone()
        }
    }

    pub fn is_turned(&self) -> bool {
        self.turns.iter().any(|&t| t != 0)
    }
}

/// Whether every document is a photo; a job with no documents is not one.
pub fn photos_only(documents: &[LoadedDocument]) -> bool {
    !documents.is_empty() && documents.iter().all(|d| d.kind == DocumentKind::Photo)
}
