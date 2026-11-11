#if os(iOS)
import LazyPrintKit
import QuartzCore
import SwiftUI
import UIKit

/// The sides of the plan as sheets of paper. A drag folds the page over from its edge, the fold following the finger; let go
/// and it turns or falls back. The flap is the other face of the sheet as it will come out of the printer (a short-edge back
/// upside down, a one-sided sheet's blank), and under the page is the next side. `UIPageViewController`'s curl cannot show a
/// back with one page in view (it wants a single page with the spine at the edge), so the fold is drawn here, as paper
/// folded flat along a line. A pinch zooms the page, which then pans instead of folding; on a two-sided job a pinch inward
/// at full size goes back to the two decks.
struct PageFoldView: UIViewRepresentable {
    let count: Int
    let sheets: [Sheet]
    @Binding var side: Int
    /// `AppState.preview`. Only its changes are used, as the sign that the current side has been drawn or looks different.
    let image: CGImage?
    let drawn: @MainActor (Int) -> CGImage?
    let draw: @MainActor (Int) async -> CGImage?
    /// The page's size at full zoom out, centred in the view.
    let paperSize: CGSize
    let zoomOut: (() -> Void)?
    let zoomed: (CGFloat) -> Void
    /// A tap on the paper.
    let touched: () -> Void

    func makeUIView(context: Context) -> PaperScroll {
        PaperScroll()
    }

    func updateUIView(_ scroll: PaperScroll, context: Context) {
        scroll.zoomOut = zoomOut
        scroll.zoomed = zoomed
        scroll.touched = touched
        scroll.paperSize = paperSize
        let paper: FoldingPaper = scroll.paper
        let side: Binding<Int> = $side
        paper.onTurn = { side.wrappedValue = $0 }
        paper.drawn = drawn
        paper.draw = draw
        paper.update(side: side.wrappedValue, count: count, sheets: sheets, image: image)
    }
}

/// The page in a scroll view for zooming. At full size the scroll view keeps still, so a drag folds the page and the screen
/// around it still scrolls.
final class PaperScroll: UIScrollView, UIScrollViewDelegate {
    let paper = FoldingPaper()
    var zoomOut: (() -> Void)?
    var zoomed: (CGFloat) -> Void = { _ in }
    var touched: () -> Void = {}
    var paperSize: CGSize = .zero {
        didSet {
            guard paperSize != oldValue else { return }
            let wasZoomed: Bool = zoomScale > 1
            setZoomScale(1, animated: false)
            holder.bounds = CGRect(origin: .zero, size: paperSize)
            holder.layer.shadowPath = UIBezierPath(rect: holder.bounds).cgPath
            paper.frame = holder.bounds
            contentSize = paperSize
            setNeedsLayout()
            if wasZoomed {
                // Not during the update that set the size.
                DispatchQueue.main.async { [zoomed] in zoomed(1) }
            }
        }
    }
    private let holder = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 4
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        panGestureRecognizer.isEnabled = false
        holder.layer.shadowColor = UIColor.black.cgColor
        holder.layer.shadowOpacity = 0.35
        holder.layer.shadowRadius = 6
        holder.layer.shadowOffset = CGSize(width: 0, height: 2)
        holder.addSubview(paper)
        addSubview(holder)
        let twice = UITapGestureRecognizer(target: self, action: #selector(tappedTwice(_:)))
        twice.numberOfTapsRequired = 2
        addGestureRecognizer(twice)
        let once = UITapGestureRecognizer(target: self, action: #selector(tappedOnce))
        once.cancelsTouchesInView = false
        once.delegate = TapAlongside.shared
        once.require(toFail: twice)
        addGestureRecognizer(once)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size: CGSize = holder.frame.size
        holder.center = CGPoint(x: max(size.width, bounds.width) / 2, y: max(size.height, bounds.height) / 2)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        holder
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        let isZoomed: Bool = zoomScale > 1.01
        panGestureRecognizer.isEnabled = isZoomed
        paper.isFoldable = !isZoomed
        setNeedsLayout()
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        // Room to pinch inward past full size, which is the way back to the decks.
        minimumZoomScale = zoomOut == nil ? 1 : 0.6
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        minimumZoomScale = 1
        if scale < 0.9, let zoomOut {
            zoomOut()
        } else if scale < 1 {
            setZoomScale(1, animated: true)
        }
        zoomed(max(1, scale))
    }

    @objc private func tappedOnce() {
        touched()
    }

    @objc private func tappedTwice(_ tap: UITapGestureRecognizer) {
        if zoomScale > 1.01 {
            setZoomScale(1, animated: true)
            zoomed(1)
        } else {
            let point: CGPoint = tap.location(in: holder)
            let size = CGSize(width: bounds.width / 2.5, height: bounds.height / 2.5)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
                 animated: true)
        }
    }
}

