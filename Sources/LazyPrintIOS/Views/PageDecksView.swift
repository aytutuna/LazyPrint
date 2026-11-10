#if os(iOS)
import SwiftUI
import UIKit

/// A two-sided job as two decks of paper, the way it comes out of the printer and is read: the sheets to come on the right,
/// front up, and the ones turned over on the left, back up. A drag turns the top sheet over from one deck to the other, so
/// both of its sides show on the way. This is `UIPageViewController`'s curl with the spine in the middle, which takes two
/// pages at a time. Its pages run: nothing, sheet 1 front, sheet 1 back, sheet 2 front, ... , last back, nothing; spread `j`
/// is the back of sheet `j` on the left and the front of sheet `j + 1` on the right (sides `2j - 1` and `2j`).
struct PageDecksView: UIViewControllerRepresentable {
    /// The plan's sides, front and back of each sheet in turn.
    let count: Int
    @Binding var side: Int
    /// `AppState.preview`. Only its changes are used, as the sign that the sides have been drawn or look different.
    let image: CGImage?
    let drawn: @MainActor (Int) -> CGImage?
    let draw: @MainActor (Int) async -> CGImage?
    /// A pinch outward on a page, with the side it was on.
    let zoomIn: (Int) -> Void

    static func spread(of side: Int) -> Int {
        (side + 1) / 2
    }

    /// The side a spread is known by: the front on the right, or the last back once every sheet is turned.
    static func side(of spread: Int, count: Int) -> Int {
        max(0, min(2 * spread, count - 1))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal,
                                              options: [.spineLocation: NSNumber(value: UIPageViewController.SpineLocation.mid.rawValue)])
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        controller.view.backgroundColor = .clear
        // A tap on a page's edge would turn it by accident, and fast taps at either end can crash the curl.
        for recognizer in controller.gestureRecognizers where recognizer is UITapGestureRecognizer {
            recognizer.isEnabled = false
        }
        controller.view.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator,
                                                                      action: #selector(Coordinator.pinched(_:))))
        return controller
    }

    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        context.coordinator.view = self
        context.coordinator.sync(controller)
    }

    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var view: PageDecksView
        private var isTurning = false
        private var lastImage: CGImage?
        private var lastCount = 0
        private var neighbours: Task<Void, Never>?
        private var pinchedIn = false

        init(_ view: PageDecksView) {
            self.view = view
        }

        /// Turns to the state's spread, and redraws the pages when the preview or the plan changed. A turn in progress
        /// finishes first, since setting the pages during one can leave them out of step.
        func sync(_ controller: UIPageViewController) {
            guard !isTurning else { return }
            let wanted: Int = PageDecksView.spread(of: view.side)
            let shown: Int? = (controller.viewControllers?.first as? DeckPage).map { $0.entry / 2 }
            if shown != wanted {
                let pages: [DeckPage] = [DeckPage(entry: 2 * wanted, count: view.count),
                                         DeckPage(entry: 2 * wanted + 1, count: view.count)]
                pages.forEach(load)
                let animated: Bool = shown.map { abs($0 - wanted) == 1 } == true && !UIAccessibility.isReduceMotionEnabled
                    && controller.view.window != nil
                isTurning = animated
                controller.view.isUserInteractionEnabled = !animated
                controller.setViewControllers(pages, direction: wanted > (shown ?? 0) ? .forward : .reverse,
                                              animated: animated) { [weak self, weak controller] (_: Bool) in
                    guard animated, let self, let controller else { return }
                    self.isTurning = false
                    controller.view.isUserInteractionEnabled = true
                    self.sync(controller)
                }
            }
            if view.image !== lastImage || view.count != lastCount {
                lastImage = view.image
                lastCount = view.count
                for page in controller.viewControllers?.compactMap({ $0 as? DeckPage }) ?? [] {
                    load(page)
                }
                drawNeighbours()
            }
        }

        private func load(_ page: DeckPage) {
            guard let side = page.side, side < view.count else {
                page.show(nil, isPaper: false)
                return
            }
            if let image = view.drawn(side) {
                page.show(image, isPaper: true)
                return
            }
            page.show(nil, isPaper: true)
            let draw: @MainActor (Int) async -> CGImage? = view.draw
            Task { [weak self, weak page] in
                _ = await draw(side)
                // Read back rather than show what was drawn, which is the old layout if the plan changed meanwhile.
                guard let self, let page, page.side == side, let image = self.view.drawn(side) else { return }
                page.show(image, isPaper: true)
            }
        }

        /// The spreads either side of this one.
        private func drawNeighbours() {
            neighbours?.cancel()
            let draw: @MainActor (Int) async -> CGImage? = view.draw
            let spread: Int = PageDecksView.spread(of: view.side)
            let around: [Int] = [2 * spread + 1, 2 * spread + 2, 2 * spread - 2, 2 * spread - 3]
                .filter { (0..<view.count).contains($0) }
            neighbours = Task {
                for side in around where !Task.isCancelled {
                    _ = await draw(side)
                }
            }
        }

        private func page(_ entry: Int) -> UIViewController? {
            guard (0...view.count + 1).contains(entry) else { return nil }
            let page = DeckPage(entry: entry, count: view.count)
            load(page)
            return page
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            (viewController as? DeckPage).flatMap { page($0.entry - 1) }
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            (viewController as? DeckPage).flatMap { page($0.entry + 1) }
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                willTransitionTo pendingViewControllers: [UIViewController]) {
            isTurning = true
        }

        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            isTurning = false
            if completed, let page = pageViewController.viewControllers?.first as? DeckPage {
                // The plan may have shrunk during the drag.
                view.side = PageDecksView.side(of: page.entry / 2, count: view.count)
            }
            sync(pageViewController)
        }

        @objc func pinched(_ pinch: UIPinchGestureRecognizer) {
            switch pinch.state {
            case .began:
                pinchedIn = false
            case .changed:
                guard !pinchedIn, pinch.scale > 1.15, let pinchView = pinch.view,
                      let pages = (pinch.view?.next as? UIPageViewController)?.viewControllers as? [DeckPage] else { return }
                pinchedIn = true
                let onLeft: Bool = pinch.location(in: pinchView).x < pinchView.bounds.midX
                let sides: [Int] = (onLeft ? pages : pages.reversed()).compactMap { $0.side }.filter { $0 < view.count }
                if let side = sides.first {
                    view.zoomIn(side)
                }
            default:
                break
            }
        }
    }
}

/// One entry of the curl's run: a side of the plan, or nothing before the first sheet and after the last.
private final class DeckPage: UIViewController {
    let entry: Int
    let side: Int?
    private let imageView = UIImageView()

    init(entry: Int, count: Int) {
        self.entry = entry
        self.side = entry >= 1 && entry <= count ? entry - 1 : nil
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func loadView() {
        imageView.contentMode = .scaleToFill
        imageView.layer.borderColor = UIColor.black.withAlphaComponent(0.15).cgColor
        view = imageView
    }

    /// `isPaper` false is an empty deck, where nothing is drawn.
    func show(_ image: CGImage?, isPaper: Bool) {
        loadViewIfNeeded()
        imageView.image = image.map { UIImage(cgImage: $0) }
        imageView.backgroundColor = isPaper ? .white : .clear
        imageView.layer.borderWidth = isPaper ? 0.5 : 0
    }
}
#endif
