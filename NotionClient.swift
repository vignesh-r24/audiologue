import Foundation

struct NotionClient {
    static let notionVersion = "2022-06-28"
    
    // Asynchronously uploads a meeting summary to the user's Notion database.
    // Returns true on success, false on failure.
    static func uploadNote(title: String, markdown: String, displayDate: String) async -> Bool {
        // Retrieve credentials securely from the Keychain
        guard let token = KeychainHelper.get(service: "Audiologue", account: "notion_token"), !token.isEmpty,
              let databaseId = KeychainHelper.get(service: "Audiologue", account: "notion_database_id"), !databaseId.isEmpty else {
            print("[Notion] Notion integration not configured. Skipping upload.")
            return false
        }
        
        print("[Notion] Fetching database schema for ID: \(databaseId)...")
        guard let schema = await fetchDatabaseSchema(databaseId: databaseId, token: token) else {
            print("[Notion] Failed to retrieve database schema. Aborting upload.")
            return false
        }
        
        let titleKey = schema.titleKey
        print("[Notion] Discovered primary title property: '\(titleKey)'")
        
        // Extract metadata from the markdown content
        let category = extractCategory(from: markdown)
        let attendees = extractAttendees(from: markdown)
        let organization = extractOrganization(from: markdown)
        let objective = extractObjective(from: markdown)
        
        let dateObj = parseDateString(displayDate)
        
        var properties: [String: Any] = [:]
        var unmappedMetadata: [(String, String)] = []
        
        // Remove titleKey and dateKey from available keys to avoid duplicate mapping
        var availableProperties = schema.properties
        availableProperties.removeValue(forKey: titleKey)
        
        let dateKey = findDatePropertyKey(in: schema.properties)
        if let dKey = dateKey {
            availableProperties.removeValue(forKey: dKey)
        }
        
        // 1. Set Title
        properties[titleKey] = [
            "title": [
                ["text": ["content": title]]
            ]
        ]
        
        // 2. Map Date Property if it exists in the schema
        if let dKey = dateKey, let dateType = schema.properties[dKey] {
            if dateType == "date" {
                let isoFormatter = ISO8601DateFormatter()
                let dateIso = isoFormatter.string(from: dateObj)
                properties[dKey] = ["date": ["start": dateIso]]
            } else if dateType == "rich_text" {
                properties[dKey] = ["rich_text": [["text": ["content": displayDate]]]]
            } else {
                unmappedMetadata.append((dKey, displayDate))
            }
        } else {
            unmappedMetadata.append(("Date", displayDate))
        }
        
        // Discover potential properties in the schema dynamically
        let categoryKey = findPropertyKey(matching: ["category", "type", "meeting type", "kind", "genre"], in: availableProperties)
        if let catKey = categoryKey {
            availableProperties.removeValue(forKey: catKey)
        }
        
        let attendeesKey = findPropertyKey(matching: ["attendees", "participants", "speakers", "who"], in: availableProperties)
        if let attKey = attendeesKey {
            availableProperties.removeValue(forKey: attKey)
        }
        
        let organizationKey = findPropertyKey(matching: ["organization", "org", "company", "employer", "firm"], in: availableProperties)
        if let orgKey = organizationKey {
            availableProperties.removeValue(forKey: orgKey)
        }
        
        let objectiveKey = findPropertyKey(matching: ["objective", "goal", "purpose", "context", "summary", "description"], in: availableProperties)
        if let objKey = objectiveKey {
            availableProperties.removeValue(forKey: objKey)
        }
        
        // 3. Map Category
        if let catKey = categoryKey, let categoryType = schema.properties[catKey] {
            if categoryType == "select" {
                properties[catKey] = ["select": ["name": category]]
            } else if categoryType == "rich_text" {
                properties[catKey] = ["rich_text": [["text": ["content": category]]]]
            } else {
                unmappedMetadata.append((catKey, category))
            }
        } else {
            unmappedMetadata.append(("Category", category))
        }
        
        // 4. Map Attendees
        if let attKey = attendeesKey, let attendeesType = schema.properties[attKey] {
            let attendeeList = attendees.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0 != "Self" }
            
            if attendeesType == "multi_select" && !attendeeList.isEmpty {
                let objects = attendeeList.map { ["name": $0] }
                properties[attKey] = ["multi_select": objects]
            } else if attendeesType == "rich_text" {
                properties[attKey] = ["rich_text": [["text": ["content": attendees]]]]
            } else {
                unmappedMetadata.append((attKey, attendees))
            }
        } else {
            unmappedMetadata.append(("Attendees", attendees))
        }
        