/// Lets a tap that only wakes the arrows up be seen along with the arrows' own: on its own it would win the tap and the
/// button under the finger would never fire.
final class TapAlongside: NSObject, UIGestureRecognizerDelegate {
    static let shared = TapAlongside()

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}

final class FoldingPaper: UIView {
    var onTurn: (Int) -> Void = { _ in }
    /// Off while the page is zoomed, when a drag pans it.
    var isFoldable = true
    var drawn: @MainActor (Int) -> CGImage? = { _ in nil }
    var draw: @MainActor (Int) async -> CGImage? = { _ in nil }

    /// A page turning over: `top` is the side folding away, `bottom` the one under it. `start` is the point of the page that
    /// was lifted and `corner` where it is now; the fold is the line halfway between them.
    private struct Turn {
        let top: Int
        let bottom: Int
        let forward: Bool
        let byHand: Bool
        let start: CGPoint
        /// The corner before the turn: where it was lifted going forward, and with the fold on the far edge (all of the page
        /// folded away) going back.
        let rest: CGPoint
        var corner: CGPoint
    }

    private struct Motion {
        let from: CGPoint
        let to: CGPoint
        let lift: CGFloat
        let begun: CFTimeInterval
        let duration: CFTimeInterval
        let completes: Bool
    }

    private final class Face {
        let layer = CALayer()
        var side: Int?
    }

    private var side = -1
    private var wanted = 0
    private var count = 0
    private var sheets: [Sheet] = []
    private var lastImage: CGImage?
    private var turn: Turn?
    private var motion: Motion?
    private var link: CADisplayLink?
    private var neighbours: Task<Void, Never>?

