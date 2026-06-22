import Cocoa
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var statusTitleItem: NSMenuItem!
    private var deviceInfoItem: NSMenuItem!
    private var recentNotesMenu: NSMenu!
    private var openFolderItem: NSMenuItem!
    private var setKeyItem: NSMenuItem!
    private var setNotionItem: NSMenuItem!
    private var quitItem: NSMenuItem!
    private var dashboardItem: NSMenuItem!
    
    private var recorder: AudioRecorder?
    private var isRecording = false
    private var isProcessing = false
    private var activeGeminiClient: GeminiClient?
    private var activeRemoteFileName: String?
    
    private var recordingTimer: Timer?
    private var recordingStartDate: Date?
    
    private var firstName: String {
        return NSFullUserName().components(separatedBy: " ").first ?? NSUserName()
    }
    
    private var systemPrompt: String {
        let name = firstName
        return """
        CRITICAL SAFETY CHECK: If the attached audio is completely silent, contains only static, or contains only background noise (with no human voice or vocals at all), you MUST NOT hallucinate or fabricate any conversation, speakers, or meeting details. Instead, you must output exactly:
        Meeting Title: No Speech Detected
        No speech detected in the audio recording.
        Do not generate any other sections or text.

        You are a strategic communications analyst. Analyze the attached audio and produce a structured markdown summary designed to be actionable for the primary user (the person who recorded this).

        First line: Meeting Title: [3-5 word title]

        Then classify the conversation type before summarizing. This changes what you focus on.

        ## Conversation Type
        Identify one: [Meeting | Interview | Media/Podcast | Other]
        - Choose 'Meeting' for professional calls, catch-ups, syncs, or coffee chats with other participants.
        - Choose 'Interview' for recruiter screens, job interviews, or interview practices/bio introductions.
        - Choose 'Media/Podcast' for recorded podcasts, lectures, video audio, or passive listening/commentaries.
        - Choose 'Other' for vocal practice, singing, hardware test recordings, or miscellaneous items.

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
        IMPORTANT: Only generate this section if the recording is a meeting, interview, or call where \(name) is actively participating and speaking. If this is a passive recording (e.g., a podcast, YouTube video, presentation, or lecture) where \(name) is not speaking, output: "No communication assessment available (primary user \(name) did not participate in the conversation)."
        Otherwise, note 2-3 moments where \(name) could have been more concise, structured, or direct. Include the approximate timestamp or context, what was said, and a tighter alternative. Focus on patterns like: unnecessary preamble, mid-sentence restarts, over-long answers, or talking when they should have been listening.

        ---

        ## Transcript
        Provide a chronological, verbatim, diarized transcript. Identify speakers by name using context clues:
        - The primary user (the person who recorded this meeting) is named \(name). Label a speaker's turns as **\(name)** ONLY if the recording is a meeting, call, or interview where \(name) is actively participating and speaking. Do NOT label any speaker as **\(name)** in passive recordings of external content (e.g., YouTube videos, podcast episodes, lectures, audiobooks, or presentations) unless there is clear, explicit evidence/confirmation (such as verbal introductions or other speakers addressing them by name) that \(name) is speaking.
        - If it is a passive recording or \(name) is not speaking, identify speakers dynamically by their actual names if mentioned in the audio, or by their roles or descriptive labels (e.g., **Host**, **Guest**, **Co-Host**, **Presenter**, **Speaker 1**, **Speaker 2**).
        - Format each turn as:
          **[Speaker Name]:** [Verbatim speech]
        - Use paragraph breaks between speakers. Do not merge multiple speakers into one block.
        - Mark unclear, overlapping, or whispered segments as `[inaudible]` rather than guessing the words.
        """
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Redirect print statements and errors to a local log file for easy debugging
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let audiologueDir = appSupport.appendingPathComponent("Audiologue")
        try? FileManager.default.createDirectory(at: audiologueDir, withIntermediateDirectories: true)
        let logURL = audiologueDir.appendingPathComponent("audiologue.log")
        if let logPath = logURL.path.cString(using: .utf8) {
            _ = freopen(logPath, "a", stdout)
            _ = freopen(logPath, "a", stderr)
            // Disable stdout/stderr buffering to flush logs immediately to disk
            setvbuf(stdout, nil, _IONBF, 0)
            setvbuf(stderr, nil, _IONBF, 0)
        }
        print("\n--- Audiologue Launched at \(Date()) ---")

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
        
        // Run migration of existing loose HTML files to .previews subfolder
        migrateExistingHTMLFiles()
        
        // Regenerate the dashboard HTML to ensure it is up-to-date
        regenerateDashboard()
        
        // Register signal handlers for graceful shutdown on terminal exit
        setupSignalHandlers()
        
        // Register custom URL scheme handler for audiologue://
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        
        // Hide dock icon for dockless experience
        NSApp.setActivationPolicy(.accessory)
    }
    
    private func setupMenu() {
        let menu = NSMenu()
        
        statusTitleItem = NSMenuItem(title: "Status: Idle", action: nil, keyEquivalent: "")
        statusTitleItem.isEnabled = false
        menu.addItem(statusTitleItem)
        
        deviceInfoItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        deviceInfoItem.isEnabled = false
        deviceInfoItem.isHidden = true
        menu.addItem(deviceInfoItem)
        
        toggleItem = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "")
        menu.addItem(toggleItem)
        
        dashboardItem = NSMenuItem(title: "View Notes Dashboard", action: #selector(openDashboard), keyEquivalent: "")
        menu.addItem(dashboardItem)
        
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
        
        setNotionItem = NSMenuItem(title: "Configure Notion...", action: #selector(configureNotion), keyEquivalent: "")
        menu.addItem(setNotionItem)
        
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
        statusTitleItem.title = "Status: Connecting..."
        toggleItem.title = "Stop Recording"
        
        // Show [R] next to the app icon in the menu bar during recording
        statusItem.button?.attributedTitle = NSAttributedString(string: "")
        statusItem.button?.title = "[R]"
        if let button = statusItem.button {
            button.imagePosition = .imageLeft
        }
        
        // Show device info
        let deviceName = recorder?.getDefaultInputDeviceName() ?? "Unknown"
        deviceInfoItem.title = deviceName
        if #available(macOS 11.0, *) {
            if let micImage = NSImage(systemSymbolName: "mic", accessibilityDescription: "Microphone") {
                micImage.isTemplate = true
                deviceInfoItem.image = micImage
            }
        }
        deviceInfoItem.isHidden = false
        
        Task {
            do {
                try await recorder?.start()
                print("[System] Recording started.")
                
                await MainActor.run {
                    // Only start timer and set date once recording successfully begins
                    self.recordingStartDate = Date()
                    self.statusTitleItem.title = "Status: Recording... 00:00"
                    
                    // Start elapsed timer (fires every second on the main RunLoop in common modes)
                    let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                        guard let self = self, let start = self.recordingStartDate else { return }
                        let elapsed = Int(Date().timeIntervalSince(start))
                        let mins = elapsed / 60
                        let secs = elapsed % 60
                        let timeStr = String(format: "%02d:%02d", mins, secs)
                        self.statusTitleItem.title = "Status: Recording... \(timeStr)"
                    }
                    RunLoop.current.add(timer, forMode: .common)
                    self.recordingTimer = timer
                }
            } catch {
                let errDesc = error.localizedDescription
                await MainActor.run {
                    print("[Error] Recording failed to start: \(errDesc)")
                    self.resetUIState()
                }
            }
        }
    }
    
    private func stopRecording() {
        isRecording = false
        isProcessing = true
        
        // Invalidate timer immediately so time stops going up
        recordingTimer?.invalidate()
        recordingTimer = nil
        
        statusTitleItem.title = "Status: Processing..."
        toggleItem.title = "Processing Notes..."
        
        // Show [P] next to the app icon in the menu bar during processing
        statusItem.button?.attributedTitle = NSAttributedString(string: "")
        statusItem.button?.title = "[P]"
        if let button = statusItem.button {
            button.imagePosition = .imageLeft
        }
        
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
        statusItem.button?.attributedTitle = NSAttributedString(string: "")
        statusItem.button?.title = ""
        statusItem.button?.imagePosition = .imageOnly
        recorder = nil
        
        // Stop elapsed timer and hide device info
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartDate = nil
        deviceInfoItem.isHidden = true
        deviceInfoItem.image = nil
    }
    
    private func generateHTMLFile(markdownContent: String, title: String, displayDate: String, outputURL: URL) throws {
        let base64Markdown = Data(markdownContent.utf8).base64EncodedString()
        let userFirstName = self.firstName
        
        let htmlTemplate = #"""
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Meeting Summary - {{TITLE}}</title>
    <style>
        @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap');
        
        :root {
            --bg-color: #f8fafc;
            --card-bg: #ffffff;
            --text-primary: #1e293b;
            --text-secondary: #475569;
            --text-muted: #64748b;
            --accent: #6366f1;
            --accent-hover: #4f46e5;
            --border-color: #f1f5f9;
            --shadow-sm: 0 1px 2px 0 rgba(0, 0, 0, 0.02);
            --shadow-md: 0 4px 12px -2px rgba(0, 0, 0, 0.03), 0 2px 6px -1px rgba(0, 0, 0, 0.02);
            --shadow-lg: 0 20px 25px -5px rgba(0, 0, 0, 0.03), 0 10px 10px -5px rgba(0, 0, 0, 0.02);
        }

        * {
            box-sizing: border-box;
            margin: 0;
            padding: 0;
        }

        body {
            background-color: var(--bg-color);
            color: var(--text-primary);
            font-family: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
            line-height: 1.7;
            -webkit-font-smoothing: antialiased;
            display: flex;
            min-height: 100vh;
        }

        .app-container {
            display: flex;
            width: 100%;
            max-width: 1440px;
            margin: 0 auto;
            padding: 24px;
            gap: 24px;
        }

        .sidebar {
            width: 320px;
            flex-shrink: 0;
            display: flex;
            flex-direction: column;
            gap: 20px;
            position: sticky;
            top: 24px;
            height: calc(100vh - 48px);
        }

        .sidebar-card {
            background: var(--card-bg);
            border: 1px solid var(--border-color);
            border-radius: 12px;
            padding: 24px;
            box-shadow: var(--shadow-md);
        }

        .sidebar-title {
            font-size: 0.75rem;
            text-transform: uppercase;
            letter-spacing: 0.1em;
            color: var(--text-muted);
            margin-bottom: 8px;
            font-weight: 700;
        }

        .sidebar-meta {
            margin-bottom: 24px;
        }

        .meta-item {
            margin-bottom: 12px;
        }

        .meta-label {
            font-size: 0.75rem;
            color: var(--text-muted);
            font-weight: 500;
        }

        .meta-value {
            font-size: 0.95rem;
            font-weight: 600;
            color: var(--text-primary);
        }

        .btn {
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 8px;
            width: 100%;
            padding: 12px 16px;
            border-radius: 8px;
            font-size: 0.9rem;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.2s ease;
            border: none;
            outline: none;
        }

        .btn-primary {
            background-color: var(--accent);
            color: #ffffff;
        }

        .btn-primary:hover {
            background-color: var(--accent-hover);
            transform: translateY(-1px);
        }

        .btn-secondary {
            background-color: transparent;
            color: var(--text-primary);
            border: 1px solid var(--border-color);
            margin-top: 10px;
        }

        .btn-secondary:hover {
            background-color: #f1f5f9;
            border-color: var(--text-muted);
        }

        #notion-btn:hover {
            background-color: rgba(99, 102, 241, 0.05) !important;
            border-color: var(--accent) !important;
            transform: translateY(-1px);
        }

        .content-panel {
            flex-grow: 1;
            background: var(--card-bg);
            border: 1px solid var(--border-color);
            border-radius: 12px;
            padding: 48px;
            box-shadow: var(--shadow-lg);
            overflow-y: auto;
            max-width: 900px;
        }

        .note-header {
            margin-bottom: 32px;
            border-bottom: 1px solid var(--border-color);
            padding-bottom: 24px;
        }

        .note-title {
            font-size: 2rem;
            font-weight: 700;
            color: #0f172a;
            line-height: 1.25;
            margin-bottom: 8px;
            letter-spacing: -0.02em;
        }

        .note-subtitle {
            font-size: 0.9rem;
            color: var(--text-muted);
        }

        strong {
            font-weight: 600;
            color: #0f172a;
        }

        .rendered-markdown h1,
        .rendered-markdown h2,
        .rendered-markdown h3 {
            color: #0f172a;
            font-weight: 600;
            letter-spacing: -0.02em;
        }

        .rendered-markdown h1 {
            font-size: 1.6rem;
            margin-top: 2rem;
            margin-bottom: 1rem;
            border-bottom: 1px solid var(--border-color);
            padding-bottom: 8px;
        }

        .rendered-markdown h2 {
            font-size: 1.25rem;
            margin-top: 2rem;
            margin-bottom: 1rem;
            padding-bottom: 4px;
            position: relative;
        }

        .rendered-markdown h2::after {
            content: '';
            position: absolute;
            bottom: 0;
            left: 0;
            width: 32px;
            height: 2px;
            background-color: var(--accent);
            border-radius: 2px;
        }

        .rendered-markdown h3 {
            font-size: 1.1rem;
            margin-top: 1.5rem;
            margin-bottom: 0.5rem;
        }

        .rendered-markdown p {
            margin-bottom: 1rem;
            color: var(--text-secondary);
            font-size: 0.975rem;
        }

        .rendered-markdown ul,
        .rendered-markdown ol {
            list-style: none;
            padding-left: 0;
            margin-bottom: 1.25rem;
        }

        .rendered-markdown li {
            position: relative;
            padding-left: 20px;
            margin-bottom: 6px;
            font-size: 0.975rem;
            color: var(--text-secondary);
        }

        .rendered-markdown li::before {
            content: "•";
            color: var(--accent);
            position: absolute;
            left: 6px;
            top: 0;
            font-weight: bold;
        }

        .rendered-markdown hr {
            margin: 2rem 0;
            border: 0;
            border-top: 1px solid var(--border-color);
        }

        .rendered-markdown blockquote {
            background: rgba(99, 102, 241, 0.02);
            border-left: 3px solid var(--accent);
            padding: 12px 18px;
            margin: 1.5rem 0;
            border-radius: 0 8px 8px 0;
            font-style: italic;
        }

        .rendered-markdown blockquote p {
            margin-bottom: 0;
            font-size: 0.975rem;
            color: var(--text-secondary);
        }

        .transcript-turn {
            margin-bottom: 12px;
            padding: 12px 16px;
            border-radius: 8px;
            background: #fafafa;
            border: 1px solid #f1f5f9;
            transition: all 0.2s ease;
        }

        .transcript-turn:hover {
            background: #f8fafc;
            border-color: #e2e8f0;
        }

        .user-turn {
            background: rgba(99, 102, 241, 0.02);
            border-left: 3px solid var(--accent);
        }

        .user-turn .speaker {
            color: var(--accent);
        }

        .other-turn {
            background: rgba(13, 148, 136, 0.01);
            border-left: 3px solid #0d9488;
        }

        .other-turn .speaker {
            color: #0d9488;
        }

        .speaker {
            font-weight: 600;
            display: inline-block;
            margin-bottom: 4px;
            font-size: 0.8rem;
            text-transform: uppercase;
            letter-spacing: 0.05em;
        }

        .speech {
            display: block;
            color: var(--text-primary);
            font-size: 0.95rem;
            line-height: 1.6;
        }

        .inaudible {
            color: #94a3b8;
            font-style: italic;
            background: #f1f5f9;
            padding: 2px 6px;
            border-radius: 4px;
            font-size: 0.85em;
        }

        code {
            font-family: 'JetBrains Mono', monospace;
            background: #f1f5f9;
            padding: 2px 6px;
            border-radius: 4px;
            font-size: 0.9em;
            color: #e11d48;
        }

        pre {
            background: #f8fafc;
            border: 1px solid var(--border-color);
            border-radius: 8px;
            padding: 16px;
            overflow-x: auto;
            margin-bottom: 1.25rem;
        }

        pre code {
            background: transparent;
            padding: 0;
            border-radius: 0;
            color: var(--text-primary);
        }

        #toast {
            position: fixed;
            bottom: 24px;
            right: 24px;
            background: #0f172a;
            color: #ffffff;
            padding: 12px 24px;
            border-radius: 8px;
            box-shadow: var(--shadow-lg);
            font-weight: 500;
            font-size: 0.9rem;
            z-index: 1000;
            opacity: 0;
            transform: translateY(100px);
            transition: all 0.3s cubic-bezier(0.16, 1, 0.3, 1);
            display: flex;
            align-items: center;
            gap: 8px;
        }

        #toast.show {
            opacity: 1;
            transform: translateY(0);
        }

        .toast-icon {
            color: #10b981;
        }

        @media (max-width: 1024px) {
            .app-container {
                flex-direction: column;
                padding: 16px;
            }

            .sidebar {
                width: 100%;
                height: auto;
                position: static;
            }

            .content-panel {
                padding: 24px;
                max-width: 100%;
            }
        }
        
        .spinner {
            animation: spin 1s linear infinite;
        }
        @keyframes spin {
            0% { transform: rotate(0deg); }
            100% { transform: rotate(360deg); }
        }
    </style>
