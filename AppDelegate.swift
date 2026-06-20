import Cocoa
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var statusTitleItem: NSMenuItem!
    private var recentNotesMenu: NSMenu!
    private var openFolderItem: NSMenuItem!
    private var setKeyItem: NSMenuItem!
    private var quitItem: NSMenuItem!
    
    private var recorder: AudioRecorder?
    private var isRecording = false
    private var isProcessing = false
    private var activeGeminiClient: GeminiClient?
    private var activeRemoteFileName: String?
    
    private var firstName: String {
        return NSFullUserName().components(separatedBy: " ").first ?? NSUserName()
    }
    
    private var systemPrompt: String {
        let name = firstName
        return """
        You are a strategic communications analyst. Analyze the attached audio and produce a structured markdown summary designed to be actionable for the primary user (the person who recorded this).

        First line: Meeting Title: [3-5 word title]

        Then classify the conversation type before summarizing. This changes what you focus on.

        ## Conversation Type
        Identify one: [Recruiter Screen | Networking/Referral Call | Mentorship/Catch-up | Team Meeting | Interview | Other]

        ---

        ## Context
        One sentence: Who spoke, what is their role/relationship, and what was the purpose of this conversation.

        ## Key Takeaways
        The 3-5 most important things learned, offered, or agreed to in this conversation. Each should be specific and actionable, not philosophical or generic. Ask yourself: if the user re-reads this summary in 2 weeks, what do they need to remember?

        ## Commitments Made
        Split into two sections. Only include commitments that were explicitly stated, not implied.

        **They committed to:**
        - [Name]: [What they said they would do]

        **I committed to:**
        - [What the user said they would do]

        ## Strategic Intelligence
        Information shared during the conversation that the user could leverage in future conversations, interviews, or decisions. This includes: insider knowledge about a company, team, or role; advice given; preferences or priorities revealed by the other party; names dropped that could be useful for networking.

        ## Follow-Up Plan
        Based on the commitments and conversation, what should the user do next and by when? Be specific.

        ## Relationship Status
        One sentence: Where does this relationship stand after this call, and what is the appropriate next touchpoint?

        ## Communication Self-Assessment
        Evaluate **\(name)**'s communication only.
        Note 2-3 moments where \(name) could have been more concise, structured, or direct. Include the approximate timestamp or context, what was said, and a tighter alternative. Focus on patterns like: unnecessary preamble, mid-sentence restarts, over-long answers, or talking when they should have been listening.

        ---

        ## Transcript
        Provide a chronological, verbatim, diarized transcript. Identify speakers by name using context clues:
        - The primary user (the person who recorded this meeting) is named \(name). Label their turns as **\(name)**.
        - Identify the other speaker(s) dynamically by their actual name if mentioned or introduced in the audio. If their name is not mentioned, label them by their role (e.g., **Recruiter**, **Interviewer**, **Manager**) or relationship if clear from context, rather than using generic labels like "Speaker 2".
        - Format each turn as:
          **[Speaker Name]:** [Verbatim speech]
        - Use paragraph breaks between speakers. Do not merge multiple speakers into one block.
        - Mark unclear, overlapping, or whispered segments as `[inaudible]` rather than guessing the words.
        """
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Setup status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            if let image = NSImage(named: "icon") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "A"
            }
        }
        
        setupMenu()
        
        // Register signal handlers for graceful shutdown on terminal exit
        setupSignalHandlers()
        
        // Hide dock icon for dockless experience
        NSApp.setActivationPolicy(.accessory)
    }
    
    private func setupMenu() {
        let menu = NSMenu()
        
        statusTitleItem = NSMenuItem(title: "Status: Idle", action: nil, keyEquivalent: "")
        statusTitleItem.isEnabled = false
        menu.addItem(statusTitleItem)
        
        toggleItem = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "")
        menu.addItem(toggleItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Recent Notes Submenu
        let recentNotesItem = NSMenuItem(title: "Recent Notes", action: nil, keyEquivalent: "")
        recentNotesMenu = NSMenu()
        recentNotesItem.submenu = recentNotesMenu
        menu.addItem(recentNotesItem)
        updateRecentNotesMenu()
        
        openFolderItem = NSMenuItem(title: "Open Notes Folder", action: #selector(openNotesFolder), keyEquivalent: "")
        menu.addItem(openFolderItem)
        
        setKeyItem = NSMenuItem(title: "Set Gemini API Key", action: #selector(setApiKey), keyEquivalent: "")
        menu.addItem(setKeyItem)
        
        menu.addItem(NSMenuItem.separator())
        
        quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        menu.addItem(quitItem)
        
        statusItem.menu = menu
    }
    
    @objc private func toggleRecording() {
        if isProcessing { return }
        
        if !isRecording {
            startRecording()
        } else {
            stopRecording()
        }
    }
    
    private func startRecording() {
        // Check API key first
        guard let apiKey = KeychainHelper.get(service: "Audiologue", account: "api_key"), !apiKey.isEmpty else {
            showErrorAlert(title: "API Key Required", message: "Please set your Gemini API Key before recording.")
            setApiKey()
            return
        }
        
        let tempDir = FileManager.default.temporaryDirectory
        let outputURL = tempDir.appendingPathComponent("meeting_recording.m4a")
        
        recorder = AudioRecorder(outputURL: outputURL)
        
        isRecording = true
        statusTitleItem.title = "Status: Recording..."
        toggleItem.title = "Stop Recording"
        statusItem.button?.title = "[R]"
        if let button = statusItem.button {
            button.imagePosition = .imageLeft
        }
        
        Task {
            do {
                try await recorder?.start()
                print("[System] Recording started.")
            } catch {
                let errDesc = error.localizedDescription
                let isPermissionError = errDesc.contains("TCC") || errDesc.contains("declined") || errDesc.contains("permission")
                
                if isPermissionError {
                    // Sleep to allow the macOS system prompt to be visible and clickable without being overlapped
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                }
                
                await MainActor.run {
                    self.showErrorAlert(
                        title: "Recording Failed",
                        message: "Could not start audio recording. Verify that your app has Microphone and Screen Recording permissions.\n\n" +
                                 "Error: \(errDesc)\n\n" +
                                 "If 'Audiologue' is already enabled in your settings but you still see this message:\n\n" +
                                 "1. Open System Settings > Privacy & Security > Screen & System Audio Recording.\n" +
                                 "2. Select 'Audiologue' in the list and click the minus '-' button to remove it completely.\n" +
                                 "3. Try recording again. This will force macOS to refresh its security database."
                    )
                    self.resetUIState()
                }
            }
        }
    }
    
    private func stopRecording() {
        isRecording = false
        isProcessing = true
        statusTitleItem.title = "Status: Processing..."
        toggleItem.title = "Processing Notes..."
        statusItem.button?.title = "[P]"
        
        Task {
            do {
                print("[System] Stopping recording stream...")
                try await recorder?.stop()
                
                let tempDir = FileManager.default.temporaryDirectory
                let recordedURL = tempDir.appendingPathComponent("meeting_recording.m4a")
                
                guard FileManager.default.fileExists(atPath: recordedURL.path) else {
                    throw NSError(domain: "AppDelegate", code: 1, userInfo: [NSLocalizedDescriptionKey: "Recorded file not found at \(recordedURL.path)"])
                }
                
                // Get API key
                guard let apiKey = KeychainHelper.get(service: "Audiologue", account: "api_key") else {
                    throw NSError(domain: "AppDelegate", code: 2, userInfo: [NSLocalizedDescriptionKey: "API Key missing during processing"])
                }
                
                let client = GeminiClient(apiKey: apiKey)
                self.activeGeminiClient = client
                
                print("[System] Initiating Gemini analysis...")
                let notesMarkdown = try await client.analyzeAudio(fileURL: recordedURL, systemPrompt: systemPrompt) { [weak self] filename in
                    self?.activeRemoteFileName = filename
                }
                
                // Reset active files state
                self.activeGeminiClient = nil
                self.activeRemoteFileName = nil
                
                // Save and Open Note
                try saveAndOpenNote(content: notesMarkdown)
                
                // Clean up local temp file
                try? FileManager.default.removeItem(at: recordedURL)
                
            } catch {
                print("[Error] Processing pipeline failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.showErrorAlert(title: "Transcription Failed", message: "Failed to summarize meeting audio.\n\nError: \(error.localizedDescription)")
                    
                    // Rescue the file to the notes folder
                    let tempDir = FileManager.default.temporaryDirectory
                    let recordedURL = tempDir.appendingPathComponent("meeting_recording.m4a")
                    if FileManager.default.fileExists(atPath: recordedURL.path) {
                        let df = DateFormatter()
                        df.dateFormat = "yyyy-MM-dd_HH-mm"
                        let timestamp = df.string(from: Date())
                        let recoveryURL = self.getNotesDirectory().appendingPathComponent("Failed_Transcription_\(timestamp).m4a")
                        try? FileManager.default.moveItem(at: recordedURL, to: recoveryURL)
                        print("[Recovery] Audio rescued to \(recoveryURL.path)")
                        self.showErrorAlert(title: "Audio Rescued", message: "The audio was saved to your Notes folder as:\n\n\(recoveryURL.lastPathComponent)")
                    }
                }
            }
            
            await MainActor.run {
                self.resetUIState()
                self.updateRecentNotesMenu()
            }
        }
    }
    
    private func resetUIState() {
        isRecording = false
        isProcessing = false
        statusTitleItem.title = "Status: Idle"
        toggleItem.title = "Start Recording"
        statusItem.button?.title = ""
        statusItem.button?.imagePosition = .imageOnly
        recorder = nil
    }
    
    private func saveAndOpenNote(content: String) throws {
        // Parse Title
        var meetingTitle = "Untitled Meeting"
        let lines = content.components(separatedBy: .newlines)
        var sanitizedContent = content
        
        if let firstLine = lines.first, firstLine.hasPrefix("Meeting Title:") {
            let rawTitle = firstLine.replacingOccurrences(of: "Meeting Title:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !rawTitle.isEmpty {
                meetingTitle = rawTitle
            }
            
            // Skip title and empty line in output note
            let skipCount = (lines.count > 1 && lines[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ? 2 : 1
            sanitizedContent = lines.dropFirst(skipCount).joined(separator: "\n")
        }
        
        // Sanitize filename
        var sanitizedTitle = meetingTitle.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).inverted).joined(separator: "_")
        while sanitizedTitle.contains("__") {
            sanitizedTitle = sanitizedTitle.replacingOccurrences(of: "__", with: "_")
        }
        sanitizedTitle = sanitizedTitle.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if sanitizedTitle.isEmpty { sanitizedTitle = "Meeting_Note" }
        
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HH-mm"
        let timestamp = df.string(from: Date())
        
        let notesDir = getNotesDirectory()
        let notesURL = notesDir.appendingPathComponent("\(timestamp)_\(sanitizedTitle).md")
        
        try sanitizedContent.write(to: notesURL, atomically: true, encoding: .utf8)
        print("[System] Saved meeting note to: \(notesURL.path)")
        
        // Open note in TextEdit
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-a", "TextEdit", notesURL.path]
        task.launch()
    }
    
    private func getNotesDirectory() -> URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let audiologueDir = appSupport.appendingPathComponent("Audiologue")
        let notesDir = audiologueDir.appendingPathComponent("MeetingNotes")
        try? fm.createDirectory(at: notesDir, withIntermediateDirectories: true, attributes: [FileAttributeKey.posixPermissions: 0o700])
        return notesDir
    }
    

    private func updateRecentNotesMenu() {
        recentNotesMenu.removeAllItems()
        let recent = getRecentNotes()
        
        if recent.isEmpty {
            let item = NSMenuItem(title: "No recent notes", action: nil, keyEquivalent: "")
            item.isEnabled = false
            recentNotesMenu.addItem(item)
        } else {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            let todayStr = df.string(from: Date())
            
            for noteURL in recent {
                let filename = noteURL.deletingPathExtension().lastPathComponent
                let parts = filename.components(separatedBy: "_")
                
                var datePart = ""
                var timePart = ""
                var titlePart = ""
                
                if parts.count >= 3 {
                    datePart = parts[0]
                    timePart = parts[1]
                    titlePart = parts.dropFirst(2).joined(separator: " ")
                } else if parts.count == 2 {
                    datePart = parts[0]
                    timePart = parts[1]
                } else {
                    datePart = todayStr
                    timePart = "00-00"
                    titlePart = filename
                }
                
                let timeFormatted = timePart.replacingOccurrences(of: "-", with: ":")
                var timePrefix = ""
                
                if datePart != todayStr {
                    let dateSplit = datePart.components(separatedBy: "-")
                    if dateSplit.count == 3 {
                        timePrefix = "\(dateSplit[1])/\(dateSplit[2]) - \(timeFormatted)"
                    } else {
                        timePrefix = "\(datePart) - \(timeFormatted)"
                    }
                } else {
                    timePrefix = timeFormatted
                }
                
                var displayTitle = ""
                if !titlePart.isEmpty {
                    displayTitle = "\(timePrefix) | \(titlePart)"
                } else {
                    displayTitle = timePrefix
                }
                
                let item = NSMenuItem(title: displayTitle, action: #selector(openRecentNote(_:)), keyEquivalent: "")
                item.representedObject = noteURL
                recentNotesMenu.addItem(item)
            }
        }
    }
    
    @objc private func openRecentNote(_ sender: NSMenuItem) {
        guard let noteURL = sender.representedObject as? URL else { return }
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-a", "TextEdit", noteURL.path]
        task.launch()
    }
    
    private func getRecentNotes() -> [URL] {
        let notesDir = getNotesDirectory()
        let fm = FileManager.default
        do {
            let contents = try fm.contentsOfDirectory(at: notesDir, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)
            let mdFiles = contents.filter { $0.pathExtension.lowercased() == "md" }
            let sorted = try mdFiles.sorted {
                let date1 = try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? Date.distantPast
                let date2 = try $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? Date.distantPast
                return date1 > date2
            }
            return Array(sorted.prefix(5))
        } catch {
            print("Failed to query recent notes: \(error.localizedDescription)")
            return []
        }
    }
    
    @objc private func openNotesFolder() {
        let notesDir = getNotesDirectory()
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = [notesDir.path]
        task.launch()
    }
    
    @objc private func setApiKey() {
        let alert = NSAlert()
        alert.messageText = "Gemini API Key Setup"
        alert.informativeText = "Please enter your Gemini API Key. You can obtain one for free in Google AI Studio."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.stringValue = KeychainHelper.get(service: "Audiologue", account: "api_key") ?? ""
        alert.accessoryView = input
        
        // Force pop-up window focus on top of all other windows
        NSApp.activate(ignoringOtherApps: true)
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let newKey = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !newKey.isEmpty {
                KeychainHelper.set(service: "Audiologue", account: "api_key", value: newKey)
                print("[System] API Key saved to system Keychain.")
            }
        }
    }
    
    private func showErrorAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        print("[Shutdown] Graceful cleanup starting...")
        
        // 1. Force stop recorders
        if isRecording {
            let recorderRef = recorder
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                try? await recorderRef?.stop()
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 2.0)
        }
        
        // 2. Clean up remote file on Gemini servers if we quit in the middle of processing
        if let client = activeGeminiClient, let resourceName = activeRemoteFileName {
            print("[Shutdown] Cleaning up remote file from Gemini File API: \(resourceName)")
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                try? await client.deleteFile(resourceName: resourceName)
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 2.0)
        }
        
        // 3. Sweep temporary local recordings
        let tempDir = FileManager.default.temporaryDirectory
        let filesToClean = ["meeting_recording.m4a", "temp_sys.m4a", "temp_mic.caf"]
        for file in filesToClean {
            let fileURL = tempDir.appendingPathComponent(file)
            try? FileManager.default.removeItem(at: fileURL)
        }
        
        print("[Shutdown] Cleanup complete.")
    }
    
    // POSIX Signal handling for graceful shutdown in terminal context
    private func setupSignalHandlers() {
        let handler: @convention(c) (Int32) -> Void = { sig in
            print("\n[Shutdown] Received terminal signal (\(sig)). Executing application exit sequence...")
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
        
        signal(SIGINT, handler)
        signal(SIGTERM, handler)
    }
}