    private let front = Face()
    private let back = Face()
    private let under = Face()
    private let frontMask = CAShapeLayer()
    private let flap = CALayer()
    private let flapMask = CAShapeLayer()
    private let shade = CAGradientLayer()
    private let edgeShadow = CAShapeLayer()
    private let flapShadow = CAShapeLayer()
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .white
        clipsToBounds = true
        for face in [front, back, under] {
            face.layer.backgroundColor = UIColor.white.cgColor
            face.layer.contentsGravity = .resize
        }
        for shadow in [edgeShadow, flapShadow] {
            shadow.fillColor = UIColor.white.cgColor
            shadow.shadowColor = UIColor.black.cgColor
            shadow.shadowOpacity = 0.3
            shadow.shadowRadius = 6
            shadow.shadowOffset = .zero
        }
        shade.colors = [UIColor.black.withAlphaComponent(0.2).cgColor, UIColor.black.withAlphaComponent(0).cgColor]
        back.layer.anchorPoint = .zero
        front.layer.mask = frontMask
        flap.mask = flapMask
        flap.addSublayer(back.layer)
        flap.addSublayer(shade)
        for sublayer in [under.layer, edgeShadow, front.layer, flapShadow, flap] {
            layer.addSublayer(sublayer)
        }
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        layoutFold()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func update(side wanted: Int, count: Int, sheets: [Sheet], image: CGImage?) {
        let changed: Bool = image !== lastImage || sheets != self.sheets
        self.wanted = wanted
        self.count = count
        self.sheets = sheets
        lastImage = image
        if turn == nil && wanted != side {
            go(to: wanted)
        } else if changed {
            refresh()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutFold()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Off screen the display link would keep the turn, and this view, going.
        if window == nil, let motion {
            finish(motion.completes)
        }
    }

    // MARK: Sides

    private func otherSide(_ side: Int?) -> Int? {
        side.flatMap { PreviewPosition.otherSide(of: $0, sheets: sheets) }
    }

    /// Puts a side on a face: the image if it has been drawn or another face has it, else a draw, unless `draws` is false
    /// because the state is drawing it already as the current side.
    private func show(_ face: Face, side: Int?, draws: Bool = true) {
        face.side = side
        guard let side else {
            quietly { face.layer.contents = nil }
            return
        }
        var shown: Any? = drawn(side)
        if shown == nil {
            let faces: [Face] = [front, back, under]
            shown = faces.first { (other: Face) -> Bool in other !== face && other.side == side }?.layer.contents
        }
        quietly { face.layer.contents = shown }
        guard shown == nil, draws else { return }
        let draw: @MainActor (Int) async -> CGImage? = draw
        Task { [weak self, weak face] in
            _ = await draw(side)
            // Read back rather than show what was drawn, which is the old layout if the plan changed meanwhile. By then the
            // face may show another side, or none.
            guard let self, let face, face.side == side, let image = self.drawn(side) else { return }
            self.quietly { face.layer.contents = image }
        }
    }

    /// The plan or the current side's picture changed.
    private func refresh() {
        if let side = front.side, let image = drawn(side) {
            quietly { front.layer.contents = image }
        }
        show(back, side: otherSide(front.side))
        if let side = under.side {
            show(under, side: side, draws: side != self.side)
        }
        drawNeighbours()
    }

    private func drawNeighbours() {
        neighbours?.cancel()
        let draw: @MainActor (Int) async -> CGImage? = draw
        let around: [Int] = [otherSide(side), side + 1, side - 1, otherSide(side - 1)]
            .compactMap { $0 }
            .filter { $0 != side && (0..<count).contains($0) }
        neighbours = Task {
            for side in around where !Task.isCancelled {
                _ = await draw(side)
            }
        }
    }

    /// Lies flat on a side.
    private func settle(on new: Int) {
        turn = nil
        motion = nil
        side = new
        show(front, side: new, draws: false)
        show(back, side: otherSide(new))
        under.side = nil
        layoutFold()
        drawNeighbours()
    }

    private func go(to target: Int) {
        let animated: Bool = side >= 0 && abs(target - side) == 1 && window != nil && !UIAccessibility.isReduceMotionEnabled
        if animated, begin(forward: target > side, at: CGPoint(x: bounds.width, y: bounds.height * 0.9), byHand: false),
           let turn {
            animate(to: turn.forward ? done(turn) : turn.start, completes: true, lift: bounds.height * 0.12)
        } else {
            settle(on: target)
        }
    }

    // MARK: Turning

    private func begin(forward: Bool, at start: CGPoint, byHand: Bool) -> Bool {
        let top: Int = forward ? side : side - 1
        let bottom: Int = top + 1
        guard top >= 0, bottom < count, bounds.width > 0 else { return false }
        let rest: CGPoint = forward ? start : CGPoint(x: -start.x, y: start.y)
        turn = Turn(top: top, bottom: bottom, forward: forward, byHand: byHand, start: start, rest: rest, corner: rest)
        show(front, side: top, draws: top != wanted)
        show(back, side: otherSide(top))
        show(under, side: bottom, draws: bottom != wanted)
        layoutFold()
        return true
    }

    /// Where the corner goes for the top page to have folded right off: the fold on the far edge.
    private func done(_ turn: Turn) -> CGPoint {
        CGPoint(x: -turn.start.x, y: turn.start.y)
    }

    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard gesture === pan else { return super.gestureRecognizerShouldBegin(gesture) }
        let velocity: CGPoint = pan.velocity(in: self)
        // Up and down is the screen's scrolling.
        guard isFoldable, turn == nil, abs(velocity.x) > abs(velocity.y) else { return false }
        return velocity.x < 0 ? side + 1 < count : side > 0
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        let moved: CGPoint = pan.translation(in: self)
        switch pan.state {
        case .began:
            let forward: Bool = pan.velocity(in: self).x < 0
            // Going back the page comes in from the far edge, so it is lifted by its free edge and the fold crosses all of it.
            let touched = CGPoint(x: forward ? pan.location(in: self).x - moved.x : bounds.width,
                                  y: pan.location(in: self).y - moved.y)
            _ = begin(forward: forward, at: touched, byHand: true)
        case .changed:
            guard var turn, turn.byHand else { return }
            // Twice the finger's travel, so the fold, halfway to the corner, moves with the finger. Past the lifted point the
            // page lies flat; any further and the fold would turn the other part of it over.
            turn.corner = CGPoint(x: turn.rest.x + 2 * moved.x, y: turn.rest.y + 2 * moved.y)
            if turn.corner.x >= turn.start.x {
                turn.corner = turn.start
            }
            self.turn = turn
            layoutFold()
        case .ended, .cancelled, .failed:
            guard let turn, turn.byHand, motion == nil else { return }
            let speed: CGFloat = pan.velocity(in: self).x
            let far: CGFloat = bounds.width * 0.25
            let completes: Bool = pan.state == .ended && (turn.forward
                ? (moved.x < -far && speed < 200) || speed < -500
                : (moved.x > far && speed > -200) || speed > 500)
            let target: CGPoint = turn.forward ? (completes ? done(turn) : turn.start) : (completes ? turn.start : turn.rest)
            animate(to: target, completes: completes, lift: 0)
        default:
            break
        }
    }

