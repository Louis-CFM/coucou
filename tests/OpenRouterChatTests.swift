import Foundation

@main
struct OpenRouterChatTests {
    static func main() throws {
        func model(_ id: String, _ pricing: [String: Any] = ["prompt": "0", "completion": "0"], outputs: [String] = ["text"]) -> [String: Any] {
            ["id": id, "name": id, "pricing": pricing,
             "architecture": ["input_modalities": ["text"], "output_modalities": outputs]]
        }
        let items = [
            model("z/free"), model("a/free:free"), model("openrouter/free"), model("z/free"),
            model("paid", ["prompt": "0.001", "completion": "0"]),
            model("misleading:free", ["prompt": "0", "completion": "0.001"]),
            model("request-charge", ["prompt": "0", "completion": "0", "request": "0.01"]),
            model("dynamic", ["prompt": "-1", "completion": "0"]),
            model("missing", ["prompt": "0"]),
            model("invalid", ["prompt": "0garbage", "completion": "0"]),
            model("nan", ["prompt": "NaN", "completion": "0"]),
            model("numeric", ["prompt": 0, "completion": 0]),
            model("image-only", outputs: ["image"])
        ]
        let data = try JSONSerialization.data(withJSONObject: ["data": items])
        let models = try OpenRouterChat.parseModels(data)
        precondition(models.map(\.id) == ["openrouter/free", "a/free:free", "z/free"])
        precondition(models[0].label == "Auto — Free")
        precondition(tryEmpty())
        do {
            _ = try OpenRouterChat.parseModels(Data("{}".utf8))
            fatalError("Malformed catalogue accepted")
        } catch OpenRouterChat.Failure.invalidCatalogue { }
        let url = URL(string: "https://openrouter.ai/api/v1/models")!
        for code in [200, 401, 403, 429, 500] {
            let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
            do {
                try OpenRouterChat.checkResponse(response)
                precondition(code == 200)
            } catch let failure as OpenRouterChat.Failure {
                switch (code, failure) {
                case (401, .unauthorized), (403, .unauthorized), (429, .rateLimited), (500, .http(500)): break
                default: fatalError("Wrong HTTP classification")
                }
            }
        }
        let caps = OpenRouterChat.freeProviderPreferences["max_price"] as! [String: Int]
        precondition(caps == ["prompt": 0, "completion": 0, "request": 0])
        print("OpenRouter catalogue, free pricing guards and HTTP error tests passed")
    }

    static func tryEmpty() -> Bool {
        (try? OpenRouterChat.parseModels(Data(#"{"data":[]}"#.utf8)).isEmpty) == true
    }
}
