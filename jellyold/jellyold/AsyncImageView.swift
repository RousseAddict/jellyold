import UIKit

class AsyncImageView: UIImageView {

    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 60
        c.totalCostLimit = 25 * 1024 * 1024 // 25 MB
        return c
    }()

    private static let loadQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 3
        q.name = "com.jellyold.imageLoad"
        return q
    }()

    private var loadingURL: String?

    // `completion` runs on the main thread once this view's image is settled — it is
    // skipped when a newer load() has superseded this one, so the caller's spinner
    // stays with whichever request currently owns the view.
    func load(url: String, completion: (() -> Void)? = nil) {
        if let cached = AsyncImageView.cache.object(forKey: url as NSString) {
            image = cached
            completion?()
            return
        }
        loadingURL = url
        image = nil
        guard let nsurl = URL(string: url) else { completion?(); return }
        let capturedURL = url
        NSURLConnection.sendAsynchronousRequest(URLRequest(url: nsurl), queue: AsyncImageView.loadQueue) { [weak self] _, data, _ in
            guard let data = data, let raw = UIImage(data: data) else {
                OperationQueue.main.addOperation { completion?() }
                return
            }
            // Force-decode the compressed image data on the background thread
            // so the main thread never has to decompress it during render.
            let decoded = AsyncImageView.forceDecoded(raw)
            // Cost is the decoded footprint, not the compressed byte count: a photo
            // library's JPEGs are ~10x larger in memory than on the wire, and costing
            // them by data.count lets the cache hold far more than totalCostLimit.
            AsyncImageView.cache.setObject(decoded, forKey: capturedURL as NSString,
                                           cost: AsyncImageView.decodedBytes(decoded))
            OperationQueue.main.addOperation { [weak self] in
                guard let self = self, self.loadingURL == capturedURL else { return }
                self.image = decoded
                completion?()
            }
        }
    }

    private static func decodedBytes(_ image: UIImage) -> Int {
        return Int(image.size.width * image.scale * image.size.height * image.scale * 4)
    }

    private static func forceDecoded(_ image: UIImage) -> UIImage {
        UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
        image.draw(at: .zero)
        let result = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()
        return result
    }

    func cancel() { loadingURL = nil }
}
