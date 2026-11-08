#if os(iOS)
import SwiftUI
import UIKit

/// The sides of the plan as a stack of paper. A drag folds the page over and follows the finger; let go and it turns or falls
/// back. The fold is `UIPageViewController`'s page curl, which shows the side under the page as soon as the drag starts, so
/// the sides next to the current one are drawn ahead of it.
struct PageCurlView: UIViewControllerRepresentable {
    let count: Int
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
        private var neighbours: Task<Void, Never>?

        init(_ view: PageCurlView) {
            self.view = view
        }

        /// Turns to the state's side, and redraws the page when the preview changed. A turn in progress finishes first, since
        /// setting the pages during one can leave them out of step.
        func sync(_ controller: UIPageViewController) {
            guard !isTurning else { return }
            let shown: PageController? = controller.viewControllers?.first as? PageController
            if shown?.side != view.side {
                let page: PageController = PageController(side: view.side)
                page.show(view.drawn(view.side))
                // Off screen the animation's completion may never come, and it is what ends the turn.
                let animated: Bool = shown != nil && !UIAccessibility.isReduceMotionEnabled && controller.view.window != nil
                isTurning = animated
                controller.view.isUserInteractionEnabled = !animated
                controller.setViewControllers([page], direction: view.side > (shown?.side ?? 0) ? .forward : .reverse,
                                              animated: animated) { [weak self, weak controller] (_: Bool) in
                    guard animated, let self, let controller else { return }
                    self.isTurning = false
                    controller.view.isUserInteractionEnabled = true
                    self.sync(controller)
                }
            }
            if view.image !== lastImage {
                lastImage = view.image
                if let page = controller.viewControllers?.first as? PageController {
                    load(page)
                }
                drawNeighbours()
            }
        }

        private func load(_ page: PageController) {
            if let image = view.drawn(page.side) {
                page.show(image)
                return
            }
            let draw: @MainActor (Int) async -> CGImage? = view.draw
            Task { [weak self, weak page] in
                guard let side = page?.side else { return }
                _ = await draw(side)
                // Read back rather than show what was drawn, which is the old layout if the plan changed meanwhile.
                page?.show(self?.view.drawn(side))
            }
        }

        private func drawNeighbours() {
            neighbours?.cancel()
            let draw: @MainActor (Int) async -> CGImage? = view.draw
            let around: [Int] = [view.side + 1, view.side - 1].filter { (0..<view.count).contains($0) }
            neighbours = Task {
                for side in around where !Task.isCancelled {
                    _ = await draw(side)
                }
            }
        }

        private func page(_ side: Int) -> UIViewController? {
            guard (0..<view.count).contains(side) else { return nil }
            let page: PageController = PageController(side: side)
            load(page)
            return page
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            (viewController as? PageController).flatMap { page($0.side - 1) }
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            (viewController as? PageController).flatMap { page($0.side + 1) }
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
    private let imageView = UIImageView()

    init(side: Int) {
        self.side = side
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
