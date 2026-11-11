#if os(iOS)
import SwiftUI
import UIKit

/// Previous and next on the edges of the page, laid over the paper inside its own UIKit view: SwiftUI buttons, or a UIKit
/// view of their own, laid over the paper show but never get the tap. Between the buttons touches go through to the paper.
/// VoiceOver turns the pages with the preview's adjustable action instead.
final class ArrowsView: UIView {
    let back = ArrowsView.button("chevron.left", label: "Previous page", id: "print.previous")
    let forward = ArrowsView.button("chevron.right", label: "Next page", id: "print.next")
    var turn: (Int) -> Void = { _ in }

    override init(frame: CGRect) {
        super.init(frame: frame)
        back.addAction(UIAction { [weak self] _ in self?.turn(-1) }, for: .primaryActionTriggered)
        forward.addAction(UIAction { [weak self] _ in self?.turn(1) }, for: .primaryActionTriggered)
        addSubview(back)
        addSubview(forward)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func update(canGoBack: Bool, canGoOn: Bool, faint: Bool, turn: @escaping (Int) -> Void) {
        self.turn = turn
        back.isHidden = !canGoBack
        forward.isHidden = !canGoOn
        let alpha: CGFloat = faint ? 0.25 : 1
        if self.alpha != alpha {
            UIView.animate(withDuration: 0.4) { self.alpha = alpha }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size: CGFloat = 44
        back.frame = CGRect(x: 8, y: bounds.midY - size / 2, width: size, height: size)
        forward.frame = CGRect(x: bounds.width - 8 - size, y: bounds.midY - size / 2, width: size, height: size)
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
