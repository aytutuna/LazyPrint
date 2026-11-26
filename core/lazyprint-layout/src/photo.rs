use crate::LayoutSize;

/// A print size.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PhotoSize {
    /// "4x6", "5x7", "8x10", "3.5x5", "wallet", "10x15cm", "13x18cm" or "page".
    pub id: &'static str,
    pub title: &'static str,
    /// Portrait; none is as large as the cell allows.
    pub size: Option<LayoutSize>,
}

const fn inches(width: f64, height: f64) -> Option<LayoutSize> {
    Some(LayoutSize {
        width: width * 72.0,
        height: height * 72.0,
    })
}

const fn centimetres(width: f64, height: f64) -> Option<LayoutSize> {
    Some(LayoutSize {
        width: width * 72.0 / 2.54,
        height: height * 72.0 / 2.54,
    })
}

pub const PHOTO_SIZES: [PhotoSize; 8] = [
    PhotoSize {
        id: "4x6",
        title: "4 × 6 in",
        size: inches(4.0, 6.0),
    },
    PhotoSize {
        id: "5x7",
        title: "5 × 7 in",
        size: inches(5.0, 7.0),
    },
    PhotoSize {
        id: "8x10",
        title: "8 × 10 in",
        size: inches(8.0, 10.0),
    },
    PhotoSize {
        id: "3.5x5",
        title: "3.5 × 5 in",
        size: inches(3.5, 5.0),
    },
    PhotoSize {
        id: "wallet",
        title: "Wallet, 2.5 × 3.5 in",
        size: inches(2.5, 3.5),
    },
    PhotoSize {
        id: "10x15cm",
        title: "10 × 15 cm",
        size: centimetres(10.0, 15.0),
    },
    PhotoSize {
        id: "13x18cm",
        title: "13 × 18 cm",
        size: centimetres(13.0, 18.0),
    },
    PhotoSize {
        id: "page",
        title: "Largest that fits",
        size: None,
    },
];

/// The size with this id; "page" for an id nobody knows.
pub fn photo_size(id: &str) -> &'static PhotoSize {
    PHOTO_SIZES
        .iter()
        .find(|s| s.id == id)
        .unwrap_or(&PHOTO_SIZES[PHOTO_SIZES.len() - 1])
}
