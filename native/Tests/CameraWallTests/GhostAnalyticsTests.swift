import CameraCore
@testable import CameraWall
import CoreGraphics
import Foundation
import XCTest

final class GhostAnalyticsTests: XCTestCase {

    private func makeTestImage(width: Int = 64, height: Int = 96, r: UInt8 = 210, g: UInt8 = 45, b: UInt8 = 50) -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width + x) * 4
                // Add slight gradient/edges so Laplacian variance is non-zero
                let edgeBoost: UInt8 = ((x + y) % 5 == 0) ? 35 : 0
                pixels[idx] = r &+ edgeBoost
                pixels[idx + 1] = g
                pixels[idx + 2] = b
                pixels[idx + 3] = 255
            }
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }

    func testCaptureSchedulerAndIdSwitchInheritance() {
        let scheduler = GhostCaptureScheduler()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let box0 = NormalizedRect(x: 0.10, y: 0.10, width: 0.10, height: 0.20)

        // 1. First appearance -> immediate capture
        let r1 = scheduler.shouldCapture(
            trackKey: "T1",
            cameraID: "CAM-A",
            label: "person",
            normalizedRect: box0,
            timestamp: t0
        )
        XCTAssertEqual(r1, .firstAppearance)

        // 2. At t0 + 0.4s -> nil (waiting for 1.0s bootstrap)
        let r2 = scheduler.shouldCapture(
            trackKey: "T1",
            cameraID: "CAM-A",
            label: "person",
            normalizedRect: box0,
            timestamp: t0.addingTimeInterval(0.4)
        )
        XCTAssertNil(r2)

        // 3. At t0 + 1.1s -> second bootstrap capture
        let r3 = scheduler.shouldCapture(
            trackKey: "T1",
            cameraID: "CAM-A",
            label: "person",
            normalizedRect: box0,
            timestamp: t0.addingTimeInterval(1.1)
        )
        XCTAssertEqual(r3, .bootstrapSecond)

        // 4. Tracker ID switch ("T2") at t0 + 1.5s in same spot (IoU = 1.0 >= 0.50) inherits state and suppresses duplicate firstAppearance
        let rSwitch = scheduler.shouldCapture(
            trackKey: "T2",
            cameraID: "CAM-A",
            label: "person",
            normalizedRect: box0,
            timestamp: t0.addingTimeInterval(1.5)
        )
        XCTAssertNil(rSwitch)

        // 5. Significant movement (>= 0.35 * diag) after 4.0s triggers .movement
        let movedBox = NormalizedRect(x: 0.50, y: 0.50, width: 0.10, height: 0.20)
        let rMove = scheduler.shouldCapture(
            trackKey: "T2",
            cameraID: "CAM-A",
            label: "person",
            normalizedRect: movedBox,
            timestamp: t0.addingTimeInterval(5.5)
        )
        XCTAssertEqual(rMove, .movement)
    }

    func testCropQualityAndChromaPrint() {
        let imgRed = makeTestImage(width: 80, height: 120, r: 215, g: 30, b: 35)
        let imgBlue = makeTestImage(width: 80, height: 120, r: 25, g: 55, b: 220)
        let mask = [Float](repeating: 0.95, count: 80 * 120)

        let q = GhostCropQualityScorer.score(
            cgImage: imgRed,
            alphaMask: mask,
            confidence: 0.90,
            normalizedBox: NormalizedRect(x: 0.2, y: 0.2, width: 0.15, height: 0.30)
        )
        XCTAssertGreaterThan(q.totalScore, 0.55)
        XCTAssertTrue(q.hasValidMask)

        let cRed1 = GhostChromaPrint.compute(from: imgRed, alphaMask: mask, isVehicle: false)
        let cRed2 = GhostChromaPrint.compute(from: imgRed, alphaMask: mask, isVehicle: false)
        let cBlue = GhostChromaPrint.compute(from: imgBlue, alphaMask: mask, isVehicle: false)

        XCTAssertNotNil(cRed1)
        XCTAssertNotNil(cBlue)
        XCTAssertEqual(cRed1?.blob.count, GhostChromaPrint.descriptorDimension)
        XCTAssertEqual(cRed1?.code, cRed2?.code)
        XCTAssertGreaterThan(cRed1!.cosineSimilarity(to: cRed2!), 0.99)
        XCTAssertLessThan(cRed1!.cosineSimilarity(to: cBlue!), 0.85)
    }

    func testMultiCueIdentityResolverAndChromaRescueGuard() {
        let resolver = GhostIdentityResolver()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        var emb1 = [Float](repeating: 0, count: 512)
        emb1[0] = 1.0

        let imgRed = makeTestImage(r: 215, g: 30, b: 35)
        let chromaRed = GhostChromaPrint.compute(from: imgRed)

        let obs1 = GhostMultiCueCandidateObservation(
            trackKey: "TRK-1",
            cameraID: "CAM-1",
            kind: "person",
            embedding: emb1,
            cropQuality: 0.85,
            chromaPrint: chromaRed,
            observedAt: t0
        )
        let d1 = resolver.resolve(observation: obs1)
        XCTAssertTrue(d1.createdNewIdentity)
        XCTAssertEqual(d1.state, .single)

        // Second observation on CAM-2 10 seconds later with identical embedding + chroma -> .confirmed
        let obs2 = GhostMultiCueCandidateObservation(
            trackKey: "TRK-2",
            cameraID: "CAM-2",
            kind: "person",
            embedding: emb1,
            cropQuality: 0.88,
            chromaPrint: chromaRed,
            observedAt: t0.addingTimeInterval(10)
        )
        let d2 = resolver.resolve(observation: obs2)
        XCTAssertFalse(d2.createdNewIdentity)
        XCTAssertEqual(d2.identityID, d1.identityID)
        XCTAssertEqual(d2.state, .confirmed)

        // Impossible simultaneous veto: observation on CAM-3 at exact same timestamp t0 -> cannot match d1
        let obsSimultaneous = GhostMultiCueCandidateObservation(
            trackKey: "TRK-SIM",
            cameraID: "CAM-3",
            kind: "person",
            embedding: emb1,
            cropQuality: 0.85,
            chromaPrint: chromaRed,
            observedAt: t0
        )
        let dSim = resolver.resolve(observation: obsSimultaneous)
        XCTAssertNotEqual(dSim.identityID, d1.identityID)
        XCTAssertTrue(dSim.createdNewIdentity)
    }

    func testWeightedSexResolutionAndImpuritySplitter() {
        // Secondary cue alone (beard) without direct sex or gendered noun -> .unknown
        let secondaryOnly = GhostSexResolver.resolve(observations: [
            GhostSexObservationInput(trackKey: "T1", facialHair: "beard", cropQuality: 0.85)
        ])
        XCTAssertEqual(secondaryOnly.sex, .unknown)

        // Direct multilingual cues -> resolved
        let maleRes = GhostSexResolver.resolve(observations: [
            GhostSexObservationInput(trackKey: "T1", apparentSex: "male", descriptionText: "Мужчина в черной куртке", cropQuality: 0.85)
        ])
        XCTAssertEqual(maleRes.sex, .male)
        XCTAssertGreaterThan(maleRes.confidence, 0.70)

        // Impurity split when an identity has both male and female tracks
        let split = GhostIdentityPuritySplitter.evaluateIdentity(
            identityID: "ID-MIXED",
            trackObservations: [
                "TRK-M1": [GhostSexObservationInput(trackKey: "TRK-M1", apparentSex: "male", cropQuality: 0.90)],
                "TRK-M2": [GhostSexObservationInput(trackKey: "TRK-M2", apparentSex: "male", cropQuality: 0.85)],
                "TRK-F1": [GhostSexObservationInput(trackKey: "TRK-F1", apparentSex: "female", cropQuality: 0.88)]
            ]
        )
        XCTAssertNotNil(split)
        XCTAssertEqual(split?.majoritySex, .male)
        XCTAssertEqual(split?.minoritySex, .female)
        XCTAssertEqual(split?.movedTrackKeys, ["TRK-F1"])
    }

    func testCollageBuilderAndOpSecAndDryRunCoordinator() async throws {
        let img = makeTestImage(width: 96, height: 128, r: 120, g: 160, b: 90)
        let cells = [
            GhostCollageCell(badgeIndex: 1, itemID: "1", cgImage: img, caption: "P-001"),
            GhostCollageCell(badgeIndex: 2, itemID: "2", cgImage: img, caption: "P-002")
        ]
        let collage = GhostCollageBuilder.buildCollage(kind: .describe, cells: cells)
        XCTAssertNotNil(collage)
        XCTAssertFalse(collage!.jpegData.isEmpty)

        let sanitized = GhostOpSec.sanitizeText("As an AI, OpenAI gpt-5.4-mini and Qwen2.5-VL with YOLOv8 detected a man.")
        XCTAssertFalse(sanitized.lowercased().contains("openai"))
        XCTAssertFalse(sanitized.lowercased().contains("qwen"))
        XCTAssertFalse(sanitized.lowercased().contains("yolo"))

        let client = GhostAIClient(config: GhostAIConfiguration(mode: .dryRun, preferredLanguage: .ru))
        let coordinator = GhostAnalyticsCoordinator(aiClient: client)
        let reply = await coordinator.askGhostChatAgent(question: "Где сейчас мужчина в черной куртке?")
        XCTAssertFalse(reply.answerMarkdown.isEmpty)
    }
}

