import Foundation
import Photos

// PhotoKit plumbing shared by `download` and `import`. The first call in a session
// triggers the one-time Photos permission prompt, attributed to the terminal app
// this binary runs from.

func requirePhotosAccess() async throws {
    // photolibraryd refuses XPC connections from processes without a bundle identity
    // (symptom: endless "NSCocoaErrorDomain Code=4097" CoreData retries and no
    // permission prompt), so refuse up front with the remedy.
    guard Bundle.main.bundleIdentifier != nil else {
        throw RescueError("""
        This binary has no bundle identity, and Photos' daemon will refuse it. Build and run \
        through the app wrapper instead:
          ./Scripts/build-app.sh
          ./SharedAlbumRescue.app/Contents/MacOS/shared-album-rescue <command>
        """)
    }
    let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    guard status == .authorized else {
        throw RescueError("""
        Photos access not granted (status \(status.rawValue)). Approve the “SharedAlbumRescue” \
        prompt, or add it under System Settings → Privacy & Security → Photos, then re-run.
        """)
    }
}

/// Maps asset UUIDs (ZASSET.ZUUID) to PHAssets across every cloud-shared album.
/// PHAsset.localIdentifier is "<UUID>/L0/001", so the prefix is the join key.
func fetchSharedAssetsByUUID() throws -> (assets: [String: PHAsset], collections: Int) {
    var byUUID: [String: PHAsset] = [:]
    var collectionCount = 0
    let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumCloudShared, options: nil)
    collections.enumerateObjects { collection, _, _ in
        collectionCount += 1
        let assets = PHAsset.fetchAssets(in: collection, options: nil)
        assets.enumerateObjects { asset, _, _ in
            let uuid = asset.localIdentifier.split(separator: "/").first.map(String.init) ?? asset.localIdentifier
            byUUID[uuid] = asset
        }
    }
    guard collectionCount > 0 else {
        throw RescueError("""
        PhotoKit returned zero cloud-shared albums. Check that Photos → Settings → iCloud has \
        “Shared Albums” enabled and that the Photos permission was granted to SharedAlbumRescue.
        """)
    }
    return (byUUID, collectionCount)
}

/// Downloads one resource of a shared asset to a local file, allowing network access
/// so Apple's servers hand over content that was never cached locally.
func writeResource(_ resource: PHAssetResource, to url: URL) async throws {
    if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let options = PHAssetResourceRequestOptions()
    options.isNetworkAccessAllowed = true
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }
}

/// Finds or creates a regular user album with the given title.
func ensureAlbum(named title: String) async throws -> PHAssetCollection {
    let fetchOptions = PHFetchOptions()
    fetchOptions.predicate = NSPredicate(format: "title = %@", title)
    let existing = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: fetchOptions)
    if let collection = existing.firstObject {
        return collection
    }
    var placeholderID: String?
    try await PHPhotoLibrary.shared().performChanges {
        let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
        placeholderID = request.placeholderForCreatedAssetCollection.localIdentifier
    }
    guard let placeholderID,
          let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [placeholderID], options: nil).firstObject
    else {
        throw RescueError("Could not create album “\(title)”")
    }
    return collection
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
