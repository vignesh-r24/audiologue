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
        
        // Run migration of existing loose HTML files to .previews subfolder
        migrateExistingHTMLFiles()
        
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
                    if isPermissionError {
                        let hasPrompted = UserDefaults.standard.bool(forKey: "hasPromptedForPermissions")
                        if !hasPrompted {
                            // First run ever: system permissions prompts are active on screen.
                            // Do not show our own alert window to avoid overlapping or blocking the OS prompt.
                            UserDefaults.standard.set(true, forKey: "hasPromptedForPermissions")
                            print("[System] First-time permissions prompts active. Suppressing alert overlay.")
                        } else {
                            // Subsequent run: permissions are explicitly denied/revoked.
                            self.showErrorAlert(
                                title: "System Permissions Setup Required",
                                message: "Audiologue requires Microphone and Screen & System Audio Recording permissions to record meetings.\n\n" +
                                         "1. macOS should have prompted you to allow these. Please click 'Allow' or 'Open System Settings'.\n" +
                                         "2. Verify both permissions are enabled for 'Audiologue' in System Settings > Privacy & Security.\n" +
                                         "3. If they are already enabled but you still see this message, select 'Audiologue' in the Screen Recording settings list, click the minus '-' button to remove it, and try again."
                            )
                        }
                    } else {
                        self.showErrorAlert(
                            title: "Recording Failed",
                            message: "Could not start audio recording.\n\nError: \(errDesc)"
                        )
                    }
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
        });
    </script>
</body>
</html>
"""#
        
        let html = htmlTemplate
            .replacingOccurrences(of: "{{BASE64_MARKDOWN}}", with: base64Markdown)
            .replacingOccurrences(of: "{{USER_FIRST_NAME}}", with: userFirstName)
            .replacingOccurrences(of: "{{MEETING_DATE}}", with: displayDate)
            .replacingOccurrences(of: "{{RAW_TITLE}}", with: title)
            .replacingOccurrences(of: "{{TITLE}}", with: title)
        
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
