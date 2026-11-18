import Foundation
import Testing
@testable import CameraCore

private actor MemoryReportBackend: ACTAReportExportBackend {
    var selection: ACTAReportExportSelection
    var written: ACTAReportExportSelection?
    var selections = 0
    var verificationOK = true
    var failPublication = false
    var cancelSelection = false
    var verificationCount = 0
    var failAfterFirstVerification = false

    init(selection: ACTAReportExportSelection) { self.selection = selection }

    func selectReportAndDestination() async throws -> ACTAReportExportSelection {
        selections += 1
        if cancelSelection { throw CancellationError() }
        return selection
    }

    func publish(_ selection: ACTAReportExportSelection) async throws {
        if failPublication { throw Failure() }
        written = selection
    }

    func verify(_ selection: ACTAReportExportSelection) async throws -> Bool {
        verificationCount += 1
        return verificationOK && (!failAfterFirstVerification || verificationCount == 1)
            && written?.token == selection.token && written?.html == selection.html
    }

    func setSelection(_ selection: ACTAReportExportSelection) { self.selection = selection }
    func setVerificationOK(_ value: Bool) { verificationOK = value }
    func setFailPublication() { failPublication = true }
    func setCancelSelection() { cancelSelection = true }
    func setFailAfterFirstVerification() { failAfterFirstVerification = true }
    struct Failure: Error {}
}

struct ACTAReportExportActionTests {
    private func selection(html: Data = Data("<html>synthetic</html>".utf8),
                           destination: String = "/operator-selected/report.html") -> ACTAReportExportSelection {
        ACTAReportExportSelection(token: UUID(), reportKind: "mission", destination: destination,
                                  directoryDevice: 12, directoryInode: 34, fileName: "report.html", html: html)
    }