        // 5. Map Organization
        if organization != "—" {
            if let orgKey = organizationKey, let orgType = schema.properties[orgKey] {
                if orgType == "select" {
                    properties[orgKey] = ["select": ["name": organization]]
                } else if orgType == "rich_text" {
                    properties[orgKey] = ["rich_text": [["text": ["content": organization]]]]
                } else {
                    unmappedMetadata.append((orgKey, organization))
                }
            } else {
                unmappedMetadata.append(("Organization", organization))
            }
        }
        
        // 6. Map Objective / Context
        if objective != "No context provided." {
            if let objKey = objectiveKey, let objType = schema.properties[objKey] {
                if objType == "rich_text" {
                    properties[objKey] = ["rich_text": [["text": ["content": objective]]]]
                } else if objType == "select" {
                    properties[objKey] = ["select": ["name": objective]]
                } else {
                    unmappedMetadata.append((objKey, objective))
                }
            } else {
                unmappedMetadata.append(("Objective", objective))
            }
        }
        
        // Convert Markdown to Notion Blocks
        var childrenBlocks = parseMarkdownToBlocks(markdown)
        
        // If there's unmapped metadata, prepend it as a clean block list at the top of the body
        if !unmappedMetadata.isEmpty {
            var metadataBlocks: [[String: Any]] = []
            metadataBlocks.append([
                "object": "block",
                "type": "heading_3",
                "heading_3": [
                    "rich_text": [["text": ["content": "Metadata Summary"]]]
                ]
            ])
            
            for (key, val) in unmappedMetadata {
                metadataBlocks.append([
                    "object": "block",
                    "type": "bulleted_list_item",
                    "bulleted_list_item": [
                        "rich_text": [
                            [
                                "type": "text",
                                "text": ["content": "\(key): "],
                                "annotations": ["bold": true]
                            ],
                            [
                                "type": "text",
                                "text": ["content": val]
                            ]
                        ]
                    ]
                ])
            }
            
            metadataBlocks.append([
                "object": "block",
                "type": "divider",
                "divider": [:]
            ])
            
            childrenBlocks.insert(contentsOf: metadataBlocks, at: 0)
        }
        
        // Send Create Page Request
        let payload: [String: Any] = [
            "parent": ["database_id": databaseId],
            "properties": properties,
            "children": childrenBlocks
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            print("[Notion] Failed to serialize page request payload.")
            return false
        }
        
