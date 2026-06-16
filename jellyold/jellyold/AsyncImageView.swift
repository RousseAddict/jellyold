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

    func load(url: String) {
        if let cached = AsyncImageView.cache.object(forKey: url as NSString) {
            image = cached
            return
        }
        loadingURL = url
        image = nil
        guard let nsurl = URL(string: url) else { return }
        let capturedURL = url
        NSURLConnection.sendAsynchronousRequest(URLRequest(url: nsurl), queue: AsyncImageView.loadQueue) { [weak self] _, data, _ in
            guard let data = data, let raw = UIImage(data: data) else { return }
            // Force-decode the compressed image data on the background thread
            // so the main thread never has to decompress it during render.
            let decoded = AsyncImageView.forceDecoded(raw)
            AsyncImageView.cache.setObject(decoded, forKey: capturedURL as NSString, cost: data.count)
            OperationQueue.main.addOperation { [weak self] in
                guard let self = self, self.loadingURL == capturedURL else { return }
                self.image = decoded
            }
        }
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
