import os
import sys
import threading
import time
import subprocess
from pathlib import Path

# Inject Homebrew path so pydub and subprocess can always locate ffmpeg/SwitchAudioSource
os.environ["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + os.environ.get("PATH", "")

try:
    import objc
    # Crucial for PyObjC thread-safety when running background threads (like sounddevice/PortAudio)
    objc.initThreading()
except Exception as e:
    print(f"Warning: Could not initialize PyObjC threading: {e}", file=sys.stderr)
    sys.stderr.flush()

try:
    import rumps
    import config
    import audio_detector
    import recorder
except ImportError as e:
    print(f"Error: Missing UI dependency. {e}")
    print("Please install requirements using:")
    print("pip install rumps")
    sys.exit(1)

class AudiologueApp(rumps.App):
    def __init__(self):
        # Resolve absolute path to the monochrome soundwave template icon
        icon_path = str(Path(__file__).parent / "icon.png")
        # Disable the default quit button to force our custom cleanup quit handler
        super().__init__("Audiologue", icon=icon_path, template=True, quit_button=None)
        
        # Hide the Python process icon from the Dock by setting activation policy to Accessory
        try:
            from AppKit import NSApplication, NSApplicationActivationPolicyAccessory
            NSApplication.sharedApplication().setActivationPolicy_(NSApplicationActivationPolicyAccessory)
        except Exception as e:
            print(f"Warning: Could not set Dock activation policy: {e}", file=sys.stderr)
            sys.stderr.flush()
        
        # Menu structure setup
        self.status_item = rumps.MenuItem("Status: Idle", callback=None)
        
        self.toggle_item = rumps.MenuItem("Start Recording", callback=self.on_toggle_click)
        self.open_folder_item = rumps.MenuItem("Open Notes Folder", callback=self.on_open_folder)
        self.config_key_item = rumps.MenuItem("Configure API Key", callback=self.on_config_key)
        self.quit_item = rumps.MenuItem("Quit", callback=self.on_quit)
        
        self.menu = [
            self.status_item,
            rumps.separator,
            self.toggle_item,
            self.open_folder_item,
            ("Recent Notes", ["No notes found"]), # Initialize as a nested list so rumps creates a submenu
            self.config_key_item,
            rumps.separator,
            self.quit_item
        ]
        
        # Get a reference to the dynamically populated submenu
        self.recent_menu = self.menu["Recent Notes"]
        
        # State tracking
        self.is_recording = False
        self.is_processing = False
        
        # Threads & references
        self.mic_recorder = None
        self.sys_recorder = None
        self.mic_wav = None
        self.sys_wav = None
        self.original_output = None
        
        # Active Gemini upload tracking for graceful shutdown cleanup
        self.gemini_client = None
        self.active_gemini_file_name = None
        
        # Run startup sweep to clear leftover temp files
        self.config_temp_cleanup()
        
        # Populate the recent notes list
        self.update_recent_menu()
        
        # Register signal handlers for SIGINT and SIGTERM for graceful exit and cleanup
        import signal
        try:
            signal.signal(signal.SIGINT, self.graceful_shutdown_handler)
            signal.signal(signal.SIGTERM, self.graceful_shutdown_handler)
        except ValueError as e:
            print(f"Warning: Could not register signal handlers: {e}", file=sys.stderr)
            sys.stderr.flush()
            
        # Register Cocoa notification observer for application termination
        try:
            from AppKit import NSNotificationCenter, NSApplicationWillTerminateNotification
            NSNotificationCenter.defaultCenter().addObserver_selector_name_object_(
                self,
                "applicationWillTerminate:",
                NSApplicationWillTerminateNotification,
                None
            )
        except Exception as e:
            print(f"Warning: Could not register Cocoa termination observer: {e}", file=sys.stderr)
            sys.stderr.flush()
        
        # Start a background thread to listen for terminal input (fallback to stop recording)
        threading.Thread(target=self._terminal_input_listener, daemon=True).start()

    def run_on_main_thread(self, func, *args, **kwargs):
        """
        Safely schedules a function to be executed on the AppKit (Cocoa) main thread.
        Uses PyObjCTools.AppHelper.callAfter to ensure thread-safety and avoid crashes.
        """
        from PyObjCTools import AppHelper
        AppHelper.callAfter(func, *args, **kwargs)

    def _terminal_input_listener(self):
        """
        Listens to terminal stdin in the background.
        Provides a robust fallback to stop recording by pressing Enter in the terminal
        if the status bar icon becomes hidden due to macOS notch/overflow.
        """
        # Give the app a moment to print initial startup logs
        time.sleep(1.0)
        print("\n=== Audiologue Console Control ===")
        print("Fallback: If the menu bar icon is hidden/missing, press ENTER here to stop recording.")
        print("==================================\n", flush=True)
        
        while True:
            try:
                line = sys.stdin.readline()
                if not line:
                    break # EOF
                
                # Check status and perform appropriate action
                if self.is_recording:
                    print("\n[Terminal Fallback] Stop command received. Scheduling recording stop on main thread...", flush=True)
                    self.run_on_main_thread(self.stop_recording_workflow)
                elif self.is_processing:
                    print("[Terminal Fallback] Application is currently busy processing meeting notes...", flush=True)
                else:
                    print("[Terminal Fallback] Application is idle. Click the menu bar icon or press Enter when recording to stop.", flush=True)
            except Exception as e:
                print(f"[Error in terminal listener]: {e}", file=sys.stderr)
                sys.stderr.flush()
                break

    def config_temp_cleanup(self):
        """
        Startup sweep to delete any leftover audio files (e.g. .wav or .mp3) 
        from previously crashed runs to avoid privacy leaks.
        """
        try:
            temp_dir = config.get_temp_dir()
            if temp_dir.exists():
                for item in temp_dir.iterdir():
                    if item.is_file() and item.suffix.lower() in ('.wav', '.mp3'):
                        try:
                            item.unlink()
                            print(f"[Startup Sweep] Cleaned up orphaned file: {item}")
                        except Exception as e:
                            print(f"[Startup Sweep Warning] Failed to delete {item}: {e}", file=sys.stderr)
        except Exception as e:
            print(f"[Startup Sweep Error] Failed to complete startup sweep: {e}", file=sys.stderr)
            sys.stderr.flush()

    def update_recent_menu(self):
        """Scans the notes directory and updates the 'Recent Notes' submenu with the top 5 most recent files."""
        try:
            self.recent_menu.clear()
            notes_dir = config.get_notes_dir()
            if not notes_dir.exists():
                self.recent_menu.add(rumps.MenuItem("No notes found", callback=None))
                return
                
            # Find all markdown files, sort by modification time descending
            md_files = sorted(
                [f for f in notes_dir.iterdir() if f.is_file() and f.suffix.lower() == '.md'],
                key=lambda x: x.stat().st_mtime,
                reverse=True
            )
            
            recent_files = md_files[:5]
            if not recent_files:
                self.recent_menu.add(rumps.MenuItem("No notes found", callback=None))
                return
                
            today_str = time.strftime("%Y-%m-%d")
            for file_path in recent_files:
                name_without_ext = file_path.stem
                parts = name_without_ext.split("_", 2)
                
                date_part = ""
                time_part = ""
                title_part = ""
                
                if len(parts) == 3:
                    date_part, time_part, title_part = parts
                elif len(parts) == 2:
                    date_part, time_part = parts
                else:
                    date_part = today_str
                    time_part = "00-00"
                    title_part = name_without_ext
                
                # Format time
                time_formatted = time_part.replace("-", ":")
                
                # Format date if before today
                if date_part != today_str:
                    date_split = date_part.split("-")
                    if len(date_split) == 3:
                        mm_dd = f"{date_split[1]}/{date_split[2]}"
                    else:
                        mm_dd = date_part
                    time_prefix = f"{mm_dd} - {time_formatted}"
                else:
                    time_prefix = time_formatted
                
                # Format title
                if title_part:
                    title_formatted = title_part.replace("_", " ")
                    display_title = f"{time_prefix} | {title_formatted}"
                else:
                    display_title = time_prefix
                    
                item = rumps.MenuItem(display_title, callback=self.on_open_recent_note)
                item.file_path = str(file_path)
                self.recent_menu.add(item)
        except Exception as e:
            print(f"Error updating recent notes menu: {e}", file=sys.stderr)
            sys.stderr.flush()

    def on_open_recent_note(self, sender):
        """Callback to open a selected note from the recent menu in TextEdit."""
        file_path = getattr(sender, 'file_path', None)
        if file_path:
            print(f"[Menu] Opening note in TextEdit: {file_path}", flush=True)
            subprocess.run(["open", "-a", "TextEdit", file_path])

    def graceful_shutdown_handler(self, signum, frame):
        """
        Intercepts termination signals (SIGINT, SIGTERM) or quit events to stop recorders,
        restore audio routing, sweep local temp files, delete active Gemini files,
        and exit cleanly.
        """
        if signum is not None:
            print(f"\n[Shutdown] Received termination signal ({signum}). Starting graceful cleanup...")
        else:
            print(f"\n[Shutdown] Quit requested from menu. Starting graceful cleanup...")
        
        # 1. Stop recording if active
        if self.is_recording:
            print("[Shutdown] Stopping active recorders...")
            if self.mic_recorder:
                try:
                    self.mic_recorder.stop()
                except Exception:
                    pass
            if self.sys_recorder:
                try:
                    self.sys_recorder.stop()
                except Exception:
                    pass
        
        # 2. Restore default audio routing immediately
        if self.original_output:
            print(f"[Shutdown] Restoring original audio routing: {self.original_output}")
            try:
                audio_detector.restore_audio_routing(self.original_output)
            except Exception as e:
                print(f"[Shutdown Error] Failed to restore audio routing: {e}", file=sys.stderr)
        
        # 3. Clean up active Gemini API files
        if self.gemini_client and self.active_gemini_file_name:
            print(f"[Shutdown] Deleting remote file from Gemini API: {self.active_gemini_file_name}")
            try:
                self.gemini_client.files.delete(name=self.active_gemini_file_name)
                print("[Shutdown] Remote file deleted successfully.")
            except Exception as e:
                print(f"[Shutdown Warning] Failed to delete remote file: {e}", file=sys.stderr)
                
        # 4. Sweep local temporary directory
        print("[Shutdown] Performing sweep of temporary directory...")
        try:
            temp_dir = config.get_temp_dir()
            if temp_dir.exists():
                for item in temp_dir.iterdir():
                    if item.is_file() and item.suffix.lower() in ('.wav', '.mp3'):
                        try:
                            item.unlink()
                            print(f"[Shutdown Clean] Deleted local temp file: {item}")
                        except Exception:
                            pass
        except Exception as e:
            print(f"[Shutdown Error] Temporary directory sweep failed: {e}", file=sys.stderr)
            
        sys.stderr.flush()
        print("[Shutdown] Graceful cleanup complete. Exiting.", flush=True)
        # Force immediate exit to prevent PyObjC from hanging the terminal
        os._exit(0)

    def applicationWillTerminate_(self, notification):
        """
        Cocoa notification callback triggered when the application is about to terminate.
        """
        self.graceful_shutdown_handler(None, None)

    def on_toggle_click(self, sender):
        """Main state-toggling logic."""
        if self.is_processing:
            print("[Warning] App Busy: Currently processing previous notes.")
            return

        if not self.is_recording:
            self.start_recording_workflow()
        else:
            self.stop_recording_workflow()

    def start_recording_workflow(self):
        # Verify API Key is configured before starting
        api_key = config.get_api_key()
        if not api_key:
            print("[Error] Gemini API Key is missing. Please set it in the config menu.")
            self.on_config_key(None)
            return

        print("\nStarting meeting recording session...")
        self.is_recording = True
        self.title = "[R]" # Keep it tiny during recording
        self.status_item.title = "Status: Recording..."
        self.toggle_item.title = "Stop Recording"
        
        # Run recording initialization in a separate thread so UI does not freeze
        threading.Thread(target=self._async_start_recording, daemon=True).start()

    def _async_start_recording(self):
        try:
            # Create temp directories
            temp_dir = config.get_temp_dir()
            self.mic_wav = temp_dir / "temp_mic.wav"
            self.sys_wav = temp_dir / "temp_sys.wav"
            
            # Configure route/monitor
            self.original_output, _ = audio_detector.configure_meeting_routing()
            
            # CRITICAL: Pause for 1.5 seconds. When the audio device is swapped,
            # macOS CoreAudio takes up to a second to rebuild the audio hardware context.
            # Trying to open PortAudio streams immediately causes device busy errors or crashes.
            time.sleep(1.5)
            
            # Auto-resolve device indexes (runs after routing is active so indexes are correct)
            mic_idx, sys_idx = recorder.get_auto_device_indexes()
            
            # Create sounddevice streams
            self.mic_recorder = recorder.AudioRecorder(device_index=mic_idx, filename=str(self.mic_wav))
            self.sys_recorder = recorder.AudioRecorder(device_index=sys_idx, filename=str(self.sys_wav))
            
            # Start stream capture threads
            self.mic_recorder.start()
            self.sys_recorder.start()
            
            print("[System] Recording Started successfully. Capturing mic and system loopback...", flush=True)
            
        except Exception as e:
            print(f"[Error] Failed to start recording: {e}", file=sys.stderr)
            sys.stderr.flush()
            self.run_on_main_thread(self.reset_ui_state)

    def stop_recording_workflow(self):
        print("\nStopping meeting recording session...")
        self.is_recording = False
        self.is_processing = True
        self.title = "[P]" # Keep it tiny during processing
        self.status_item.title = "Status: Processing..."
        self.toggle_item.title = "Processing Notes..."
        
        # Stop recorders immediately to free audio devices
        if self.mic_recorder:
            self.mic_recorder.stop()
        if self.sys_recorder:
            self.sys_recorder.stop()
            
        # Restore default system audio routing
        if self.original_output:
            audio_detector.restore_audio_routing(self.original_output)

        # Offload file mixing and Gemini upload to background thread to avoid beachballing macOS
        threading.Thread(target=self._async_processing_pipeline, daemon=True).start()

    def _async_processing_pipeline(self):
        mixed_mp3 = None
        try:
            # Wait for recorders to save final audio blocks
            if self.mic_recorder:
                self.mic_recorder.join()
            if self.sys_recorder:
                self.sys_recorder.join()
                
            print("Audio streams stopped. Mixing channels...")
            
            # Output file paths
            temp_dir = config.get_temp_dir()
            mixed_mp3 = temp_dir / f"meeting_{int(time.time())}.mp3"
            
            # Mix & Normalize
            mic_segment = recorder.AudioSegment.from_wav(str(self.mic_wav))
            sys_segment = recorder.AudioSegment.from_wav(str(self.sys_wav))
            
            # Check if both audio streams are completely silent (indicates permission denial or no source audio)
            if mic_segment.max <= 5 and sys_segment.max <= 5:
                print("[Warning] Captured audio is completely silent. Microphone permission might be missing.", flush=True)
                self.run_on_main_thread(
                    rumps.alert,
                    "No Audio Captured",
                    "The recording is completely silent. Please verify that:\n\n"
                    "1. Your Terminal (or the Audiologue app) has Microphone permissions enabled in macOS System Settings -> Privacy & Security -> Microphone.\n"
                    "2. Your microphone and system speakers are active and producing audio during the recording."
                )
                return
            
            if mic_segment.max > 0:
                mic_segment = mic_segment.normalize()
            if sys_segment.max > 0:
                sys_segment = sys_segment.normalize()
                
            mixed = mic_segment.overlay(sys_segment)
            mixed.export(str(mixed_mp3), format="mp3", bitrate="64k")
            
            # Clean up raw WAVs immediately
            if self.mic_wav and self.mic_wav.exists():
                self.mic_wav.unlink()
            if self.sys_wav and self.sys_wav.exists():
                self.sys_wav.unlink()
            
            print("Uploading MP3 to Gemini API for processing...")
            # Retrieve transcript & summary
            api_key = config.get_api_key()
            
            # Setup active upload tracking
            def on_upload(client, filename):
                self.gemini_client = client
                self.active_gemini_file_name = filename
                
            notes_md = recorder.run_gemini_analysis(mixed_mp3, api_key, on_upload=on_upload)
            
            # Parse title from Gemini response
            lines = notes_md.splitlines()
            meeting_title = "Untitled Meeting"
            if lines and lines[0].startswith("Meeting Title:"):
                raw_title = lines[0].replace("Meeting Title:", "").strip()
                if raw_title:
                    meeting_title = raw_title
                skip_lines = 2 if len(lines) > 1 and not lines[1].strip() else 1
                notes_md = "\n".join(lines[skip_lines:])
            
            # Sanitize meeting_title for filename
            sanitized_title = "".join(c if c.isalnum() or c in ("-", "_") else "_" for c in meeting_title)
            while "__" in sanitized_title:
                sanitized_title = sanitized_title.replace("__", "_")
            sanitized_title = sanitized_title.strip("_")
            
            # Save notes to local Markdown file
            notes_dir = config.get_notes_dir()
            timestamp = time.strftime("%Y-%m-%d_%H-%M")
            notes_path = notes_dir / f"{timestamp}_{sanitized_title}.md"
            
            with open(notes_path, "w", encoding="utf-8") as f:
                f.write(notes_md)
                
            # Clear active upload tracking since it completed successfully
            self.gemini_client = None
            self.active_gemini_file_name = None
            
            # Clean up local MP3
            if mixed_mp3 and mixed_mp3.exists():
                mixed_mp3.unlink()
            
            print(f"[System] Notes saved successfully: {notes_path}")
            
            # Dynamically refresh the recent notes menu to include this new note (must run on main thread)
            self.run_on_main_thread(self.update_recent_menu)
            
        except Exception as e:
            print(f"[Error] Processing pipeline failed: {e}", file=sys.stderr)
            sys.stderr.flush()
            # Rescue the mixed MP3 file to the notes folder so the audio recording is not lost
            try:
                if mixed_mp3 and mixed_mp3.exists():
                    notes_dir = config.get_notes_dir()
                    timestamp = time.strftime("%Y-%m-%d_%H-%M")
                    recovery_path = notes_dir / f"Failed_Transcription_{timestamp}.mp3"
                    import shutil
                    shutil.move(str(mixed_mp3), str(recovery_path))
                    print(f"[Recovery] Saved meeting audio to: {recovery_path}", flush=True)
                    self.run_on_main_thread(
                        rumps.alert,
                        "Transcription Failed",
                        f"The Gemini transcription/summary failed, but your meeting audio was successfully saved to your notes folder as:\n\n"
                        f"{recovery_path.name}\n\n"
                        f"Error: {e}"
                    )
            except Exception as recovery_error:
                print(f"[Recovery Error] Failed to rescue audio recording: {recovery_error}", file=sys.stderr)
                sys.stderr.flush()
            
        finally:
            # Clean up raw WAVs if they still exist due to errors
            if self.mic_wav and self.mic_wav.exists():
                try:
                    self.mic_wav.unlink()
                except Exception:
                    pass
            if self.sys_wav and self.sys_wav.exists():
                try:
                    self.sys_wav.unlink()
                except Exception:
                    pass
            # Clean up local MP3 if it still exists due to errors
            if mixed_mp3 and mixed_mp3.exists():
                try:
                    mixed_mp3.unlink()
                except Exception:
                    pass
            
            # Ensure upload tracking state is reset
            self.gemini_client = None
            self.active_gemini_file_name = None
            
            # Safely restore UI on the main thread
            self.run_on_main_thread(self.reset_ui_state)

    def reset_ui_state(self):
        """Restores UI settings back to default Idle state. (Must run on main thread)"""
        self.is_recording = False
        self.is_processing = False
        self.title = None
        self.status_item.title = "Status: Idle"
        self.toggle_item.title = "Start Recording"

    def on_open_folder(self, sender):
        """Opens the meeting notes folder in Finder."""
        notes_dir = config.get_notes_dir()
        subprocess.run(["open", str(notes_dir)])

    def on_config_key(self, sender):
        """Prompts for and securely saves the Gemini API key in Keychain."""
        current_key = config.get_api_key()
        masked_key = current_key[:6] + "..." + current_key[-4:] if len(current_key) > 10 else ""
        
        window = rumps.Window(
            message=f"Enter your Gemini API Key (current: {masked_key}):",
            title="Configure Credentials",
            cancel=True
        )
        window.add_button("Save")
        response = window.run()
        
        if response.clicked == 1: # Save clicked
            new_key = response.text.strip()
            if new_key:
                if config.save_api_key(new_key):
                    rumps.alert("Success", "API Key saved securely to macOS Keychain!")
                else:
                    rumps.alert("Error", "Failed to save key to Keychain.")

    def on_quit(self, sender):
        """Quit callback to perform full cleanup before termination."""
        self.graceful_shutdown_handler(None, None)

if __name__ == "__main__":
    # Enable debug mode to print PyObjC/AppKit errors in terminal
    rumps.debug_mode(True)
    app = AudiologueApp()
    app.run()
