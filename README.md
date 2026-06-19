# Audiologue

A lightweight, premium macOS status bar application that records system audio and microphone input concurrently, mixes them, transcribes and summarizes the dialogue using Google's Gemini 2.5 Flash API, and saves structured meeting notes locally.

Designed to live natively in your macOS menu bar with a clean, monochrome status bar icon.

---

## Features
* 🎙️ **Dual-Channel Recording**: Captures your microphone and system audio (e.g. Zoom, Teams, Webex) simultaneously using a virtual loopback driver.
* ☁️ **Cloud-Powered AI**: Offloads transcription, speaker diarization, and executive summaries to Google's Gemini File API (using your own free API key), consuming 0% local CPU/RAM for the heavy lifting.
* 💾 **Disk Streaming**: Writes raw audio streams directly to disk during the meeting, ensuring minimal memory footprint (~40-50 MB RAM) regardless of meeting duration.
* 🔒 **Local Privacy**: Automatically cleans up temporary local files and deletes remote audio files from Google's servers immediately after generating meeting summaries.
* 📊 **Smart Mixing**: Automatically normalizes and overlays both audio tracks into a lightweight, clear MP3 file post-meeting.
* 🚀 **Spotlight Integration**: Packageable as a tiny, lightweight launcher app for instant launching via Spotlight search.

---

## 1. System Dependencies (macOS)

Audiologue relies on Homebrew for essential audio routing utilities. Open your terminal and run:

```bash
# Install SwitchAudioSource, BlackHole loopback driver, and FFmpeg for audio mixing
brew install switchaudio-osx blackhole-2ch ffmpeg
```

---

## 2. Audio MIDI Configuration

To record system audio (incoming meeting voices) without losing the ability to hear the meeting in your headphones or speakers, you must configure **Multi-Output Devices** in macOS:

1. Open the **Audio MIDI Setup** app (Applications > Utilities > Audio MIDI Setup).
2. Click the `+` button in the bottom-left corner and select **Create Multi-Output Device**.
3. Double-click its name in the sidebar and rename it exactly: **`Meeting-Speakers`**
4. Check the box for **MacBook Air Speakers** (or your internal speakers) **AND** the box for **BlackHole 2ch**. Make sure the built-in speaker is set as the *Master Device*.
5. (Optional - For AirPods users) Click the `+` button again, select **Create Multi-Output Device**, and rename it exactly: **`Meeting-AirPods`**
6. Check the box for your **AirPods** **AND** the box for **BlackHole 2ch**. Make sure the AirPods are set as the *Master Device*.

*Note: Audiologue automatically detects when you connect or disconnect AirPods during a meeting and seamlessly swaps system output between `Meeting-Speakers` and `Meeting-AirPods`.*

---

## 3. Python Installation & Setup

1. Clone this repository:
   ```bash
   git clone https://github.com/vignesh-r24/audiologue.git
   cd audiologue
   ```

2. Create a Python virtual environment and activate it:
   ```bash
   python -m venv venv
   source venv/bin/activate
   ```

3. Install requirements:
   ```bash
   pip install -r requirements.txt
   ```

4. Configure your Gemini API Key:
   Run the secure setup script to save your key securely in the **macOS Keychain**:
   ```bash
   python setup_key.py
   ```

---

## 4. How to Use

### Launching the Status Bar App
Start the app inside your virtual environment:
```bash
python app.py
```
A custom **monochrome soundwave icon** will appear in your menu bar. 

### Menu Bar Operations
1. Click the status bar icon.
2. Select **Start Recording** when your meeting begins. The icon status will update to show `[R]` (Recording).
3. Select **Stop Recording** when the meeting ends. The status updates to `[P]` (Processing) while it mixes audio, uploads it to Gemini, and generates notes.
4. Select **Open Notes Folder** to open `~/Library/Application Support/Audiologue/MeetingNotes` in Finder where your structured Markdown summary and verbatim diarized transcript are saved.

### Terminal Fallback Control
If your menu bar becomes crowded (due to the camera notch or many active icons) and macOS temporarily hides the status icon, you can simply focus your terminal window and **press the ENTER key**. The background listener thread will safely capture the command and stop/save the recording.

---

## 5. Spotlight Integration & Standalone App

Instead of leaving a terminal window open or manually compiling files, you can build and install a standalone macOS application bundle that runs quietly as a background status bar item:

1. Package and install the app to `/Applications`:
   ```bash
   ./build.sh
   ```
2. Now, simply press `Cmd + Space`, search **"Audiologue"**, and press Enter to launch the app natively!

