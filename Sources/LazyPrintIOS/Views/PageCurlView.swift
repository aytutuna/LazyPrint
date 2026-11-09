#if os(iOS)
import LazyPrintKit
import SwiftUI
import UIKit

/// The sides of the plan as sheets of paper. A drag folds the page over and follows the finger; let go and it turns or falls
/// back. The fold is `UIPageViewController`'s double-sided page curl: the flap is the other face of the sheet, as it will come
/// out of the printer (a short-edge back upside down, a one-sided sheet's blank), and under it is the next side. So the
/// curl's pages are two for each side, the side and its reverse, and the sides around the current one are drawn ahead.
struct PageCurlView: UIViewControllerRepresentable {
    let count: Int
    let sheets: [Sheet]
    @Binding var side: Int
    /// `AppState.preview`. Only its changes are used, as the sign that the current side has been drawn or looks different.
    let image: CGImage?
    let drawn: @MainActor (Int) -> CGImage?
    let draw: @MainActor (Int) async -> CGImage?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal)
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        // A tap on the page's edge would turn it by accident, and fast taps at either end of the plan can crash the curl.
        for recognizer in controller.gestureRecognizers where recognizer is UITapGestureRecognizer {
            recognizer.isEnabled = false
        }
        return controller
    }

    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        context.coordinator.view = self
        context.coordinator.sync(controller)
    }

    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var view: PageCurlView
        private var isTurning = false
        private var lastImage: CGImage?
        private var lastSheets: [Sheet] = []
        private var neighbours: Task<Void, Never>?

        init(_ view: PageCurlView) {
            self.view = view
        }

        /// Turns to the state's side, and redraws the pages when the preview or the plan changed. A turn in progress finishes
        /// first, since setting the pages during one can leave them out of step.
        func sync(_ controller: UIPageViewController) {
            guard !isTurning else { return }
            let shown: PageController? = controller.viewControllers?.first as? PageController
            if shown?.side != view.side {
                let front: PageController = PageController(side: view.side, isReverse: false)
                let reverse: PageController = PageController(side: view.side, isReverse: true)
                front.show(view.drawn(view.side))
                load(reverse)
                // Off screen the animation's completion may never come, and it is what ends the turn.
                let animated: Bool = shown != nil && !UIAccessibility.isReduceMotionEnabled && controller.view.window != nil
                isTurning = animated
                controller.view.isUserInteractionEnabled = !animated
                // Set when the controller was made, this is gone by the time its view has loaded, and the pages are counted against it.
                controller.isDoubleSided = true
                controller.setViewControllers([front, reverse], direction: view.side > (shown?.side ?? 0) ? .forward : .reverse,
                                              animated: animated) { [weak self, weak controller] (_: Bool) in
                    guard animated, let self, let controller else { return }
                    self.isTurning = false
                    controller.view.isUserInteractionEnabled = true
                    self.sync(controller)
                }
            }
            if view.image !== lastImage || view.sheets != lastSheets {
                lastImage = view.image
                lastSheets = view.sheets
                for page in controller.viewControllers?.compactMap({ $0 as? PageController }) ?? [] {
                    // The current side is the state's to draw, and it comes with the change of image.
                    if page.isReverse {
                        load(page)
                    } else if let image = view.drawn(page.side) {
                        page.show(image)
                    }
                }
                drawNeighbours()
            }
        }

        /// The side of the plan a page shows, if any.
        private func side(on page: PageController) -> Int? {
            page.isReverse ? PreviewPosition.otherSide(of: page.side, sheets: view.sheets) : page.side
        }

        private func load(_ page: PageController) {
            guard let side = side(on: page) else {
                page.show(nil)
                return
            }
            if let image = view.drawn(side) {
                page.show(image)
                return
            }
            let draw: @MainActor (Int) async -> CGImage? = view.draw
            Task { [weak self, weak page] in
                _ = await draw(side)
                // Read back rather than show what was drawn, which is the old layout if the plan changed meanwhile. By then
                // this page may show another side, or none.
                guard let self, let page, self.side(on: page) == side, let image = self.view.drawn(side) else { return }
                page.show(image)
            }
        }

        private func drawNeighbours() {
            neighbours?.cancel()
            let draw: @MainActor (Int) async -> CGImage? = view.draw
            let current: Int = view.side
            let around: [Int] = [PreviewPosition.otherSide(of: current, sheets: view.sheets), current + 1, current - 1,
                                 PreviewPosition.otherSide(of: current - 1, sheets: view.sheets)]
                .compactMap { $0 }
                .filter { $0 != current && (0..<view.count).contains($0) }
            neighbours = Task {
                for side in around where !Task.isCancelled {
                    _ = await draw(side)
                }
            }
        }

        private func page(_ side: Int, isReverse: Bool) -> UIViewController? {
            guard (0..<view.count).contains(side) else { return nil }
            let page: PageController = PageController(side: side, isReverse: isReverse)
            load(page)
            return page
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let current = viewController as? PageController else { return nil }
            return current.isReverse ? page(current.side, isReverse: false) : page(current.side - 1, isReverse: true)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let current = viewController as? PageController else { return nil }
            return current.isReverse ? page(current.side + 1, isReverse: false) : page(current.side, isReverse: true)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                willTransitionTo pendingViewControllers: [UIViewController]) {
            isTurning = true
        }

        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            isTurning = false
            if completed, let page = pageViewController.viewControllers?.first as? PageController {
                // The plan may have shrunk during the drag.
                view.side = max(0, min(page.side, view.count - 1))
            }
            sync(pageViewController)
        }
    }
}

private final class PageController: UIViewController {
    let side: Int
    let isReverse: Bool
    private let imageView = UIImageView()

    init(side: Int, isReverse: Bool) {
        self.side = side
        self.isReverse = isReverse
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func loadView() {
        imageView.backgroundColor = .white
        imageView.contentMode = .scaleToFill
        view = imageView
    }

    func show(_ image: CGImage?) {
        imageView.image = image.map { UIImage(cgImage: $0) }
    }
}
#endif