</head>
<body>
    <div class="app-container">
        <div class="sidebar">
            <div class="sidebar-card">
                <h3 class="sidebar-title">Audiologue</h3>
                <div class="sidebar-meta">
                    <div class="meta-item">
                        <div class="meta-label">Note Date</div>
                        <div class="meta-value" id="meta-date">-</div>
                    </div>
                    <div class="meta-item">
                        <div class="meta-label">Meeting Name</div>
                        <div class="meta-value" id="meta-title">-</div>
                    </div>
                </div>
                
                <button class="btn btn-primary" id="copy-md-btn">
                    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path></svg>
                    Copy Markdown
                </button>
                <div style="font-size:0.75rem; color:var(--text-muted); text-align:center; margin-top:6px;">
                    Paste directly into Notion, Slack, or Obsidian
                </div>
                
                <button class="btn btn-secondary" id="notion-btn" style="display: {{SHOW_NOTION_BUTTON}}; align-items: center; justify-content: center; margin-top: 10px; border-color: #6366f1; color: #6366f1;">
                    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="margin-right: 8px;"><path d="M12 2L2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5"/></svg>
                    Send to Notion
                </button>
                
                <a class="btn btn-secondary" href="../dashboard.html" style="text-decoration: none; display: flex; align-items: center; justify-content: center; margin-top: 16px;">
                    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="margin-right: 8px;"><rect x="3" y="3" width="7" height="9"></rect><rect x="14" y="3" width="7" height="5"></rect><rect x="14" y="12" width="7" height="9"></rect><rect x="3" y="16" width="7" height="5"></rect></svg>
                    View Dashboard
                </a>
            </div>
        </div>

        <div class="content-panel">
            <header class="note-header">
                <h1 class="note-title" id="note-title">-</h1>
                <div class="note-subtitle" id="note-subtitle">-</div>
            </header>
            <main class="rendered-markdown" id="content-area">
                Loading summary...
            </main>
        </div>
    </div>

    <div id="toast">
        <svg class="toast-icon" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 6 9 17 4 12"></polyline></svg>
        <span id="toast-message">Copied to clipboard!</span>
    </div>

    <script>
        const base64Markdown = "{{BASE64_MARKDOWN}}";
        const userFirstName = "{{USER_FIRST_NAME}}";
        const meetingDateStr = "{{MEETING_DATE}}";
        const rawTitleStr = "{{RAW_TITLE}}";

        function decodeBase64Utf8(base64) {
            const binary = atob(base64);
            const bytes = new Uint8Array(binary.length);
            for (let i = 0; i < binary.length; i++) {
                bytes[i] = binary.charCodeAt(i);
            }
            return new TextDecoder().decode(bytes);
        }

        function renderInline(text) {
            text = text.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
            text = text.replace(/\*([^*]+)\*/g, '<em>$1</em>');
            text = text.replace(/`([^`]+)`/g, '<code>$1</code>');
            text = text.replace(/\[inaudible\]/gi, '<span class="inaudible">[inaudible]</span>');
            return text;
        }

        function renderMarkdown(md) {
            const lines = md.split('\n');
            let html = '';
            let inList = false;
            let inTranscript = false;
            let inCodeBlock = false;
            let codeContent = [];

            for (let i = 0; i < lines.length; i++) {
                const line = lines[i];
                const trimmed = line.trim();
                
                // Code Blocks
                if (trimmed.startsWith('```')) {
                    if (inCodeBlock) {
                        inCodeBlock = false;
                        html += `<pre><code>${codeContent.join('\n')}</code></pre>`;
                        codeContent = [];
                    } else {
                        inCodeBlock = true;
                    }
                    continue;
                }
                
                if (inCodeBlock) {
                    codeContent.push(line);
                    continue;
                }

                // Close list if we hit a non-list item
                if (inList && !trimmed.startsWith('- ') && !trimmed.startsWith('* ')) {
                    html += '</ul>';
                    inList = false;
                }

                // Horizontal Rule
                if (trimmed === '---' || trimmed === '***') {
                    html += '<hr>';
                    continue;
                }

                // Headings
                if (trimmed.startsWith('# ')) {
                    // Skip Heading 1 in content area as it is already displayed in the page header card
                    continue;
                }
                if (trimmed.startsWith('## ')) {
                    const headerText = trimmed.substring(3).trim();
                    if (headerText.toLowerCase() === 'transcript') {
                        inTranscript = true;
                    } else {
                        inTranscript = false;
                    }
                    html += `<h2>${renderInline(headerText)}</h2>`;
                    continue;
                }
                if (trimmed.startsWith('### ')) {
                    html += `<h3>${renderInline(trimmed.substring(4))}</h3>`;
                    continue;
                }

                // List Items
                if (trimmed.startsWith('- ') || trimmed.startsWith('* ')) {
                    if (!inList) {
                        html += '<ul>';
                        inList = true;
                    }
                    html += `<li>${renderInline(trimmed.substring(2))}</li>`;
                    continue;
                }

                // Blockquotes
                if (trimmed.startsWith('>')) {
                    html += `<blockquote>${renderInline(trimmed.replace(/^>\s?/, ''))}</blockquote>`;
                    continue;
                }

                // Empty Lines
                if (trimmed === '') {
                    continue;
                }

                // Speaker turns in Transcript formatting: **Speaker Name:** text
                const speakerRegex = /^\*\*([^*:]+)(?::\*\*|\*\*:\s*)(.*)$/;
                const match = trimmed.match(speakerRegex);
                if (match) {
                    const speaker = match[1].trim();
                    const text = match[2].trim();
                    const isUser = speaker.toLowerCase() === userFirstName.toLowerCase();
                    html += `<div class="transcript-turn ${isUser ? 'user-turn' : 'other-turn'}">
                        <span class="speaker">${speaker}</span>
                        <span class="speech">${renderInline(text)}</span>
                    </div>`;
                    continue;
                }

                // Paragraphs
                html += `<p>${renderInline(trimmed)}</p>`;
            }

            if (inList) {
                html += '</ul>';
            }

            return html;
        }

        function showToast(message) {
            const toast = document.getElementById('toast');
            const msg = document.getElementById('toast-message');
            msg.textContent = message;
            toast.classList.add('show');
            setTimeout(() => {
                toast.classList.remove('show');
            }, 2500);
        }

        function copyToClipboard(text) {
            navigator.clipboard.writeText(text).then(() => {
                showToast("Markdown copied to clipboard!");
            }).catch(err => {
                console.error("Copy failed: ", err);
                showToast("Failed to copy clipboard.");
            });
        }

        window.addEventListener('DOMContentLoaded', () => {
            const md = decodeBase64Utf8(base64Markdown);
            
            document.getElementById('note-title').textContent = rawTitleStr;
            document.getElementById('meta-title').textContent = rawTitleStr;
            document.getElementById('meta-date').textContent = meetingDateStr;
            document.getElementById('note-subtitle').textContent = "Meeting Note generated on " + meetingDateStr;
            
            const contentArea = document.getElementById('content-area');
            contentArea.innerHTML = renderMarkdown(md);
            
            document.getElementById('copy-md-btn').addEventListener('click', () => {
                const fullMarkdown = "# " + rawTitleStr + "\n\n" + md;
                copyToClipboard(fullMarkdown);
            });

            const notionBtn = document.getElementById('notion-btn');
            if (notionBtn) {
                notionBtn.addEventListener('click', () => {
                    notionBtn.disabled = true;
                    notionBtn.style.opacity = '0.7';
                    notionBtn.innerHTML = `
                        <svg class="spinner" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" style="margin-right: 8px;">
                            <line x1="12" y1="2" x2="12" y2="6"></line>
                            <line x1="12" y1="18" x2="12" y2="22"></line>
                            <line x1="4.93" y1="4.93" x2="7.76" y2="7.76"></line>
                            <line x1="16.24" y1="16.24" x2="19.07" y2="19.07"></line>
                            <line x1="2" y1="12" x2="6" y2="12"></line>
                            <line x1="18" y1="12" x2="22" y2="12"></line>
                            <line x1="4.93" y1="19.07" x2="7.76" y2="16.24"></line>
                            <line x1="16.24" y1="7.76" x2="19.07" y2="4.93"></line>
                        </svg>
                        Sending...
                    `;
                    
                    let iframe = document.getElementById('notion-iframe');
                    if (!iframe) {
                        iframe = document.createElement('iframe');
                        iframe.id = 'notion-iframe';
                        iframe.style.display = 'none';
                        document.body.appendChild(iframe);
                    }
                    iframe.src = `audiologue://upload_notion?filename={{FILENAME}}`;
                    
                    showToast("Sending note to Notion...");
                    
                    setTimeout(() => {
                        notionBtn.innerHTML = `
                            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#22c55e" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" style="margin-right: 8px;">
                                <polyline points="20 6 9 17 4 12"></polyline>
                            </svg>
                            Sent to Notion!
                        `;
                        notionBtn.style.borderColor = '#22c55e';
                        notionBtn.style.color = '#22c55e';
                    }, 2000);
                });
            }
        });
    </script>