        var request = URLRequest(url: URL(string: "https://api.notion.com/v1/pages")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(notionVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                print("[Notion] Connection error: Invalid HTTP response.")
                return false
            }
            
            if httpResponse.statusCode == 200 || httpResponse.statusCode == 201 {
                print("[Notion] Success! Uploaded meeting summary to Notion.")
                return true
            } else {
                let body = String(data: data, encoding: .utf8) ?? "No response body"
                print("[Notion] HTTP Error \(httpResponse.statusCode): \(body)")
                return false
            }
        } catch {
            print("[Notion] Failed to upload: \(error.localizedDescription)")
            return false
        }
    }
    
    // Helper to query database columns/properties type definitions
    struct DatabaseSchema {
        let titleKey: String
        let properties: [String: String]
    }
    
    private static func fetchDatabaseSchema(databaseId: String, token: String) async -> DatabaseSchema? {
        var request = URLRequest(url: URL(string: "https://api.notion.com/v1/databases/\(databaseId)")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(notionVersion, forHTTPHeaderField: "Notion-Version")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                print("[Notion] Schema fetch failed with status: \(code)")
                return nil
            }
            
            guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let propertiesDict = json["properties"] as? [String: [String: Any]] else {
                print("[Notion] Parse error: properties key missing in database response.")
                return nil
            }
            
            var titleKey = "Name" // Fallback name
            var properties: [String: String] = [:]
            
            for (propName, propDetails) in propertiesDict {
                if let type = propDetails["type"] as? String {
                    properties[propName] = type
                    if type == "title" {
                        titleKey = propName
                    }
                }
            }
            return DatabaseSchema(titleKey: titleKey, properties: properties)
        } catch {
            print("[Notion] Failed to fetch schema: \(error.localizedDescription)")
            return nil
        }
    }
    
    // Helper to match property keys case-insensitively
    private static func findPropertyKey(matching patterns: [String], in properties: [String: String]) -> String? {
        for pattern in patterns {
            let lowerPattern = pattern.lowercased()
            for key in properties.keys {
                if key.lowercased() == lowerPattern {
                    return key
                }
            }
        }
        for pattern in patterns {
            let lowerPattern = pattern.lowercased()
            for key in properties.keys {
                if key.lowercased().contains(lowerPattern) {
                    return key
                }
            }
        }
        return nil
    }
    
    // Helper to find any date property in the schema
    private static func findDatePropertyKey(in properties: [String: String]) -> String? {
        for (key, type) in properties {
            if type == "date" {
                return key
            }
        }
        let datePatterns = ["meeting date", "date", "timestamp", "time", "created"]
        for pattern in datePatterns {
            for (key, _) in properties {
                if key.lowercased().contains(pattern) {
                    return key
                }
            }
        }
        return nil
    }
    
    // Robust date parsing helper
    private static func parseDateString(_ displayDate: String) -> Date {
        let df = DateFormatter()
        df.dateStyle = .long
        df.timeStyle = .short
        if let date = df.date(from: displayDate) {
            return date
        }
        let formats = [
            "MMMM d, yyyy h:mm a",
            "MMMM d, yyyy 'at' h:mm a",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd_HH-mm"
        ]
        let customDf = DateFormatter()
        for fmt in formats {
            customDf.dateFormat = fmt
            if let date = customDf.date(from: displayDate) {
                return date
            }
        }
        return Date()
    }
    
    // Objective / Context extractor
    private static func extractObjective(from markdown: String) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        var capture = false
        var capturedLines: [String] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("## ") {
                let lowerHeader = trimmed.lowercased()
                if lowerHeader.contains("context") || lowerHeader.contains("summary") || lowerHeader.contains("objective") {
                    capture = true
                    continue
                } else if capture {
                    break
                }
            }
            if capture {
                if trimmed.hasPrefix("---") {
                    break
                }
                if !trimmed.isEmpty {
                    capturedLines.append(trimmed)
                }
            }
        }
        
        if capturedLines.isEmpty {
            return "No context provided."
        }
        
        let fullText = capturedLines.joined(separator: " ")
        if fullText.count > 200 {
            return String(fullText.prefix(197)) + "..."
        }
        return fullText
    }
    
    // Metadata Extractors
    private static func extractCategory(from markdown: String) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        for i in 0..<min(lines.count, 35) {
            let line = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("## Conversation Type") && i + 1 < lines.count {
                var extracted = lines[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                if extracted.hasPrefix("[") && extracted.hasSuffix("]") {
                    extracted = String(extracted.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if !extracted.isEmpty {
                    return extracted
                }
            }
        }
        return "Other"
    }
    
    private static func extractAttendees(from markdown: String) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        var attendeesSet = Set<String>()
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("**") {
                let components = trimmed.components(separatedBy: "**")
                if components.count > 2 {
                    let namePart = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    var speakerName = namePart
                    if speakerName.hasSuffix(":") {
                        speakerName = String(speakerName.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    let lowerName = speakerName.lowercased()
                    let isBlacklisted = lowerName.isEmpty || 
                                        lowerName == "they committed to" || 
                                        lowerName == "i committed to" || 
                                        lowerName == "action items" || 
                                        lowerName == "vignesh" || 
                                        lowerName == "vignesh radhakrishnan" ||
                                        speakerName.count >= 30
                    if !isBlacklisted {
                        attendeesSet.insert(speakerName)
                    }
                }
            }
        }
        
        let sorted = attendeesSet.sorted()
        return sorted.isEmpty ? "Self" : sorted.joined(separator: ", ")
    }
    
    private static func extractOrganization(from markdown: String) -> String {
        let lowerContent = markdown.lowercased()
        let knownOrgs = ["Intuit", "TechCorp", "SaaSify", "Amazon", "Google", "Mattel", "Kellogg", "Northwestern"]
        for org in knownOrgs {
            if lowerContent.contains(org.lowercased()) {
                return org
            }
        }
        return "—"
    }
    
    // Markdown to Notion Block Parser
    private static func parseMarkdownToBlocks(_ markdown: String) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        let lines = markdown.components(separatedBy: .newlines)
        
        var inCodeBlock = false
        var codeLines: [String] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if trimmed.hasPrefix("---") {
                blocks.append([
                    "object": "block",
                    "type": "divider",
                    "divider": [:]
                ])
                continue
            }
            
            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    blocks.append([
                        "object": "block",
                        "type": "code",
                        "code": [
                            "rich_text": [["text": ["content": codeLines.joined(separator: "\n")]]],
                            "language": "markdown"
                        ]
                    ])
                    codeLines.removeAll()
                    inCodeBlock = false
                } else {
                    inCodeBlock = true
                }
                continue
            }
            
            if inCodeBlock {
                codeLines.append(line)
                continue
            }
            
            if trimmed.isEmpty {
                continue
            }
            
            if trimmed.hasPrefix("# ") {
                blocks.append(createHeadingBlock(level: 1, text: String(trimmed.dropFirst(2))))
            } else if trimmed.hasPrefix("## ") {
                blocks.append(createHeadingBlock(level: 2, text: String(trimmed.dropFirst(3))))
            } else if trimmed.hasPrefix("### ") {
                blocks.append(createHeadingBlock(level: 3, text: String(trimmed.dropFirst(4))))
            } else if trimmed.hasPrefix("- ") {
                blocks.append(createBulletedItemBlock(text: String(trimmed.dropFirst(2))))
            } else if trimmed.hasPrefix("* ") {
                blocks.append(createBulletedItemBlock(text: String(trimmed.dropFirst(2))))
            } else {
                blocks.append(createParagraphBlock(text: line))
            }
            
            // Notion API has a limit of 100 blocks per request
            if blocks.count >= 95 {
                break
            }
        }
        
        if inCodeBlock && !codeLines.isEmpty {
            blocks.append([
                "object": "block",
                "type": "code",
                "code": [
                    "rich_text": [["text": ["content": codeLines.joined(separator: "\n")]]],
                    "language": "markdown"
                ]
            ])
        }
        
        return blocks
    }
    
    // Markdown bold parsing
    private static func parseRichText(_ text: String) -> [[String: Any]] {
        var richText: [[String: Any]] = []
        let parts = text.components(separatedBy: "**")
        
        for (index, part) in parts.enumerated() {
            if part.isEmpty {
                continue
            }
            let isBold = (index % 2 == 1)
            var textObj: [String: Any] = [
                "type": "text",
                "text": ["content": part]
            ]
            if isBold {
                textObj["annotations"] = ["bold": true]
            }
            richText.append(textObj)
        }
        
        if richText.isEmpty && !text.isEmpty {
            richText.append([
                "type": "text",
                "text": ["content": text]
            ])
        }
        
        return richText
    }
    
    private static func createHeadingBlock(level: Int, text: String) -> [String: Any] {
        let type = "heading_\(level)"
        return [
            "object": "block",
            "type": type,
            type: [
                "rich_text": parseRichText(text)
            ]
        ]
    }
    
    private static func createBulletedItemBlock(text: String) -> [String: Any] {
        return [
            "object": "block",
            "type": "bulleted_list_item",
            "bulleted_list_item": [
                "rich_text": parseRichText(text)
            ]
        ]
    }
    
    private static func createParagraphBlock(text: String) -> [String: Any] {
        return [
            "object": "block",
            "type": "paragraph",
            "paragraph": [
                "rich_text": parseRichText(text)
            ]
        ]
    }
}
