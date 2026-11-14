import UIKit

// MARK: - ItemRouter
//
// What tapping an item opens, in one place, so Home's rows and the library pages
// (ItemListVC) can't drift apart. `list` is the page or row the item was tapped in:
// a photo swipes through the Photo items in it, and a track queues its Audio items.
//
// Every item type is listed explicitly; anything unlisted (Movie, Episode, Video,
// MusicVideo, ...) opens the detail page.

enum ItemRouter {

    static func open(_ list: [MediaItem], at index: Int, from nav: UINavigationController?) {
        guard let nav = nav, index >= 0, index < list.count else { return }
        let item = list[index]
        switch item.type {
        case "Series":
            nav.pushViewController(SeasonListVC(series: item), animated: true)
        case "Folder", "CollectionFolder", "PhotoAlbum":
            // Drill into generic folders (e.g. custom TV content not parsed as Series,
            // or a dated subfolder inside a home videos & photos library)
            browse(item, as: "folder", nav: nav)
        case "Photo":
            showPhoto(list, at: index, nav: nav)
        case "MusicArtist":
            browse(item, as: "musicArtist", nav: nav)
        case "MusicAlbum":
            browse(item, as: "musicAlbum", nav: nav)
        case "Playlist":
            browse(item, as: "playlistContent", nav: nav)
        case "Audio":
            playAudio(list, at: index, from: nav)
        default:
            nav.pushViewController(ItemDetailVC(item: item), animated: true)
        }
    }

    // Queues every Audio item in `list` (a playlist can hold videos too, so the queue
    // is built from an Audio-only projection and the tapped row is remapped into it)
    // and starts at the tapped track.
    static func playAudio(_ list: [MediaItem], at index: Int, from nav: UINavigationController?) {
        var audioItems: [MediaItem] = []
        var start = 0
        for i in 0..<list.count where list[i].type == "Audio" {
            if i == index { start = audioItems.count }
            audioItems.append(list[i])
        }
        guard !audioItems.isEmpty else { return }
        AudioQueue.shared.play(items: audioItems, startAt: start)
        nav?.pushViewController(NowPlayingVC(), animated: true)
    }

    // A home videos folder mixes photos and videos, so the viewer swipes through a
    // Photo-only projection of `list` with the tapped row remapped into it.
    private static func showPhoto(_ list: [MediaItem], at index: Int, nav: UINavigationController) {
        var photos: [MediaItem] = []
        var start = 0
        for i in 0..<list.count where list[i].type == "Photo" {
            if i == index { start = photos.count }
            photos.append(list[i])
        }
        guard !photos.isEmpty else { return }
        nav.pushViewController(PhotoVC(items: photos, startAt: start), animated: true)
    }

    private static func browse(_ item: MediaItem, as collectionType: String, nav: UINavigationController) {
        let child = Library(id: item.id, name: item.name, collectionType: collectionType)
        nav.pushViewController(ItemListVC(library: child), animated: true)
    }
}