</body>
</html>
"""#
        
        let notionToken = KeychainHelper.get(service: "Audiologue", account: "notion_token") ?? ""
        let notionDbId = KeychainHelper.get(service: "Audiologue", account: "notion_database_id") ?? ""
        let showNotionBtn = (!notionToken.isEmpty && !notionDbId.isEmpty) ? "flex" : "none"
        let filename = outputURL.deletingPathExtension().lastPathComponent
        
        let html = htmlTemplate
            .replacingOccurrences(of: "{{BASE64_MARKDOWN}}", with: base64Markdown)
            .replacingOccurrences(of: "{{USER_FIRST_NAME}}", with: userFirstName)
            .replacingOccurrences(of: "{{MEETING_DATE}}", with: displayDate)
            .replacingOccurrences(of: "{{RAW_TITLE}}", with: title)
            .replacingOccurrences(of: "{{TITLE}}", with: title)
            .replacingOccurrences(of: "{{SHOW_NOTION_BUTTON}}", with: showNotionBtn)
            .replacingOccurrences(of: "{{FILENAME}}", with: filename)
        
        try html.write(to: outputURL, atomically: true, encoding: .utf8)
    }

    private func getFormattedDate(fromFilename filename: String) -> String {
        let parts = filename.components(separatedBy: "_")
        if parts.count >= 2 {
            let datePart = parts[0]
            let timePart = parts[1]
            
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH-mm"
            if let date = df.date(from: "\(datePart) \(timePart)") {
                let displayDf = DateFormatter()
                displayDf.dateStyle = .long
                displayDf.timeStyle = .short
                return displayDf.string(from: date)
            }
        }
        let displayDf = DateFormatter()
        displayDf.dateStyle = .long
        displayDf.timeStyle = .short
        return displayDf.string(from: Date())
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
        let markdownOutput = "# \(meetingTitle)\n\n\(sanitizedContent)"
        try markdownOutput.write(to: notesURL, atomically: true, encoding: .utf8)
        print("[System] Saved meeting note to: \(notesURL.path)")
        
        // Generate and Open HTML File in .previews subfolder
        let previewsDir = notesDir.appendingPathComponent(".previews")
        try? FileManager.default.createDirectory(at: previewsDir, withIntermediateDirectories: true, attributes: [FileAttributeKey.posixPermissions: 0o700])
        let htmlURL = previewsDir.appendingPathComponent("\(timestamp)_\(sanitizedTitle).html")
        let displayDf = DateFormatter()
        displayDf.dateStyle = .long
        displayDf.timeStyle = .short
        let displayDate = displayDf.string(from: Date())
        
        try generateHTMLFile(markdownContent: sanitizedContent, title: meetingTitle, displayDate: displayDate, outputURL: htmlURL)
        print("[System] Saved meeting HTML to: \(htmlURL.path)")
        
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = [htmlURL.path]
        task.launch()
        
        // Regenerate the dashboard HTML to include the new note
        regenerateDashboard()
    }
    
    private func getNotesDirectory() -> URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let audiologueDir = appSupport.appendingPathComponent("Audiologue")
        let notesDir = audiologueDir.appendingPathComponent("MeetingNotes")
        try? fm.createDirectory(at: notesDir, withIntermediateDirectories: true, attributes: [FileAttributeKey.posixPermissions: 0o700])
        return notesDir
    }
    
    private func migrateExistingHTMLFiles() {
        let fm = FileManager.default
        let notesDir = getNotesDirectory()
        let previewsDir = notesDir.appendingPathComponent(".previews")
        
        do {
            try fm.createDirectory(at: previewsDir, withIntermediateDirectories: true, attributes: [FileAttributeKey.posixPermissions: 0o700])
            let contents = try fm.contentsOfDirectory(at: notesDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            let htmlFiles = contents.filter { $0.pathExtension.lowercased() == "html" }
            
            for srcURL in htmlFiles {
                let destURL = previewsDir.appendingPathComponent(srcURL.lastPathComponent)
                try? fm.moveItem(at: srcURL, to: destURL)
                print("[Migration] Moved \(srcURL.lastPathComponent) to .previews/")
            }
        } catch {
            print("Failed migration: \(error.localizedDescription)")
        }
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
        
        let notesDir = noteURL.deletingLastPathComponent()
        let previewsDir = notesDir.appendingPathComponent(".previews")
        let filename = noteURL.deletingPathExtension().lastPathComponent
        let htmlURL = previewsDir.appendingPathComponent("\(filename).html")
        
        // If HTML doesn't exist, regenerate it on-the-fly
        if !FileManager.default.fileExists(atPath: htmlURL.path) {
            try? FileManager.default.createDirectory(at: previewsDir, withIntermediateDirectories: true, attributes: [FileAttributeKey.posixPermissions: 0o700])
            do {
                let content = try String(contentsOf: noteURL, encoding: .utf8)
                
                // Try to extract title from content, or default to filename
                var meetingTitle = "Untitled Meeting"
                let lines = content.components(separatedBy: .newlines)
                if let firstLine = lines.first {
                    if firstLine.hasPrefix("Meeting Title:") {
                        let rawTitle = firstLine.replacingOccurrences(of: "Meeting Title:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !rawTitle.isEmpty { meetingTitle = rawTitle }
                    } else if firstLine.hasPrefix("# ") {
                        let rawTitle = firstLine.replacingOccurrences(of: "# ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !rawTitle.isEmpty { meetingTitle = rawTitle }
                    } else {
                        let parts = filename.components(separatedBy: "_")
                        if parts.count >= 3 {
                            meetingTitle = parts.dropFirst(2).joined(separator: " ").replacingOccurrences(of: "_", with: " ")
                        } else if parts.count == 2 {
                            meetingTitle = "Meeting \(parts[0]) \(parts[1])"
                        } else {
                            meetingTitle = filename
                        }
                    }
                }
                
                let displayDate = getFormattedDate(fromFilename: filename)
                try generateHTMLFile(markdownContent: content, title: meetingTitle, displayDate: displayDate, outputURL: htmlURL)
                print("[System] Regenerated missing HTML file for recent note: \(htmlURL.path)")
            } catch {
                print("Failed to regenerate HTML for note: \(error.localizedDescription)")
                // Fallback to TextEdit
                let task = Process()
                task.launchPath = "/usr/bin/open"
                task.arguments = ["-a", "TextEdit", noteURL.path]
                task.launch()
                return
            }
        }
        
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = [htmlURL.path]
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
        
        let input = EditableNSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
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
    
    @objc private func configureNotion() {
        let alert = NSAlert()
        alert.messageText = "Notion Integration Setup"
        alert.informativeText = "Enter your Notion Integration Token and Database ID. Make sure to share your Notion database with the integration."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        
        let tokenLabel = NSTextField(labelWithString: "Internal Integration Token:")
        tokenLabel.frame = NSRect(x: 0, y: 75, width: 300, height: 18)
        container.addSubview(tokenLabel)
        
        let tokenInput = EditableNSTextField(frame: NSRect(x: 0, y: 50, width: 300, height: 24))
        tokenInput.stringValue = KeychainHelper.get(service: "Audiologue", account: "notion_token") ?? ""
        container.addSubview(tokenInput)
        
        let dbLabel = NSTextField(labelWithString: "Database ID:")
        dbLabel.frame = NSRect(x: 0, y: 25, width: 300, height: 18)
        container.addSubview(dbLabel)
        
        let dbInput = EditableNSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        dbInput.stringValue = KeychainHelper.get(service: "Audiologue", account: "notion_database_id") ?? ""
        container.addSubview(dbInput)
        
        alert.accessoryView = container
        NSApp.activate(ignoringOtherApps: true)
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let newToken = tokenInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawDbId = dbInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            
            let cleanedInput = rawDbId.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
            let pathPart = cleanedInput.components(separatedBy: "?").first ?? cleanedInput
            
            var newDbId = pathPart
            let pattern = "[a-fA-F0-9]{32}"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let nsRange = NSRange(location: 0, length: pathPart.utf16.count)
                if let match = regex.firstMatch(in: pathPart, options: [], range: nsRange) {
                    if let range = Range(match.range, in: pathPart) {
                        newDbId = String(pathPart[range])
                    }
                }
            }
            
            if !newToken.isEmpty {
                KeychainHelper.set(service: "Audiologue", account: "notion_token", value: newToken)
            } else {
                KeychainHelper.delete(service: "Audiologue", account: "notion_token")
            }
            
            if !newDbId.isEmpty {
                KeychainHelper.set(service: "Audiologue", account: "notion_database_id", value: newDbId)
            } else {
                KeychainHelper.delete(service: "Audiologue", account: "notion_database_id")
            }
            
            print("[System] Notion configuration saved securely.")
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
    
    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        if let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
           let url = URL(string: urlString) {
            handleURL(url)
        }
    }
    
    private func handleURL(_ url: URL) {
        guard url.scheme == "audiologue" else { return }
        
        if url.host == "delete" {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
                  let queryItems = components.queryItems,
                  let filename = queryItems.first(where: { $0.name == "filename" })?.value else {
                return
            }
            
            let sanitized = filename.replacingOccurrences(of: "..", with: "")
                                    .replacingOccurrences(of: "/", with: "")
                                    .replacingOccurrences(of: "\\", with: "")
            
            if !sanitized.isEmpty {
                deleteNoteFiles(filename: sanitized)
            }
        } else if url.host == "upload_notion" {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
                  let queryItems = components.queryItems,
                  let filename = queryItems.first(where: { $0.name == "filename" })?.value else {
                return
            }
            
            let sanitized = filename.replacingOccurrences(of: "..", with: "")
                                    .replacingOccurrences(of: "/", with: "")
                                    .replacingOccurrences(of: "\\", with: "")
            
            if !sanitized.isEmpty {
                uploadNoteToNotion(filename: sanitized)
            }
        }
    }
    
    private func uploadNoteToNotion(filename: String) {
        let notesDir = getNotesDirectory()
        let cleanName = filename.replacingOccurrences(of: ".md", with: "")
        let mdURL = notesDir.appendingPathComponent("\(cleanName).md")
        
        guard let content = try? String(contentsOf: mdURL, encoding: .utf8) else {
            print("[Notion] Error: Could not read note content for upload: \(mdURL.path)")
            return
        }
        
        // Parse Title and Sanitized Content
        var meetingTitle = "Untitled Meeting"
        let lines = content.components(separatedBy: .newlines)
        var sanitizedContent = content
        
        if let firstLine = lines.first, firstLine.hasPrefix("# ") {
            meetingTitle = firstLine.replacingOccurrences(of: "# ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            sanitizedContent = lines.dropFirst().joined(separator: "\n")
        } else if let firstLine = lines.first, firstLine.hasPrefix("Meeting Title:") {
            meetingTitle = firstLine.replacingOccurrences(of: "Meeting Title:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            let skipCount = (lines.count > 1 && lines[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ? 2 : 1
            sanitizedContent = lines.dropFirst(skipCount).joined(separator: "\n")
        }
        
        let displayDate = getFormattedDate(fromFilename: cleanName)
        
        let finalTitle = meetingTitle
        let finalContent = sanitizedContent
        let finalDate = displayDate
        
        Task {
            let success = await NotionClient.uploadNote(title: finalTitle, markdown: finalContent, displayDate: finalDate)
            await MainActor.run {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                if success {
                    alert.messageText = "Notion Upload Successful"
                    alert.informativeText = "Successfully uploaded '\(finalTitle)' to your Notion database."
                    alert.alertStyle = .informational
                } else {
                    alert.messageText = "Notion Upload Failed"
                    alert.informativeText = "An error occurred while uploading '\(finalTitle)' to Notion. Please check your network connection and configuration."
                    alert.alertStyle = .warning
                }
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }
    
    private func deleteNoteFiles(filename: String) {
        let notesDir = getNotesDirectory()
        let mdURL = notesDir.appendingPathComponent("\(filename).md")
        let htmlURL = notesDir.appendingPathComponent(".previews/\(filename).html")
        
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: mdURL.path) {
                try fm.removeItem(at: mdURL)
                print("[System] Deleted markdown note: \(mdURL.path)")
            }
            if fm.fileExists(atPath: htmlURL.path) {
                try fm.removeItem(at: htmlURL)
                print("[System] Deleted preview HTML: \(htmlURL.path)")
            }
            
            DispatchQueue.main.async {
                self.regenerateDashboard()
                self.updateRecentNotesMenu()
            }
        } catch {
            print("[Error] Failed to delete note files for \(filename): \(error.localizedDescription)")
        }
    }
    
    @objc private func openDashboard() {
        regenerateDashboard()
        let notesDir = getNotesDirectory()
        let dashboardURL = notesDir.appendingPathComponent("dashboard.html")
        
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = [dashboardURL.path]
        task.launch()
    }
    
    private func regenerateDashboard() {
        let notesDir = getNotesDirectory()
        let dashboardURL = notesDir.appendingPathComponent("dashboard.html")
        let notesList = getNotesList()
        do {
            try generateDashboardHTML(notesList: notesList, outputURL: dashboardURL)
            print("[System] Dashboard successfully regenerated at: \(dashboardURL.path)")
        } catch {
            print("[Error] Failed to regenerate dashboard: \(error.localizedDescription)")
        }
    }
    
    private func getNotesList() -> [NoteInfo] {
        let notesDir = getNotesDirectory()
        let fm = FileManager.default
        var list: [NoteInfo] = []
        
        do {
            let contents = try fm.contentsOfDirectory(at: notesDir, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)
            let mdFiles = contents.filter { $0.pathExtension.lowercased() == "md" }
            
            for noteURL in mdFiles {
                let filename = noteURL.deletingPathExtension().lastPathComponent
                guard let content = try? String(contentsOf: noteURL, encoding: .utf8) else { continue }
                
                let lines = content.components(separatedBy: .newlines)
                
                var title = filename.replacingOccurrences(of: "_", with: " ")
                if let firstLine = lines.first {
                    if firstLine.hasPrefix("# ") {
                        title = firstLine.replacingOccurrences(of: "# ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                    } else if firstLine.hasPrefix("Meeting Title:") {
                        title = firstLine.replacingOccurrences(of: "Meeting Title:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                
                let lowerTitle = title.lowercased()
                let lowerContent = content.lowercased()
                
                var conversationType = "Other"
                var context = ""
                
                for i in 0..<min(lines.count, 35) {
                    let line = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
                    if line.hasPrefix("## Conversation Type") && i + 1 < lines.count {
                        var extractedType = lines[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                        if extractedType.hasPrefix("[") && extractedType.hasSuffix("]") {
                            extractedType = String(extractedType.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        if !extractedType.isEmpty {
                            conversationType = extractedType
                        }
                    } else if line.hasPrefix("## Context") && i + 1 < lines.count {
                        context = lines[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                
                // If title is generic, fallback to cleaning the filename
                if title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "meeting transcript & summary" {
                    let cleanPattern = "^\\d{4}-\\d{2}-\\d{2}_\\d{2}-\\d{2}_?"
                    if let regex = try? NSRegularExpression(pattern: cleanPattern, options: []) {
                        let nsRange = NSRange(location: 0, length: filename.utf16.count)
                        let cleaned = regex.stringByReplacingMatches(in: filename, options: [], range: nsRange, withTemplate: "")
                        if !cleaned.isEmpty {
                            title = cleaned.replacingOccurrences(of: "_", with: " ")
                        }
                    }
                }
                
                // Extract Attendees
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
                            if !lowerName.isEmpty && lowerName != "they committed to" && lowerName != "i committed to" && lowerName != "action items" && speakerName.count < 30 {
                                attendeesSet.insert(speakerName)
                            }
                        }
                    }
                }
                
                var attendeesList = attendeesSet.sorted()
                attendeesList = attendeesList.filter { name in
                    let lower = name.lowercased()
                    return lower != "vignesh" && lower != "vignesh radhakrishnan"
                }
                
                var attendees = attendeesList.joined(separator: ", ")
                if attendees.isEmpty {
                    if context.contains("Vignesh spoke with ") {
                        let parts = context.components(separatedBy: "Vignesh spoke with ")
                        if parts.count > 1 {
                            let afterSpoke = parts[1]
                            let nameWord = afterSpoke.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            if !nameWord.isEmpty && nameWord.count < 30 {
                                attendees = nameWord
                            }
                        }
                    }
                }
                
                if attendees.isEmpty {
                    attendees = "Self"
                }
                
                // Extract Organization
                var organization = "—"
                let knownOrgs = ["Intuit", "TechCorp", "SaaSify", "Amazon", "Google", "Mattel", "Kellogg", "Northwestern"]
                for org in knownOrgs {
                    if title.localizedCaseInsensitiveContains(org) || filename.localizedCaseInsensitiveContains(org) || context.localizedCaseInsensitiveContains(org) {
                        organization = org
                        break
                    }
                }
                if organization == "—" {
                    if let regex = try? NSRegularExpression(pattern: "\\bat\\s+([A-Z][a-zA-Z0-9]+)\\b", options: []) {
                        let nsRange = NSRange(content.startIndex..<content.endIndex, in: content)
                        if let match = regex.firstMatch(in: content, options: [], range: nsRange) {
                            if let orgRange = Range(match.range(at: 1), in: content) {
                                let candidate = String(content[orgRange])
                                let blacklist = ["The", "A", "An", "This", "First", "In", "On", "At", "Vignesh", "Sarah", "Rashmi", "St", "State", "He", "She", "They", "We", "I", "You", "It", "No", "Yes", "So"]
                                if !blacklist.contains(candidate) && candidate.count > 2 && candidate.count < 30 {
                                    organization = candidate
                                }
                            }
                        }
                    }
                }
                
                // Standardize Category
                var standardizedCategory = "Other"
                let lowerType = conversationType.lowercased()
                let lowerContext = context.lowercased()
                let lowerAttendees = attendees.lowercased()
                
                let isMediaWord = lowerTitle.contains("gameplay") || lowerTitle.contains("commentary") || lowerTitle.contains("playthrough") || lowerTitle.contains("video") || lowerTitle.contains("stream") || lowerTitle.contains("episode") || lowerTitle.contains("podcast") || lowerTitle.contains("highlights")
                
                if lowerContent.contains("not a participant") || lowerContext.contains("not a participant") || lowerType.contains("podcast") || lowerType.contains("media") || lowerType.contains("show") || lowerType.contains("stream") || lowerType.contains("listening") || isMediaWord || lowerAttendees.contains("commentator") || lowerAttendees.contains("host") || lowerAttendees.contains("guest") {
                    standardizedCategory = "Media/Podcast"
                } else if lowerType.contains("recruiter") || lowerType.contains("screen") || lowerType.contains("interview") || lowerTitle.contains("interview") || lowerType.contains("introduction") || lowerTitle.contains("bio") || lowerType.contains("pitch") {
                    standardizedCategory = "Interview"
                } else if lowerType.contains("meeting") || lowerType.contains("team") || lowerType.contains("call") || lowerType.contains("catch-up") {
                    standardizedCategory = "Meeting"
                } else if attendees != "Self" && !attendees.isEmpty {
                    let isGenericSpeaker = lowerAttendees == "speaker 1" || lowerAttendees == "speaker 2" || lowerAttendees == "singer" || lowerAttendees == "vocalist"
                    if isGenericSpeaker && lowerType.contains("other") {
                        standardizedCategory = "Other"
                    } else {
                        standardizedCategory = "Meeting"
                    }
                }
                
                let displayDate = getFormattedDate(fromFilename: filename)
                let previewFilename = "\(filename).html"
                
                // Resilient Lookup: Ensure preview HTML exists
                let previewsDir = notesDir.appendingPathComponent(".previews")
                let htmlURL = previewsDir.appendingPathComponent(previewFilename)
                if !fm.fileExists(atPath: htmlURL.path) {
                    print("[Resilient Lookup] HTML preview missing for \(filename). Generating companion...")
                    try? generateHTMLFile(markdownContent: content, title: title, displayDate: displayDate, outputURL: htmlURL)
                }
                
                list.append(NoteInfo(
                    filename: filename,
                    title: title,
                    dateString: displayDate,
                    conversationType: standardizedCategory,
                    context: context,
                    previewFilename: previewFilename,
                    attendees: attendees,
                    organization: organization
                ))
            }
            
            return list.sorted { $0.filename > $1.filename }
        } catch {
            print("Failed to list notes for dashboard: \(error.localizedDescription)")
            return []
        }
    }
    
    private func generateDashboardHTML(notesList: [NoteInfo], outputURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let jsonData = (try? encoder.encode(notesList)) ?? Data()
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "[]"
        
        let htmlTemplate = #"""
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Audiologue - Notes Dashboard</title>
    <style>
        @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap');
        
        * {
            box-sizing: border-box;
            margin: 0;
            padding: 0;
        }

        body {
            background-color: #f8fafc;
            color: #1e293b;
            font-family: 'Inter', -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            line-height: 1.5;
            -webkit-font-smoothing: antialiased;
            padding: 40px 24px;
        }

        .container {
            max-width: 1040px;
            margin: 0 auto;
        }

        header {
            margin-bottom: 32px;
        }

        .brand-section h1 {
            font-size: 2rem;
            font-weight: 700;
            color: #0f172a;
            letter-spacing: -0.025em;
        }

        .brand-section p {
            color: #64748b;
            font-size: 0.95rem;
            margin-top: 4px;
        }

        /* Controls bar */
        .controls-bar {
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 16px;
            margin-bottom: 20px;
            flex-wrap: wrap;
        }

        .search-container {
            position: relative;
            display: flex;
            align-items: center;
        }

        .search-icon {
            position: absolute;
            left: 12px;
            width: 16px;
            height: 16px;
            color: #64748b;
            fill: none;
            stroke: currentColor;
            stroke-width: 2;
            pointer-events: none;
        }

        .search-input {
            padding: 8px 12px 8px 36px;
            border-radius: 6px;
            border: 1px solid #cbd5e1;
            font-size: 14px;
            font-family: inherit;
            color: #1e293b;
            outline: none;
            transition: all 0.15s ease;
            width: 240px;
            background-color: #ffffff;
        }

        .search-input:focus {
            border-color: #6366f1;
            box-shadow: 0 0 0 2px rgba(99, 102, 241, 0.15);
        }

        .filter-pills {
            display: flex;
            gap: 6px;
            flex-wrap: wrap;
        }

        .filter-pill {
            padding: 6px 12px;
            border-radius: 20px;
            font-size: 13px;
            font-weight: 600;
            cursor: pointer;
            background-color: #e2e8f0;
            color: #475569;
            border: none;
            transition: all 0.15s ease;
        }

        .filter-pill:hover {
            background-color: #cbd5e1;
            color: #1e293b;
        }

        .filter-pill.active {
            background-color: #6366f1;
            color: #ffffff;
        }

        .note-count {
            color: #64748b;
            font-size: 13px;
            font-weight: 500;
        }

        /* Simple Table styling */
        .table-container {
            width: 100%;
            overflow-x: auto;
            background: #ffffff;
            border-radius: 8px;
            border: 1px solid #e2e8f0;
            box-shadow: 0 1px 3px 0 rgba(0, 0, 0, 0.05);
            margin-bottom: 24px;
        }

        .notes-table {
            width: 100%;
            border-collapse: collapse;
            font-size: 14px;
            text-align: left;
            min-width: 800px;
        }

        .notes-table th {
            padding: 12px 16px;
            font-weight: 600;
            color: #475569;
            border-bottom: 1px solid #e2e8f0;
            background-color: #f8fafc;
        }

        .notes-table td {
            padding: 14px 16px;
            border-bottom: 1px solid #e2e8f0;
            vertical-align: middle;
            color: #334155;
        }

        .notes-table tr:last-child td {
            border-bottom: none;
        }

        .notes-table tr:hover {
            background-color: #f8fafc;
        }

        .note-title-link {
            color: #6366f1;
            text-decoration: none;
            font-weight: 600;
            transition: color 0.15s ease;
        }

        .note-title-link:hover {
            color: #4f46e5;
            text-decoration: underline;
        }

        /* Simplified tag badges */
        .badge {
            font-size: 12px;
            font-weight: 500;
            padding: 4px 10px;
            border-radius: 4px;
            display: inline-block;
            white-space: nowrap;
            line-height: 1.2;
            background-color: #f1f5f9;
            color: #475569;
        }

        .badge-interview { background-color: #fee2e2; color: #991b1b; }
        .badge-meeting { background-color: #e0f2fe; color: #075985; }
        .badge-media-podcast { background-color: #dcfce7; color: #166534; }
        .badge-other { background-color: #f1f5f9; color: #475569; }

        .organization-text {
            font-weight: 500;
            color: #334155;
        }

        .date-text {
            color: #64748b;
            font-size: 13px;
        }

        .delete-btn {
            background: none;
            border: none;
            color: #ef4444;
            cursor: pointer;
            padding: 4px;
            border-radius: 4px;
            display: inline-flex;
            align-items: center;
            justify-content: center;
            transition: all 0.15s ease;
        }

        .delete-btn:hover {
            background-color: #fef2f2;
            color: #b91c1c;
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <div class="brand-section">
                <h1>Meeting Notes</h1>
                <p>Dashboard of your transcribed notes and strategic summaries</p>
            </div>
        </header>

        <section class="controls-bar">
            <div class="search-container">
                <svg class="search-icon" viewBox="0 0 16 16"><path d="M11.742 10.344a6.5 6.5 0 1 0-1.397 1.398h-.001c.03.04.062.078.098.115l3.85 3.85a1 1 0 0 0 1.415-1.414l-3.85-3.85a1.007 1.007 0 0 0-.115-.1zM12 6.5a5.5 5.5 0 1 1-11 0 5.5 5.5 0 0 1 11 0z"/></svg>
                <input type="text" id="search-input" class="search-input" placeholder="Search notes...">
            </div>
            <div class="filter-pills" id="filter-tabs">
                <button class="filter-pill active" data-filter="all">All</button>
                <button class="filter-pill" data-filter="Meeting">Meetings</button>
                <button class="filter-pill" data-filter="Interview">Interviews</button>
                <button class="filter-pill" data-filter="Media/Podcast">Media & Podcasts</button>
                <button class="filter-pill" data-filter="Other">Other</button>
            </div>
            <div class="note-count" id="note-count">0 meetings</div>
        </section>

        <main class="table-container">
            <table class="notes-table">
                <thead>
                    <tr>
                        <th style="width: 30%;">Meeting Name</th>
                        <th style="width: 20%;">Attendees</th>
                        <th style="width: 15%;">Organization</th>
                        <th style="width: 13%;">Category</th>
                        <th style="width: 14%;">Meeting Date</th>
                        <th style="width: 8%; text-align: center;">Actions</th>
                    </tr>
                </thead>
                <tbody id="table-body">
                    <!-- Dynamic rows injected here -->
                </tbody>
            </table>
        </main>
        
        <div id="empty-state" class="empty-state" style="display: none;">
            <svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2" ry="2"></rect><line x1="9" y1="9" x2="15" y2="9"></line><line x1="9" y1="13" x2="15" y2="13"></line><line x1="9" y1="17" x2="15" y2="17"></line></svg>
            <h3>No notes found</h3>
            <p>Try refining your search terms or filter selection.</p>
        </div>
    </div>

    <script>
        let notes = ##NOTES_JSON##;

        function getCategoryBadge(type) {
            const norm = type.toLowerCase().trim();
            let cls = 'badge';
            
            if (norm === 'interview') {
                cls += ' badge-interview';
            } else if (norm === 'meeting') {
                cls += ' badge-meeting';
            } else if (norm === 'media/podcast') {
                cls += ' badge-media-podcast';
            } else {
                cls += ' badge-other';
            }
            
            return `<span class="${cls}">${type}</span>`;
        }

        function renderNotes(filteredNotes) {
            const tbody = document.getElementById('table-body');
            const emptyState = document.getElementById('empty-state');
            const countLabel = document.getElementById('note-count');
            tbody.innerHTML = '';
            
            countLabel.textContent = `${filteredNotes.length} meeting${filteredNotes.length === 1 ? '' : 's'}`;

            if (filteredNotes.length === 0) {
                document.querySelector('.table-container').style.display = 'none';
                emptyState.style.display = 'block';
                return;
            }

            document.querySelector('.table-container').style.display = 'block';
            emptyState.style.display = 'none';

            filteredNotes.forEach(note => {
                const tr = document.createElement('tr');
                const isSelf = note.attendees.toLowerCase() === 'self';
                const attendeesHtml = isSelf 
                    ? `<span style="color: #64748b; font-style: italic;">Self</span>` 
                    : `<span title="${note.attendees}">${note.attendees}</span>`;
                
                const orgHtml = note.organization === '—' 
                    ? `<span style="color: #cbd5e1;">—</span>` 
                    : `<span class="organization-text">${note.organization}</span>`;

                tr.innerHTML = `
                    <td>
                        <a class="note-title-link" href=".previews/${note.previewFilename}" target="_blank">${note.title}</a>
                    </td>
                    <td>${attendeesHtml}</td>
                    <td>${orgHtml}</td>
                    <td>${getCategoryBadge(note.conversationType)}</td>
                    <td class="date-text">${note.dateString}</td>
                    <td style="text-align: center;">
                        <button class="delete-btn" onclick="deleteNote('${note.filename}')" title="Delete note">
                            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"></polyline><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"></path><line x1="10" y1="11" x2="10" y2="17"></line><line x1="14" y1="11" x2="14" y2="17"></line></svg>
                        </button>
                    </td>
                `;
                tbody.appendChild(tr);
            });
        }

        // Search & Filter Logic
        let activeFilter = 'all';
        let searchQuery = '';

        function applySearchAndFilter() {
            const filtered = notes.filter(note => {
                // Category Filter
                let matchesCategory = false;
                if (activeFilter === 'all') {
                    matchesCategory = true;
                } else if (activeFilter === 'Other') {
                    const knownTypes = ['meeting', 'interview', 'media/podcast'];
                    matchesCategory = !knownTypes.some(kt => note.conversationType.toLowerCase() === kt);
                } else {
                    matchesCategory = note.conversationType.toLowerCase() === activeFilter.toLowerCase();
                }

                // Text Search
                const query = searchQuery.toLowerCase();
                const matchesSearch = 
                    note.title.toLowerCase().includes(query) ||
                    note.context.toLowerCase().includes(query) ||
                    note.attendees.toLowerCase().includes(query) ||
                    note.organization.toLowerCase().includes(query) ||
                    note.conversationType.toLowerCase().includes(query);

                return matchesCategory && matchesSearch;
            });

            renderNotes(filtered);
        }

        document.getElementById('search-input').addEventListener('input', (e) => {
            searchQuery = e.target.value;
            applySearchAndFilter();
        });

        const tabContainer = document.getElementById('filter-tabs');
        tabContainer.addEventListener('click', (e) => {
            if (e.target.classList.contains('filter-pill')) {
                // Toggle active class
                tabContainer.querySelectorAll('.filter-pill').forEach(pill => pill.classList.remove('active'));
                e.target.classList.add('active');

                activeFilter = e.target.getAttribute('data-filter');
                applySearchAndFilter();
            }
        });

        function deleteNote(filename) {
            if (confirm("Are you sure you want to delete this note? It will be permanently removed from disk.")) {
                const iframe = document.createElement('iframe');
                iframe.style.display = 'none';
                iframe.src = `audiologue://delete?filename=${filename}`;
                document.body.appendChild(iframe);
                
                const idx = notes.findIndex(n => n.filename === filename);
                if (idx !== -1) {
                    notes.splice(idx, 1);
                    applySearchAndFilter();
                }
                
                setTimeout(() => iframe.remove(), 1000);
            }
        }

        // Initial Render
        renderNotes(notes);
    </script>
</body>
</html>
"""#
        
        let html = htmlTemplate.replacingOccurrences(of: "##NOTES_JSON##", with: jsonString)
        try html.write(to: outputURL, atomically: true, encoding: .utf8)
    }
}

struct NoteInfo: Codable {
    let filename: String
    let title: String
    let dateString: String
    let conversationType: String
    let context: String
    let previewFilename: String
    let attendees: String
    let organization: String
}

class EditableNSTextField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown {
            let commandPressed = event.modifierFlags.contains(.command)
            if commandPressed {
                switch event.charactersIgnoringModifiers {
                case "x":
                    if NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self) { return true }
                case "c":
                    if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self) { return true }
                case "v":
                    if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self) { return true }
                case "a":
                    if NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: self) { return true }
                default:
                    break
                }
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
