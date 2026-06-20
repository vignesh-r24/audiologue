# Audiologue

A lightweight, native macOS status bar application that records system audio and microphone input concurrently, transcribes and summarizes the dialogue using Google's Gemini Flash API, and saves structured meeting notes locally.

Now rewritten entirely in **native Swift**, Audiologue operates with zero third-party dependencies—no virtual loopback audio drivers (like BlackHole) or system audio switches required.

---

## Features
* 🎙️ **Direct Audio Capture**: Uses Apple's native **ScreenCaptureKit** to capture system audio (e.g., Zoom, Teams, Webex, or browser calls) directly at the OS level.
* 🔊 **Working Volume Keys**: System volume controls and keyboard volume keys function perfectly during active recordings (no locked controls or "prohibit" signs).
* ☁️ **Cloud-Powered AI**: Offloads transcription, speaker diarization, and executive summaries to Google's Gemini File API (using your own free API key), consuming 0% local CPU/RAM for the heavy lifting.
* 🔒 **Local Privacy**: Automatically cleans up temporary local files and deletes remote audio files from Google's servers immediately after generating meeting summaries.
* 📦 **Zero Dependencies**: Does not require BlackHole, Homebrew, SwitchAudioSource, or Python virtual environments. 
* ⚡ **Ultra-Lightweight**: Compiles to a native Cocoa binary of just **~3 MB** that launches instantly and uses less than 1% CPU.
* 🔄 **Smart Model Fallback**: Automatically loops through `gemini-3.5-flash` -> `gemini-3-flash` -> `gemini-2.5-flash` on rate-limit (429) errors, tripling your available daily free requests (up to 60/day).
* 👤 **Dynamic Speaker Labeling**: Injects your macOS account name dynamically into the prompt to label your transcript turns by name, while automatically detecting other speaker names from conversation context.

---

## 1. Setup & Installation

1. Clone this repository:
   ```bash
   git clone https://github.com/vignesh-r24/audiologue.git
   cd audiologue
   ```

2. Compile and install the app directly to `/Applications/`:
   ```bash
   ./build.sh
   ```

3. Open **Spotlight** (`Cmd + Space`), type **"Audiologue"**, and press Enter to launch the app!

---

## 2. Configuration & Permissions

### API Key Configuration
1. Click the Audiologue soundwave icon in the menu bar.
2. Select **Set Gemini API Key**.
3. Paste your Gemini API key (you can generate one for free in [Google AI Studio](https://aistudio.google.com/)).
   * *Note: Your key is securely stored in your native macOS Keychain.*

### macOS Permissions
When you click **Start Recording** for the first time, macOS will ask for two permissions:
1. **Microphone Access**: Required to record your own voice.
2. **Screen & System Audio Recording**: Required to capture system audio (incoming speaker voices).
   * *Important: Although Apple labels this popup "Screen Recording", Audiologue explicitly configures ScreenCaptureKit to capture **audio only**. No video or screen pixel data is ever read, processed, or saved.*

---

## 3. How to Use

### Menu Bar Operations
1. Click the status bar icon.
2. Select **Start Recording** when your meeting begins. The icon status will update to show `[R]` (Recording) in the menu bar, accompanied by macOS's native purple recording indicator.
3. Select **Stop Recording** when the meeting ends. The status will update to `[P]` (Processing) while it mixes the audio channels, uploads it to the Gemini File API, and generates your notes.
4. Once completed, the note will **automatically open in TextEdit**!
5. Access your last 5 notes directly from the **Recent Notes** submenu, or select **Open Notes Folder** to view them in Finder.

---

## File Locations
* **Meeting Notes (.md)**: Saved under `~/Library/Application Support/Audiologue/MeetingNotes/`
* **Temporary Files**: Saved under the system temporary directory and securely deleted immediately after processing.
