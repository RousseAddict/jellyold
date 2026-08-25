import UIKit

// Full-screen viewer for Photo items in a "Home videos and photos" library.
//
// Only one image is held in memory at a time (swipe left/right to move through
// the set) — a paging scroll view holding several full-resolution photos runs
// the A5/A6 devices out of memory.
final class PhotoVC: UIViewController, UIScrollViewDelegate {

    private let items: [MediaItem]
    private var index: Int

    private var scrollView: UIScrollView!
    private var imageView: AsyncImageView!
    private var spinner: UIActivityIndicatorView!
    private var lastBuiltSize: CGSize = .zero
    private var chromeHidden = false

    init(items: [MediaItem], startAt: Int) {
        self.items = items
        self.index = min(max(startAt, 0), max(items.count - 1, 0))
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        scrollView = UIScrollView(frame: view.bounds)
        scrollView.backgroundColor = .black
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        view.addSubview(scrollView)

        imageView = AsyncImageView(frame: scrollView.bounds)
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black
        scrollView.addSubview(imageView)

        spinner = UIActivityIndicatorView(style: .whiteLarge)
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(singleTapped))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        view.addGestureRecognizer(singleTap)

        let next = UISwipeGestureRecognizer(target: self, action: #selector(swipedNext))
        next.direction = .left
        view.addGestureRecognizer(next)

        let prev = UISwipeGestureRecognizer(target: self, action: #selector(swipedPrev))
        prev.direction = .right
        view.addGestureRecognizer(prev)

        loadCurrent()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        imageView.cancel()
        if chromeHidden {
            navigationController?.setNavigationBarHidden(false, animated: animated)
            chromeHidden = false
        }
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        let size = view.bounds.size
        guard size.width > 0, !size.equalTo(lastBuiltSize) else { return }
        lastBuiltSize = size
        // A rotation invalidates the zoomed content offset — reset to fit.
        scrollView.zoomScale = 1
        scrollView.frame = view.bounds
        scrollView.contentSize = size
        imageView.frame = CGRect(origin: .zero, size: size)
        spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
    }

    // MARK: - Loading

    private func loadCurrent() {
        guard index < items.count, let serverURL = JellyfinServer.serverURL else { return }
        let item = items[index]
        title = items.count > 1 ? "\(item.name)  (\(index + 1)/\(items.count))" : item.name

        scrollView.zoomScale = 1
        imageView.image = nil
        spinner.startAnimating()

        // Capped to roughly the largest screen these devices have (640x1136) — the
        // originals are multi-megapixel and would be decoded at full size.
        let url = "\(serverURL)/Items/\(item.id)/Images/Primary?maxWidth=640&quality=90"
        imageView.load(url: url) { [weak self] in
            self?.spinner.stopAnimating()
        }
    }

    private func show(offset: Int) {
        let target = index + offset
        guard target >= 0, target < items.count else { return }
        index = target
        loadCurrent()
    }

    // MARK: - Gestures

    // Swipes only navigate at fit-scale; while zoomed in the scroll view owns the pan.
    @objc private func swipedNext() {
        guard scrollView.zoomScale <= 1.01 else { return }
        show(offset: 1)
    }

    @objc private func swipedPrev() {
        guard scrollView.zoomScale <= 1.01 else { return }
        show(offset: -1)
    }

    @objc private func singleTapped() {
        chromeHidden = !chromeHidden
        navigationController?.setNavigationBarHidden(chromeHidden, animated: true)
    }

    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        if scrollView.zoomScale > 1.01 {
            scrollView.setZoomScale(1, animated: true)
        } else {
            let point = g.location(in: imageView)
            let scale: CGFloat = 2.5
            let w = scrollView.bounds.width / scale
            let h = scrollView.bounds.height / scale
            scrollView.zoom(to: CGRect(x: point.x - w / 2, y: point.y - h / 2,
                                       width: w, height: h), animated: true)
        }
    }

    // MARK: - UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    // Keep the image centred while it is smaller than the viewport.
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        let bounds = scrollView.bounds.size
        let content = imageView.frame.size
        let x = content.width  < bounds.width  ? (bounds.width  - content.width)  / 2 : 0
        let y = content.height < bounds.height ? (bounds.height - content.height) / 2 : 0
        imageView.center = CGPoint(x: content.width / 2 + x, y: content.height / 2 + y)
    }
}
