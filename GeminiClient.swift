import Foundation

struct FileInfo: Decodable {
    let name: String
    let state: String?
    let uri: String
}

struct FileAPIResponse: Decodable {
    let file: FileInfo
}

struct GenerateContentResponse: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable {
                let text: String
            }
            let parts: [Part]
        }
        let content: Content
    }
    let candidates: [Candidate]?
}

struct APIErrorResponse: Decodable {
    struct APIError: Decodable {
        let code: Int
        let message: String
        let status: String
    }
    let error: APIError
}

class GeminiClient {
    private let apiKey: String
    private let modelsToTry = ["gemini-3.5-flash", "gemini-3-flash", "gemini-2.5-flash"]
    
    init(apiKey: String) {
        self.apiKey = apiKey
    }
    
    func analyzeAudio(fileURL: URL, systemPrompt: String, onUpload: ((String) -> Void)? = nil) async throws -> String {
        // 1. Upload File
        print("[GeminiClient] Uploading \(fileURL.lastPathComponent) to Gemini File API...")
        let fileInfo = try await uploadFile(fileURL: fileURL)
        let fileResourceName = fileInfo.name // e.g. "files/abc-123"
        onUpload?(fileResourceName)
        
        defer {
            // Guarantee remote cleanup in a background task so we don't block return
            Task {
                print("[GeminiClient] Deleting remote file \(fileResourceName)...")
                try? await deleteFile(resourceName: fileResourceName)
            }
        }
        
        // 2. Poll state until ACTIVE
        try await waitForFileToBeActive(resourceName: fileResourceName)
        
        // 3. Generate Content with Fallback
        return try await generateContentWithFallback(fileUri: fileInfo.uri, systemPrompt: systemPrompt)
    }
    
    private func uploadFile(fileURL: URL) async throws -> FileInfo {
        let boundary = "Boundary-\(UUID().uuidString)"
        let url = URL(string: "https://generativelanguage.googleapis.com/upload/v1beta/files?key=\(apiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("multipart", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        
        let fileData = try Data(contentsOf: fileURL)
        
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        
        let metadata: [String: Any] = [
            "file": [
                "displayName": fileURL.lastPathComponent,
                "mimeType": "audio/mp4"
            ]
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [])
        body.append(metadataData)
        body.append("\r\n".data(using: .utf8)!)
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "GeminiClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid upload response"])
        }
        
        if !(200...299).contains(httpResponse.statusCode) {
            let responseString = String(data: data, encoding: .utf8) ?? "No response body"
            print("[GeminiClient] Upload failed with status \(httpResponse.statusCode). Response: \(responseString)")
            if let errResp = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
                throw NSError(domain: "GeminiClient", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: errResp.error.message])
            }
            throw NSError(domain: "GeminiClient", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Upload failed with status \(httpResponse.statusCode): \(responseString)"])
        }
        
        let uploadResp = try JSONDecoder().decode(FileAPIResponse.self, from: data)
        return uploadResp.file
    }
    
    private func waitForFileToBeActive(resourceName: String) async throws {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/\(resourceName)?key=\(apiKey)")!
        var attempts = 0
        let maxAttempts = 30
        
        while attempts < maxAttempts {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw NSError(domain: "GeminiClient", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to poll file state"])
            }
            
            let fileInfo = try JSONDecoder().decode(FileInfo.self, from: data)
            let state = fileInfo.state ?? "ACTIVE"
            
            if state == "ACTIVE" {
                print("[GeminiClient] Remote file is ACTIVE.")
                return
            } else if state == "FAILED" {
                throw NSError(domain: "GeminiClient", code: 3, userInfo: [NSLocalizedDescriptionKey: "File processing failed on Gemini servers"])
            }
            
            print("[GeminiClient] File processing state is \(state). Waiting 2s...")
            try await Task.sleep(nanoseconds: 2_000_000_000)
            attempts += 1
        }
        
        throw NSError(domain: "GeminiClient", code: 4, userInfo: [NSLocalizedDescriptionKey: "File processing timed out"])
    }
    
    private func generateContentWithFallback(fileUri: String, systemPrompt: String) async throws -> String {
        var lastError: Error?
        
        for modelName in modelsToTry {
            print("[GeminiClient] Attempting generation using model: \(modelName)...")
            let maxRetries = 3
            
            for attempt in 0..<maxRetries {
                do {
                    let text = try await generateContent(modelName: modelName, fileUri: fileUri, systemPrompt: systemPrompt)
                    print("[GeminiClient] Generation complete using \(modelName).")
                    return text
                } catch {
                    let err = error as NSError
                    let isRateLimit = err.code == 429 || err.localizedDescription.lowercased().contains("quota") || err.localizedDescription.lowercased().contains("limit")
                    
                    lastError = err
                    
                    if isRateLimit && modelName != modelsToTry.last {
                        print("[GeminiClient] Rate Limit hit for \(modelName). Swapping to next model tier...")
                        break // Break retry loop to try the next model
                    }
                    
                    if attempt < maxRetries - 1 {
                        let waitSec = Double(pow(2.0, Double(attempt + 1)))
                        print("[GeminiClient] Warning: \(modelName) call failed: \(err.localizedDescription). Retrying in \(waitSec)s...")
                        try await Task.sleep(nanoseconds: UInt64(waitSec * 1_000_000_000))
                    }
                }
            }
        }
        
        throw lastError ?? NSError(domain: "GeminiClient", code: 5, userInfo: [NSLocalizedDescriptionKey: "All models failed"])
    }
    
    private func generateContent(modelName: String, fileUri: String, systemPrompt: String) async throws -> String {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):generateContent?key=\(apiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        [
                            "fileData": [
                                "mimeType": "audio/mp4",
                                "fileUri": fileUri
                            ]
                        ],
                        [
                            "text": systemPrompt
                        ]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.0
            ]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody, options: [])
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "GeminiClient", code: 6, userInfo: [NSLocalizedDescriptionKey: "Invalid generateContent response"])
        }
        
        if !(200...299).contains(httpResponse.statusCode) {
            if let errResp = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
                throw NSError(domain: "GeminiClient", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: errResp.error.message])
            }
            throw NSError(domain: "GeminiClient", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Content generation failed with status \(httpResponse.statusCode)"])
        }
        
        let contentResponse = try JSONDecoder().decode(GenerateContentResponse.self, from: data)
        guard let candidate = contentResponse.candidates?.first,
              let text = candidate.content.parts.first?.text else {
            throw NSError(domain: "GeminiClient", code: 7, userInfo: [NSLocalizedDescriptionKey: "API response contains no candidates or text parts"])
        }
        
        return text
    }
    
    func deleteFile(resourceName: String) async throws {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/\(resourceName)?key=\(apiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { return }
        if httpResponse.statusCode != 200 {
            print("[GeminiClient] Warning: File deletion failed with status \(httpResponse.statusCode)")
        }
    }
}
