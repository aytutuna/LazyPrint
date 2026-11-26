use lazyprint_layout::LayoutSize;
use lazyprint_paper::*;

#[test]
fn an_inverted_range_is_refused_and_clamping_never_panics() {
    let names = ["custom_min_300x100mm", "custom_max_100x300mm"];
    assert_eq!(custom_range(names), None);
    let inverted = PaperRange {
        min_width: 30000,
        max_width: 10000,
        min_height: 10000,
        max_height: 30000,
    };
    let clamped = inverted.clamp(LayoutSize {
        width: 600.0,
        height: 700.0,
    });
    assert!(clamped.width.is_finite() && clamped.height.is_finite());
}

#[test]
fn names_with_absurd_sizes_are_not_sizes() {
    assert_eq!(pwg_size("om_x_1e999x1e999mm"), None);
    assert_eq!(pwg_size("om_x_1e300x1e300mm"), None);
    let digits = "9".repeat(400);
    assert_eq!(pwg_size(&format!("om_x_{digits}x{digits}mm")), None);
    assert_eq!(media_size(&format!("Custom.{digits}x{digits}")), None);
    assert!(pwg_size("iso_a4_210x297mm").is_some());
}
