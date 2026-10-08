//
//  CachedAsyncImage.swift
//  IPTV Client
//
//  A caching, downsampling replacement for SwiftUI's built-in AsyncImage.
//
//  SwiftUI's AsyncImage caches nothing: every time a grid cell scrolls off
//  and back on screen it re-downloads and re-decodes the full-resolution logo
//  from the network. Across a channel grid of hundreds of items this pegs the
//  CPU (brutal on the Apple TV HD's A8) and hangs scrolling. This component
//  instead keeps decoded, downsampled images in a shared in-memory cache and
//  never re-fetches a logo it has already loaded.
//

import SwiftUI
import ImageIO
import UIKit

/// Shared in-memory store of decoded, downsampled logos keyed by URL + target
/// pixel size. NSCache is thread-safe and evicts under memory pressure.
final class ChannelImageCache: @unchecked Sendable {
    static let shared = ChannelImageCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 600
    }

    static func key(url: URL, maxPixelSize: CGFloat) -> String {
        "\(url.absoluteString)|\(Int(maxPixelSize))"
    }

    func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func insert(_ image: UIImage, forKey key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
}

/// Serializes network loads so that many cells requesting the same logo at
/// once share a single download+decode instead of stampeding.
actor ChannelImageLoader {
    static let shared = ChannelImageLoader()

    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    func load(url: URL, maxPixelSize: CGFloat) async -> UIImage? {
        let key = ChannelImageCache.key(url: url, maxPixelSize: maxPixelSize)

        if let cached = ChannelImageCache.shared.image(forKey: key) {
            return cached
        }

        if let existing = inFlight[key] {
            return await existing.value
        }

        let task = Task<UIImage?, Never> {
            let image = await Self.fetchAndDownsample(url: url, maxPixelSize: maxPixelSize)
            if let image {
                ChannelImageCache.shared.insert(image, forKey: key)
            }
            return image
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    /// Warms the cache for a set of URLs with bounded concurrency, so a screen
    /// of logos can be loaded up front without stampeding the network.
    func prefetch(urls: [URL], maxPixelSize: CGFloat, maxConcurrent: Int = 6) async {
        var iterator = urls.makeIterator()
        await withTaskGroup(of: Void.self) { group in
            var inFlight = 0
            func addNext() {
                guard let url = iterator.next() else { return }
                inFlight += 1
                group.addTask { _ = await self.load(url: url, maxPixelSize: maxPixelSize) }
            }
            for _ in 0..<max(1, maxConcurrent) { addNext() }
            while inFlight > 0 {
                await group.next()
                inFlight -= 1
                addNext()
            }
        }
    }

    private static func fetchAndDownsample(url: URL, maxPixelSize: CGFloat) async -> UIImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else {
            return nil
        }
        // Decoding/downsampling is CPU-heavy; keep it off the main actor.
        return await Task.detached(priority: .utility) {
            downsample(data: data, maxPixelSize: maxPixelSize)
        }.value
    }

    private static func downsample(data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }

        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 1)
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

/// Drop-in replacement for AsyncImage that resolves cache hits synchronously
/// (so a logo reappearing on scroll paints instantly with no flicker) and
/// only touches the network on a genuine cache miss.
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    private let url: URL?
    private let maxPixelSize: CGFloat
    private let content: (Image) -> Content
    private let placeholder: () -> Placeholder

    @State private var loadedImage: UIImage?

    init(
        url: URL?,
        maxPixelSize: CGFloat,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.maxPixelSize = maxPixelSize
        self.content = content
        self.placeholder = placeholder

        // Paint cached logos on the very first frame, with no async gap.
        if let url {
            let key = ChannelImageCache.key(url: url, maxPixelSize: maxPixelSize)
            _loadedImage = State(initialValue: ChannelImageCache.shared.image(forKey: key))
        }
    }

    var body: some View {
        Group {
            if let loadedImage {
                content(Image(uiImage: loadedImage))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else {
                loadedImage = nil
                return
            }

            // Re-resolve for the current URL (this view may have been reused
            // by LazyVGrid for a different channel).
            let key = ChannelImageCache.key(url: url, maxPixelSize: maxPixelSize)
            if let cached = ChannelImageCache.shared.image(forKey: key) {
                loadedImage = cached
                return
            }

            loadedImage = nil
            let image = await ChannelImageLoader.shared.load(url: url, maxPixelSize: maxPixelSize)
            guard !Task.isCancelled else { return }
            loadedImage = image
        }
    }
}
