#if os(iOS)
import SwiftUI
import UIKit

/// Previous and next on the edges of the page. UIKit buttons rather than SwiftUI ones: drawn by SwiftUI over the paper's
/// UIKit views they show but never get the tap. Between the buttons touches go through to the paper.
struct PageArrows: UIViewRepresentable {
    let canGoBack: Bool
    let canGoOn: Bool
    let turn: (Int) -> Void

    func makeUIView(context: Context) -> ArrowsView {
        ArrowsView()
    }

    func updateUIView(_ arrows: ArrowsView, context: Context) {
        arrows.turn = turn
        arrows.back.isHidden = !canGoBack
        arrows.next.isHidden = !canGoOn
    }
}

final class ArrowsView: UIView {
    let back = ArrowsView.button("chevron.left", label: "Previous page", id: "print.previous")
    let next = ArrowsView.button("chevron.right", label: "Next page", id: "print.next")
    var turn: (Int) -> Void = { _ in }

    override init(frame: CGRect) {
        super.init(frame: frame)
        back.addAction(UIAction { [weak self] _ in self?.turn(-1) }, for: .primaryActionTriggered)
        next.addAction(UIAction { [weak self] _ in self?.turn(1) }, for: .primaryActionTriggered)
        addSubview(back)
        addSubview(next)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size: CGFloat = 44
        back.frame = CGRect(x: 8, y: bounds.midY - size / 2, width: size, height: size)
        next.frame = CGRect(x: bounds.width - 8 - size, y: bounds.midY - size / 2, width: size, height: size)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit: UIView? = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    private static func button(_ symbol: String, label: String, id: String) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: symbol,
                               withConfiguration: UIImage.SymbolConfiguration(textStyle: .title3)
                                   .applying(UIImage.SymbolConfiguration(weight: .semibold)))
        config.cornerStyle = .capsule
        config.baseBackgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.8)
        config.baseForegroundColor = .label
        let button = UIButton(configuration: config)
        button.accessibilityLabel = label
        button.accessibilityIdentifier = id
        return button
    }
}
#endif
