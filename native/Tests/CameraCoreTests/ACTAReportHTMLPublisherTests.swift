import Darwin
import Foundation
import XCTest
@testable import CameraCore

private final class ReportTestDirectory {
    let url: URL
    let fd: Int32

    init() throws {
        url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".report-publisher-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
        fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.EIO) }
    }

    deinit {
        close(fd)
        try? FileManager.default.removeItem(at: url)
    }
}

final class ACTAReportHTMLPublisherTests: XCTestCase {
    private let html = Data("<html>synthetic</html>".utf8)

    func testSnapshotBindsContentsAndDescriptorAndWritesPrivateFile() throws {
        let directory = try ReportTestDirectory()
        let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: html.count)
        defer { pointer.deallocate() }
        html.copyBytes(to: pointer, count: html.count)
        let alias = Data(bytesNoCopy: pointer, count: html.count, deallocator: .none)
        let prepared = try ACTAReportHTMLPublisher.prepare(
            html: alias, directoryFD: directory.fd, fileName: "report.html", operatorSelected: true)
        pointer[0] = 88
        let preview = prepared.review
        XCTAssertEqual(preview.byteCount, html.count)
        XCTAssertEqual(preview.sha256, "5be8790e8abd97a38ff67eefebc2bc3321a1d72d60d8139aa4c27a28284f2d03")
        let receipt = try prepared.publish(reviewed: preview, approved: true)
        let url = directory.url.appendingPathComponent("report.html")
        XCTAssertEqual(try Data(contentsOf: url), html)
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o7777, 0o600)
        XCTAssertEqual(receipt.file.inode, UInt64(info.st_ino))
        XCTAssertEqual(receipt.preview, preview)
        XCTAssertThrowsError(try prepared.publish(reviewed: preview, approved: true)) {
            XCTAssertEqual($0 as? ACTAReportHTMLPublisher.Failure, .alreadyConsumed)
        }
    }

    func testDeclineAndMismatchConsumeSnapshotWithoutCreatingFile() throws {
        let directory = try ReportTestDirectory()
        let first = try ACTAReportHTMLPublisher.prepare(html: html, directoryFD: directory.fd,
                                                        fileName: "a.html", operatorSelected: true)
        let second = try ACTAReportHTMLPublisher.prepare(html: Data("different".utf8), directoryFD: directory.fd,
                                                         fileName: "a.html", operatorSelected: true)
        XCTAssertThrowsError(try first.publish(reviewed: second.review, approved: true)) {
            XCTAssertEqual($0 as? ACTAReportHTMLPublisher.Failure, .confirmationMismatch)
        }
        XCTAssertThrowsError(try first.publish(reviewed: first.review, approved: true)) {
            XCTAssertEqual($0 as? ACTAReportHTMLPublisher.Failure, .alreadyConsumed)
        }
        XCTAssertThrowsError(try second.publish(reviewed: second.review, approved: false)) {
            XCTAssertEqual($0 as? ACTAReportHTMLPublisher.Failure, .declined)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.url.appendingPathComponent("a.html").path))
    }

    func testUntrustedDestinationAndInvalidContentFailClosed() throws {
        let directory = try ReportTestDirectory()
        for name in ["../bad.html", "/bad.html", "bad\\name.html", "bad\n.html", "bad.txt", "é.html"] {
            XCTAssertThrowsError(try ACTAReportHTMLPublisher.prepare(html: html, directoryFD: directory.fd,
                                                                    fileName: name, operatorSelected: true)) {
                XCTAssertEqual($0 as? ACTAReportHTMLPublisher.Failure, .untrustedDestination)
            }
        }
        XCTAssertThrowsError(try ACTAReportHTMLPublisher.prepare(html: html, directoryFD: directory.fd,
                                                                 fileName: "x.html", operatorSelected: false))
        XCTAssertThrowsError(try ACTAReportHTMLPublisher.prepare(html: html, directoryFD: -1,
                                                                 fileName: "x.html", operatorSelected: true))
        for invalid in [Data(), Data([0xff]), Data(repeating: 65, count: 8 * 1024 * 1024 + 1)] {
            XCTAssertThrowsError(try ACTAReportHTMLPublisher.prepare(html: invalid, directoryFD: directory.fd,
                                                                     fileName: "x.html", operatorSelected: true)) {
                XCTAssertEqual($0 as? ACTAReportHTMLPublisher.Failure, .invalidContent)
            }
        }
        XCTAssertEqual(fchmod(directory.fd, 0o755), 0)
        XCTAssertThrowsError(try ACTAReportHTMLPublisher.prepare(html: html, directoryFD: directory.fd,
                                                                 fileName: "x.html", operatorSelected: true)) {
            XCTAssertEqual($0 as? ACTAReportHTMLPublisher.Failure, .untrustedDestination)
        }
    }

    func testExistingFileAndRacedSymlinkAreNotModified() throws {
        let directory = try ReportTestDirectory()
        let target = directory.url.appendingPathComponent("target")
        let destination = directory.url.appendingPathComponent("report.html")
        let original = Data("foreign".utf8)
        try original.write(to: target)
        let first = try ACTAReportHTMLPublisher.prepare(html: html, directoryFD: directory.fd,
                                                        fileName: "report.html", operatorSelected: true)
        try original.write(to: destination)
        XCTAssertThrowsError(try first.publish(reviewed: first.review, approved: true)) {
            XCTAssertEqual($0 as? ACTAReportHTMLPublisher.Failure, .destinationExists)
        }
        XCTAssertEqual(try Data(contentsOf: destination), original)
        try FileManager.default.removeItem(at: destination)
        let second = try ACTAReportHTMLPublisher.prepare(html: html, directoryFD: directory.fd,
                                                         fileName: "report.html", operatorSelected: true)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
        XCTAssertThrowsError(try second.publish(reviewed: second.review, approved: true)) {
            XCTAssertEqual($0 as? ACTAReportHTMLPublisher.Failure, .destinationExists)
        }
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), target.path)
    }

    func testDetectedReplacementIsNotDeletedOrOverwritten() throws {
        let directory = try ReportTestDirectory()
        let destination = directory.url.appendingPathComponent("report.html")
        let moved = directory.url.appendingPathComponent("original.html")
        let foreign = Data("foreign".utf8)
        let prepared = try ACTAReportHTMLPublisher.prepare(
            html: html, directoryFD: directory.fd, fileName: "report.html", operatorSelected: true,
            beforeVerification: { _, fd in
                XCTAssertEqual(renameat(fd, "report.html", fd, "original.html"), 0)
                let replacement = openat(fd, "report.html", O_WRONLY | O_CREAT | O_EXCL, 0o600)
                XCTAssertGreaterThanOrEqual(replacement, 0)
                _ = foreign.withUnsafeBytes { write(replacement, $0.baseAddress, $0.count) }
                close(replacement)
            })
        XCTAssertThrowsError(try prepared.publish(reviewed: prepared.review, approved: true)) {
            XCTAssertEqual($0 as? ACTAReportHTMLPublisher.Failure, .verificationFailed)
        }
        XCTAssertEqual(try Data(contentsOf: destination), foreign)
        XCTAssertEqual(try Data(contentsOf: moved), html)
    }

    func testCorruptedBytesAndChangedDirectoryPermissionsFail() throws {
        let directory = try ReportTestDirectory()
        let changed = try ACTAReportHTMLPublisher.prepare(
            html: html, directoryFD: directory.fd, fileName: "changed.html", operatorSelected: true,
            beforeVerification: { file, _ in
                var byte: UInt8 = 0x58
                XCTAssertEqual(pwrite(file, &byte, 1, 0), 1)
            })
        XCTAssertThrowsError(try changed.publish(reviewed: changed.review, approved: true)) {
            XCTAssertEqual($0 as? ACTAReportHTMLPublisher.Failure, .verificationFailed)
        }
        let damaged = try Data(contentsOf: directory.url.appendingPathComponent("changed.html"))
        XCTAssertNotEqual(damaged, html)

        let untrusted = try ACTAReportHTMLPublisher.prepare(html: html, directoryFD: directory.fd,
                                                            fileName: "no.html", operatorSelected: true)
        XCTAssertEqual(fchmod(directory.fd, 0o755), 0)
        XCTAssertThrowsError(try untrusted.publish(reviewed: untrusted.review, approved: true)) {
            XCTAssertEqual($0 as? ACTAReportHTMLPublisher.Failure, .untrustedDestination)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.url.appendingPathComponent("no.html").path))
    }
}