    private func animate(to target: CGPoint, completes: Bool, lift: CGFloat) {
        guard let turn else { return }
        let distance: CGFloat = hypot(target.x - turn.corner.x, target.y - turn.corner.y)
        let duration: CFTimeInterval = min(0.45, max(0.15, Double(distance / max(bounds.width, 1)) * 0.22))
        motion = Motion(from: turn.corner, to: target, lift: lift, begun: CACurrentMediaTime(), duration: duration,
                        completes: completes)
        link?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard var turn, let motion else {
            link.invalidate()
            return
        }
        let progress: Double = min(1, (CACurrentMediaTime() - motion.begun) / motion.duration)
        let eased = CGFloat(1 - pow(1 - progress, 3))
        turn.corner = CGPoint(x: motion.from.x + (motion.to.x - motion.from.x) * eased,
                              y: motion.from.y + (motion.to.y - motion.from.y) * eased - sin(.pi * eased) * motion.lift)
        self.turn = turn
        layoutFold()
        if progress >= 1 {
            finish(motion.completes)
        }
    }

    private func finish(_ completed: Bool) {
        link?.invalidate()
        link = nil
        guard let turn else { return }
        let landed: Int = turn.forward ? (completed ? turn.bottom : turn.top) : (completed ? turn.top : turn.bottom)
        settle(on: max(0, min(landed, count - 1)))
        if turn.byHand && completed {
            wanted = side
            // Not during the update that may have taken the view off screen.
            let onTurn: (Int) -> Void = onTurn
            let landed: Int = side
            DispatchQueue.main.async { onTurn(landed) }
        } else if wanted != side {
            go(to: wanted)
        }
    }

    // MARK: The fold

