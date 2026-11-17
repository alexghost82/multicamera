@testable import CameraCore
@testable import CameraWall
import Foundation

let narrativeFakeTransport: ACTAHTTPTransport = { request in
    let result = ACTATemporalNarrativeResult(chapterTitle: "Test", summary: "Observed",
                                              atmosphere: "normal", events: [])
    let content = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
    let response = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
    return (response, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
}

func narrativeFakeClient(store: LocalTrackingStore?) -> ACTAAIClient {
    ACTAAIClient(config: ACTAAIConfiguration(mode: .localVLLM), cacheStore: store,
                 transport: narrativeFakeTransport)
}
