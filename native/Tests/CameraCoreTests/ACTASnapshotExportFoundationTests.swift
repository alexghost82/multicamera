import Darwin
import Foundation
import Testing

@testable import CameraCore

private final class SnapshotClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 100
    func now() -> TimeInterval { lock.withLock { time } }
    func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
}

private final class SnapshotTestDirectory {
    let url: URL
    init() throws {
        url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".snapshot-export-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

struct ACTASnapshotExportFoundationTests {
    private let jpeg = Data([0xff, 0xd8, 1, 2, 0xff, 0xd9])
    private let camera = UUID()

    @Test func approvalBindsExactFrameAndDestinationAndIsSingleUse() async throws {
        let service = ACTASnapshotExportFoundation()
        var mutableFrame = jpeg
        let request = try await service.prepare(
            cameraID: camera, jpeg: mutableFrame,
            destinationPath: "/exports/frame.jpg")
        mutableFrame[2] = 9
        let approved = try await service.resolve(token: request.token, reviewed: request.preview, approved: true)
        #expect(approved.jpeg == jpeg)
        #expect(approved.preview.cameraID == camera)
        #expect(approved.preview.destinationPath == "/exports/frame.jpg")
        #expect(approved.preview.byteCount == jpeg.count)
        #expect(approved.preview.sha256 == "c1c2b34cac7879f01428e2157695950295b52352e37dfacee95c14bb44ab4578")
        await #expect(throws: ACTASnapshotExportFoundation.Failure.invalidOrExpiredConfirmation) {
            try await service.resolve(token: request.token, reviewed: request.preview, approved: true)
        }
    }

    @Test func mismatchedOrDeclinedApprovalCannotBeReused() async throws {
        let service = ACTASnapshotExportFoundation()
        let first = try await service.prepare(cameraID: camera, jpeg: jpeg, destinationPath: "/exports/a.jpg")
        let otherDestination = try await service.prepare(
            cameraID: camera, jpeg: jpeg, destinationPath: "/exports/b.jpg")
        let otherCamera = try await service.prepare(cameraID: UUID(), jpeg: jpeg, destinationPath: "/exports/a.jpg")
        let otherFrame = try await service.prepare(
            cameraID: camera, jpeg: Data([0xff, 0xd8, 7, 0xff, 0xd9]),
            destinationPath: "/exports/a.jpg")
        for other in [otherDestination, otherCamera, otherFrame] {
            await #expect(throws: ACTASnapshotExportFoundation.Failure.confirmationMismatch) {
                try await service.resolve(token: other.token, reviewed: first.preview, approved: true)
            }
            await #expect(throws: ACTASnapshotExportFoundation.Failure.invalidOrExpiredConfirmation) {
                try await service.resolve(token: other.token, reviewed: other.preview, approved: true)
            }
        }
        await #expect(throws: ACTASnapshotExportFoundation.Failure.declined) {
            try await service.resolve(token: first.token, reviewed: first.preview, approved: false)
        }
        await #expect(throws: ACTASnapshotExportFoundation.Failure.invalidOrExpiredConfirmation) {
            try await service.resolve(token: first.token, reviewed: first.preview, approved: true)
        }
    }

    @Test func externalBackingAndConcurrentApprovalsCannotChangeTheCapturedFrame() async throws {
        let service = ACTASnapshotExportFoundation()
        let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: jpeg.count)
        defer { storage.deallocate() }
        jpeg.copyBytes(to: storage, count: jpeg.count)
        let aliased = Data(bytesNoCopy: storage, count: jpeg.count, deallocator: .none)
        let request = try await service.prepare(cameraID: camera, jpeg: aliased, destinationPath: "/exports/a.jpg")
        storage[2] = 9
        let results = await withTaskGroup(of: Data?.self, returning: [Data].self) { group in
            for _ in 0..<2 {
                group.addTask {
                    try? await service.resolve(token: request.token, reviewed: request.preview, approved: true).jpeg
                }
            }
            var successes: [Data] = []
            for await result in group {
                if let result { successes.append(result) }
            }
            return successes
        }
        #expect(results == [jpeg])
    }

    @Test func expiryCapacityAndCancellationAreBounded() async throws {
        let clock = SnapshotClock()
        let service = ACTASnapshotExportFoundation(now: { clock.now() })
        let requests = try await (0..<4).asyncMap { _ in
            try await service.prepare(cameraID: camera, jpeg: jpeg, destinationPath: "/exports/a.jpg")
        }
        await #expect(throws: ACTASnapshotExportFoundation.Failure.capacityExceeded) {
            try await service.prepare(cameraID: camera, jpeg: jpeg, destinationPath: "/exports/a.jpg")
        }
        await service.cancel(token: requests[0].token)
        let replacement = try await service.prepare(cameraID: camera, jpeg: jpeg, destinationPath: "/exports/a.jpg")
        clock.advance(300)
        await #expect(throws: ACTASnapshotExportFoundation.Failure.invalidOrExpiredConfirmation) {
            try await service.resolve(token: replacement.token, reviewed: replacement.preview, approved: true)
        }
        _ = try await service.prepare(cameraID: camera, jpeg: jpeg, destinationPath: "/exports/a.jpg")
    }

    @Test func rejectsUnboundedFramesAndAmbiguousDestinations() async throws {
        let service = ACTASnapshotExportFoundation()
        for data in [Data(), Data([0xff, 0xd8, 0, 0]), Data(repeating: 0, count: 8 * 1024 * 1024 + 1)] {
            await #expect(throws: ACTASnapshotExportFoundation.Failure.invalidSnapshot) {
                try await service.prepare(cameraID: camera, jpeg: data, destinationPath: "/exports/a.jpg")
            }
        }
        for path in [
            "relative/a.jpg", "/exports/../a.jpg", "/exports//a.jpg", "/exports/./a.jpg",
            "/exports/a.png", "/exports/a\n.jpg", "/exports/é.jpg", "/exports/a\\.jpg",
            "/" + String(repeating: "a", count: 1024) + ".jpg",
        ] {
            await #expect(throws: ACTASnapshotExportFoundation.Failure.invalidDestination) {
                try await service.prepare(cameraID: camera, jpeg: jpeg, destinationPath: path)
            }
        }
    }

    @Test func publicationWritesOnlyConfirmedBytesAndVerifiesIdentity() async throws {
        let directory = try SnapshotTestDirectory()
        let path = directory.url.appendingPathComponent("frame.jpg").path
        let service = ACTASnapshotExportFoundation()
        let request = try await service.prepareForPublication(cameraID: camera, jpeg: jpeg, destinationPath: path)
        #expect(request.preview.directoryIdentity != nil)
        #expect(!FileManager.default.fileExists(atPath: path))
        let receipt = try await service.publish(token: request.token, reviewed: request.preview, approved: true)
        #expect(receipt.preview == request.preview)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == jpeg)
        var info = stat()
        #expect(lstat(path, &info) == 0)
        #expect(receipt.fileIdentity.inode == UInt64(info.st_ino))
        #expect(receipt.fileIdentity.device == UInt64(info.st_dev))
        #expect(info.st_mode & 0o777 == 0o600)
        await #expect(throws: ACTASnapshotExportFoundation.Failure.invalidOrExpiredConfirmation) {
            try await service.publish(token: request.token, reviewed: request.preview, approved: true)
        }
    }

    @Test func declinedAndExpiredPublicationNeverCreateAFile() async throws {
        let directory = try SnapshotTestDirectory()
        let path = directory.url.appendingPathComponent("frame.jpg").path
        let clock = SnapshotClock()
        let service = ACTASnapshotExportFoundation(now: { clock.now() })
        let denied = try await service.prepareForPublication(cameraID: camera, jpeg: jpeg, destinationPath: path)
        await #expect(throws: ACTASnapshotExportFoundation.Failure.declined) {
            try await service.publish(token: denied.token, reviewed: denied.preview, approved: false)
        }
        let expired = try await service.prepareForPublication(cameraID: camera, jpeg: jpeg, destinationPath: path)
        clock.advance(300)
        await #expect(throws: ACTASnapshotExportFoundation.Failure.invalidOrExpiredConfirmation) {
            try await service.publish(token: expired.token, reviewed: expired.preview, approved: true)
        }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func detectsDirectoryReplacementDuringPublicationWithoutWritingToReplacement() async throws {
        let root = try SnapshotTestDirectory()
        let directory = root.url.appendingPathComponent("destination", isDirectory: true)
        let moved = root.url.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let path = directory.appendingPathComponent("frame.jpg").path
        let service = ACTASnapshotExportFoundation(
            now: { 100 },
            beforeIdentityCheck: {
                _ = rename(directory.path, moved.path)
                _ = mkdir(directory.path, mode_t(0o700))
            })
        let request = try await service.prepareForPublication(cameraID: camera, jpeg: jpeg, destinationPath: path)
        await #expect(throws: ACTASnapshotExportFoundation.Failure.destinationChanged) {
            try await service.publish(token: request.token, reviewed: request.preview, approved: true)
        }
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try Data(contentsOf: moved.appendingPathComponent("frame.jpg")) == jpeg)
    }

    @Test func refusesExistingAndRacedDestinationsIncludingSymlinks() async throws {
        let directory = try SnapshotTestDirectory()
        let file = directory.url.appendingPathComponent("frame.jpg")
        let target = directory.url.appendingPathComponent("target.jpg")
        try Data([42]).write(to: target)
        let service = ACTASnapshotExportFoundation()
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        await #expect(throws: ACTASnapshotExportFoundation.Failure.destinationExists) {
            try await service.prepareForPublication(cameraID: camera, jpeg: jpeg, destinationPath: file.path)
        }
        try FileManager.default.removeItem(at: file)
        let request = try await service.prepareForPublication(cameraID: camera, jpeg: jpeg, destinationPath: file.path)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        await #expect(throws: ACTASnapshotExportFoundation.Failure.destinationExists) {
            try await service.publish(token: request.token, reviewed: request.preview, approved: true)
        }
        #expect(try Data(contentsOf: target) == Data([42]))
        let link = directory.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory.url)
        await #expect(throws: ACTASnapshotExportFoundation.Failure.destinationUnavailable) {
            try await service.prepareForPublication(
                cameraID: camera, jpeg: jpeg,
                destinationPath: link.appendingPathComponent("other.jpg").path)
        }
    }

    @Test func rejectsDirectoryReplacementAndMismatchedDirectoryReview() async throws {
        let root = try SnapshotTestDirectory()
        let directory = root.url.appendingPathComponent("destination", isDirectory: true)
        let moved = root.url.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let path = directory.appendingPathComponent("frame.jpg").path
        let service = ACTASnapshotExportFoundation()
        let first = try await service.prepareForPublication(cameraID: camera, jpeg: jpeg, destinationPath: path)
        try FileManager.default.moveItem(at: directory, to: moved)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let second = try await service.prepareForPublication(cameraID: camera, jpeg: jpeg, destinationPath: path)
        #expect(first.preview.directoryIdentity != second.preview.directoryIdentity)
        await #expect(throws: ACTASnapshotExportFoundation.Failure.confirmationMismatch) {
            try await service.publish(token: second.token, reviewed: first.preview, approved: true)
        }
        await #expect(throws: ACTASnapshotExportFoundation.Failure.destinationChanged) {
            try await service.publish(token: first.token, reviewed: first.preview, approved: true)
        }
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(!FileManager.default.fileExists(atPath: moved.appendingPathComponent("frame.jpg").path))
    }

    @Test func failsOnReadbackCorruptionOrNamedFileReplacement() async throws {
        let root = try SnapshotTestDirectory()
        let corrupt = root.url.appendingPathComponent("corrupt.jpg").path
        let corrupting = ACTASnapshotExportFoundation(
            now: { 100 },
            beforeReadback: { fd in
                var byte: UInt8 = 0
                _ = pwrite(fd, &byte, 1, 2)
            })
        let first = try await corrupting.prepareForPublication(cameraID: camera, jpeg: jpeg, destinationPath: corrupt)
        await #expect(throws: ACTASnapshotExportFoundation.Failure.verificationFailed) {
            try await corrupting.publish(token: first.token, reviewed: first.preview, approved: true)
        }
        let replaced = root.url.appendingPathComponent("replaced.jpg").path
        let replacing = ACTASnapshotExportFoundation(
            now: { 100 },
            beforeIdentityCheck: {
                _ = unlink(replaced)
                let fd = open(replaced, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
                if fd >= 0 { close(fd) }
            })
        let second = try await replacing.prepareForPublication(cameraID: camera, jpeg: jpeg, destinationPath: replaced)
        await #expect(throws: ACTASnapshotExportFoundation.Failure.verificationFailed) {
            try await replacing.publish(token: second.token, reviewed: second.preview, approved: true)
        }
    }
}

extension Sequence {
    fileprivate func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