    /// Paper folded flat along the line halfway between where the lifted point was and where it is now. What lay on the
    /// lifted side of the line is turned over onto the page, so the flap shows the back of that part: a point of the page
    /// lands at its reflection over the line, and the back seen there is the back's picture at the point mirrored across
    /// the sheet's width (backs read the right way once the sheet is turned over side to side).
    private func layoutFold() {
        quietly {
            let rect = CGRect(origin: .zero, size: bounds.size)
            under.layer.frame = rect
            front.layer.frame = rect
            frontMask.frame = rect
            flap.frame = rect
            flapMask.frame = rect
            shade.frame = rect
            edgeShadow.frame = rect
            flapShadow.frame = rect
            back.layer.bounds = rect
            back.layer.position = .zero

            let folding: Turn? = turn.flatMap { hypot($0.start.x - $0.corner.x, $0.start.y - $0.corner.y) > 0.5 ? $0 : nil }
            under.layer.isHidden = turn == nil
            for part in [flap, edgeShadow, flapShadow] as [CALayer] {
                part.isHidden = folding == nil
            }
            guard let folding, rect.width > 0, rect.height > 0 else {
                frontMask.path = CGPath(rect: rect, transform: nil)
                return
            }
            let length: CGFloat = hypot(folding.start.x - folding.corner.x, folding.start.y - folding.corner.y)
            let normal = CGPoint(x: (folding.start.x - folding.corner.x) / length, y: (folding.start.y - folding.corner.y) / length)
            let middle = CGPoint(x: (folding.start.x + folding.corner.x) / 2, y: (folding.start.y + folding.corner.y) / 2)
            let past: (CGPoint) -> CGFloat = { ($0.x - middle.x) * normal.x + ($0.y - middle.y) * normal.y }
            let reflect: (CGPoint) -> CGPoint = { (point: CGPoint) -> CGPoint in
                let along: CGFloat = 2 * past(point)
                return CGPoint(x: point.x - along * normal.x, y: point.y - along * normal.y)
            }
            let paper: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: rect.width, y: 0),
                                    CGPoint(x: rect.width, y: rect.height), CGPoint(x: 0, y: rect.height)]
            let kept: [CGPoint] = Self.clip(paper) { -past($0) }
            let folded: [CGPoint] = Self.clip(paper, past).map(reflect)

            frontMask.path = Self.path(kept)
            edgeShadow.path = Self.path(kept)
            edgeShadow.shadowPath = edgeShadow.path
            flapMask.path = Self.path(folded)
            flapShadow.path = flapMask.path
            flapShadow.shadowPath = flapMask.path

            let mirror = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.width, ty: 0)
            let offset: CGFloat = 2 * (middle.x * normal.x + middle.y * normal.y)
            let over = CGAffineTransform(a: 1 - 2 * normal.x * normal.x, b: -2 * normal.x * normal.y,
                                         c: -2 * normal.x * normal.y, d: 1 - 2 * normal.y * normal.y,
                                         tx: offset * normal.x, ty: offset * normal.y)
            back.layer.setAffineTransform(mirror.concatenating(over))

            // Darker along the fold, where the paper bends away from the light.
            let reach: CGFloat = min(rect.width, rect.height) * 0.35
            shade.startPoint = CGPoint(x: middle.x / rect.width, y: middle.y / rect.height)
            shade.endPoint = CGPoint(x: (middle.x - normal.x * reach) / rect.width, y: (middle.y - normal.y * reach) / rect.height)
        }
    }

    /// The part of a convex polygon where `distance` is not negative.
    private static func clip(_ polygon: [CGPoint], _ distance: (CGPoint) -> CGFloat) -> [CGPoint] {
        var kept: [CGPoint] = []
        for (index, point) in polygon.enumerated() {
            let next: CGPoint = polygon[(index + 1) % polygon.count]
            let here: CGFloat = distance(point)
            let there: CGFloat = distance(next)
            if here >= 0 { kept.append(point) }
            if (here >= 0) != (there >= 0) {
                let share: CGFloat = here / (here - there)
                kept.append(CGPoint(x: point.x + (next.x - point.x) * share, y: point.y + (next.y - point.y) * share))
            }
        }
        return kept
    }

    private static func path(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }

    private func quietly(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }
}
#endif