    @Test func brokerReviewsOperatorSelectionAndPublishesFrozenBytes() async throws {
        let original = selection()
        let backend = MemoryReportBackend(selection: original)
        let action = ACTAReportExportAction(backend: backend)
        let host = try #require(await ACTALocalActionBroker.make(
            actions: [action], allowedActionIDs: [action.id], audit: { _ in }))
        let session = try #require(await host.broker.openSession(
            operatorKey: host.operatorKey, input: .chat, threadID: "report", actionIDs: [action.id]))

        let injected = await host.broker.request(session: session, actionID: action.id,
                                                  argumentsJSON: #"{"destination":"/model.html"}"#)
        #expect(!injected.success && !injected.requiresOperatorConfirmation)
        #expect(await backend.selections == 0)
        let pending = await host.broker.request(session: session, actionID: action.id, argumentsJSON: "{}")
        #expect(pending.requiresOperatorConfirmation)
        #expect(!pending.summary.contains(original.destination))
        #expect(!pending.outputJSON.contains(original.destination))
        let review = try #require(await host.broker.reviews(operatorKey: host.operatorKey, session: session).first)
        #expect(review.parameters.isEmpty)
        #expect(review.title.contains(original.destination))
        #expect(review.title.contains("directory_device=12, directory_inode=34"))
        #expect(review.title.contains("sha256=5be8790e8abd97a38ff67eefebc2bc3321a1d72d60d8139aa4c27a28284f2d03"))
        #expect(review.title.contains("no overwrite"))
        await backend.setSelection(selection(html: Data("changed".utf8), destination: "/other/report.html"))
        let result = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                                reviewed: review, approved: true)
        #expect(result.success && result.verified)
        let written = try #require(await backend.written)
        #expect(written.token == original.token && written.html == original.html)
        #expect(written.destination == original.destination)
        let replay = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                                reviewed: review, approved: true)
        #expect(!replay.success)
    }

    @Test func rejectionInvalidSelectionAndFailedVerificationDoNotClaimSuccess() async throws {
        let backend = MemoryReportBackend(selection: selection())
        let action = ACTAReportExportAction(backend: backend)
        let host = try #require(await ACTALocalActionBroker.make(
            actions: [action], allowedActionIDs: [action.id], audit: { _ in }))
        let session = try #require(await host.broker.openSession(
            operatorKey: host.operatorKey, input: .voice, threadID: "report", actionIDs: [action.id]))
        let pending = await host.broker.request(session: session, actionID: action.id, argumentsJSON: "{}")
        #expect(pending.requiresOperatorConfirmation)
        let review = try #require(await host.broker.reviews(operatorKey: host.operatorKey, session: session).first)
        let rejected = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                                  reviewed: review, approved: false)
        #expect(!rejected.success)
        #expect(await backend.written == nil)

        await backend.setSelection(selection(html: Data([0xff])))
        let invalid = await host.broker.request(session: session, actionID: action.id, argumentsJSON: "{}")
        #expect(!invalid.requiresOperatorConfirmation && !invalid.success)
        await backend.setSelection(selection())
        await backend.setVerificationOK(false)
        let another = await host.broker.request(session: session, actionID: action.id, argumentsJSON: "{}")
        #expect(another.requiresOperatorConfirmation)
        let second = try #require(await host.broker.reviews(operatorKey: host.operatorKey, session: session).first)
        let result = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                                reviewed: second, approved: true)
        #expect(!result.success && !result.verified)
        #expect(result.error?.hasPrefix("VERIFICATION_FAILED:") == true)
    }

    @Test func backendFailureIsReportedAsPotentiallyIncomplete() async throws {
        let backend = MemoryReportBackend(selection: selection())
        await backend.setFailPublication()
        let action = ACTAReportExportAction(backend: backend)
        let context = ACTAActionContext(threadID: "test")
        let prepared = try await action.prepareConfirmation(parameters: [:], context: context)
        let result = try await action.executeConfirmed(
            parameters: [:], context: ACTAActionContext(threadID: "test", isConfirmed: true),
            snapshot: prepared.snapshot)
        #expect(!result.success && !result.verified)
        #expect(result.error?.contains("may be incomplete") == true)
    }

    @Test func cancelledSelectionAndFailedReadbackFailClosed() async throws {
        let backend = MemoryReportBackend(selection: selection())
        let action = ACTAReportExportAction(backend: backend)
        let host = try #require(await ACTALocalActionBroker.make(
            actions: [action], allowedActionIDs: [action.id], audit: { _ in }))
        let session = try #require(await host.broker.openSession(
            operatorKey: host.operatorKey, input: .chat, threadID: "report", actionIDs: [action.id]))
        await backend.setCancelSelection()
        let cancelled = await host.broker.request(session: session, actionID: action.id, argumentsJSON: "{}")
        #expect(!cancelled.success && !cancelled.requiresOperatorConfirmation)
        #expect(await backend.written == nil)

        let otherBackend = MemoryReportBackend(selection: selection())
        await otherBackend.setFailAfterFirstVerification()
        let otherAction = ACTAReportExportAction(backend: otherBackend)
        let otherHost = try #require(await ACTALocalActionBroker.make(
            actions: [otherAction], allowedActionIDs: [otherAction.id], audit: { _ in }))
        let otherSession = try #require(await otherHost.broker.openSession(
            operatorKey: otherHost.operatorKey, input: .chat, threadID: "report", actionIDs: [otherAction.id]))
        let pending = await otherHost.broker.request(session: otherSession, actionID: otherAction.id, argumentsJSON: "{}")
        #expect(pending.requiresOperatorConfirmation)
        let review = try #require(await otherHost.broker.reviews(
            operatorKey: otherHost.operatorKey, session: otherSession).first)
        let result = await otherHost.broker.resolve(operatorKey: otherHost.operatorKey, session: otherSession,
                                                     reviewed: review, approved: true)
        #expect(!result.success && !result.verified)
        #expect(await otherBackend.written != nil)
    }
}
