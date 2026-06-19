import os
import sys
import time
import argparse
import threading
import tempfile
from pathlib import Path
import config
import audio_detector

# Try to import dependencies and print helpful messages if missing
try:
    import sounddevice as sd
    import soundfile as sf
    from pydub import AudioSegment
    from google import genai
except ImportError as e:
    print(f"Error: Missing dependency. {e}")
    print("Please install required packages using:")
    print("pip install sounddevice soundfile pydub google-genai numpy")
    sys.exit(1)

# Lock to prevent concurrent PortAudio stream initialization crashes
portaudio_lock = threading.Lock()

class AudioRecorder(threading.Thread):
    """
    A thread that records audio from a specific device index
    and writes it directly to a WAV file on disk.
    """
    def __init__(self, device_index, filename, sample_rate=16000, channels=1):
        super().__init__()
        self.device_index = device_index
        self.filename = filename
        self.sample_rate = sample_rate
        self.channels = channels
        self.stop_event = threading.Event()
        self.exception = None

    def run(self):
        try:
            # We open the soundfile in write mode. 
            # 16kHz mono is standard and lightweight for speech.
            with sf.SoundFile(self.filename, mode='w', samplerate=self.sample_rate, channels=self.channels) as f:
                def callback(indata, frames, time_info, status):
                    if status:
                        print(f"[Device {self.device_index}] Status: {status}", file=sys.stderr)
                    f.write(indata)

                # Acquire the lock only while initializing and starting the InputStream to prevent PortAudio concurrency crashes
                with portaudio_lock:
                    stream = sd.InputStream(device=self.device_index, 
                                             channels=self.channels, 
                                             samplerate=self.sample_rate, 
                                             callback=callback)
                    stream.start()
                
                try:
                    while not self.stop_event.is_set():
                        self.stop_event.wait(0.1)
                finally:
                    stream.stop()
                    stream.close()
        except Exception as e:
            self.exception = e
            print(f"\n[Error on Device {self.device_index}]: {e}", file=sys.stderr)
            sys.stderr.flush()

    def stop(self):
        self.stop_event.set()

def list_audio_devices():
    """Prints all available audio devices to help select mic and system loopback."""
    print("\n=== Available Audio Devices ===")
    devices = sd.query_devices()
    for idx, dev in enumerate(devices):
        max_in = dev.get('max_input_channels', 0)
        max_out = dev.get('max_output_channels', 0)
        # We look for input-capable devices
        direction = []
        if max_in > 0: direction.append("Input")
        if max_out > 0: direction.append("Output")
        
        dir_str = "/".join(direction)
        default_str = " (Default)" if idx == sd.default.device[0] else ""
        print(f"[{idx}] {dev['name']} - {dir_str} (In Chs: {max_in}, SR: {dev['default_samplerate']}Hz){default_str}")
    print("===============================\n")

def record_meeting(mic_idx, sys_idx, duration=None, output_dir=None):
    """
    Records from microphone and system (BlackHole) concurrently, 
    mixes them, and returns the path to the mixed MP3 file.
    """
    output_dir = Path(output_dir or config.get_temp_dir())
    output_dir.mkdir(parents=True, exist_ok=True)
    
    mic_wav = output_dir / "temp_mic.wav"
    sys_wav = output_dir / "temp_sys.wav"
    mixed_mp3 = output_dir / f"meeting_{int(time.time())}.mp3"
    
    # Configure meeting routing and start background route monitor
    original_output, routed_device = audio_detector.configure_meeting_routing()
    
    print(f"\nStarting recording threads...")
    print(f"  - Mic Device Index: {mic_idx} -> Saving to {mic_wav}")
    print(f"  - System Device Index: {sys_idx} (BlackHole) -> Saving to {sys_wav}")
    
    # Instantiate recorder threads
    mic_recorder = AudioRecorder(device_index=mic_idx, filename=str(mic_wav))
    sys_recorder = AudioRecorder(device_index=sys_idx, filename=str(sys_wav))
    
    # Start recording
    mic_recorder.start()
    sys_recorder.start()
    
    print("\nRecording... Press Ctrl+C to stop.")
    
    start_time = time.time()
    try:
        if duration:
            # Record for a fixed duration
            time.sleep(duration)
        else:
            # Record indefinitely until user interrupts
            while True:
                elapsed = time.time() - start_time
                mins, secs = divmod(int(elapsed), 60)
                print(f"\rElapsed Time: {mins:02d}:{secs:02d} | Recording...", end="", flush=True)
                time.sleep(1)
    except KeyboardInterrupt:
        print("\n\nStopping recording...")
    finally:
        # Request threads to stop
        mic_recorder.stop()
        sys_recorder.stop()
        
        # Wait for threads to clean up and exit
        mic_recorder.join()
        sys_recorder.join()
        
        # Restore original audio routing and stop route monitor
        audio_detector.restore_audio_routing(original_output)
        
    print("Recording stopped. Mixing audio files...")
    
    # Verify files exist and have data
    if not mic_wav.exists() or not sys_wav.exists():
        print("Error: Temporary audio files were not successfully created.")
        sys.exit(1)
        
    try:
        # Load audio segments
        mic_segment = AudioSegment.from_wav(str(mic_wav))
        sys_segment = AudioSegment.from_wav(str(sys_wav))
        
        # Normalize audio levels (boost quiet speakers, level out the mix)
        # Avoid normalizing if silent to prevent loud static hiss
        if mic_segment.max > 0:
            mic_segment = mic_segment.normalize()
        if sys_segment.max > 0:
            sys_segment = sys_segment.normalize()
            
        # Mix system and mic stream (overlay)
        mixed_segment = mic_segment.overlay(sys_segment)
        
        # Export as MP3 (mono, 16kHz, 64kbps is perfect for clear voice and small size)
        mixed_segment.export(str(mixed_mp3), format="mp3", bitrate="64k")
        print(f"Audio mixed successfully: {mixed_mp3} ({mixed_mp3.stat().st_size / 1024 / 1024:.2f} MB)")
        
        # Clean up temporary WAV files
        mic_wav.unlink()
        sys_wav.unlink()
        
        return mixed_mp3
        
    except Exception as e:
        print(f"Error during mixing: {e}")
        print("Raw WAV files have been preserved for recovery:")
        print(f"  - Mic WAV: {mic_wav}")
        print(f"  - System WAV: {sys_wav}")
        sys.exit(1)

def run_gemini_analysis(audio_path, api_key, on_upload=None):
    """
    Uploads audio file to Gemini File API, requests transcription/summary,
    and returns the markdown notes.
    """
    client = genai.Client(api_key=api_key)
    
    # Upload the file
    audio_file = client.files.upload(file=str(audio_path))
    print(f"Uploaded successfully. File name on Gemini API: {audio_file.name}")
    if on_upload:
        try:
            on_upload(client, audio_file.name)
        except Exception as e:
            print(f"Warning: on_upload callback failed: {e}", file=sys.stderr)
    print("Waiting for transcription and summary (this may take a few minutes)...")
    
    try:
        system_prompt = """
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
        Note 2-3 moments where the user could have been more concise, structured, or direct. Include the approximate timestamp or context, what was said, and a tighter alternative. Focus on patterns like: unnecessary preamble, mid-sentence restarts, over-long answers, or talking when they should have been listening.

        ---

        ## Transcript
        Provide a chronological, verbatim, diarized transcript. Identify speakers by name where possible using context clues. Format as:

        **[Speaker Name]:** [Verbatim speech]

        Use paragraph breaks between speakers. Do not merge multiple speakers into one block.
        """
        
        max_retries = 3
        for attempt in range(max_retries):
            try:
                response = client.models.generate_content(
                    model="gemini-2.5-flash",
                    contents=[audio_file, system_prompt],
                    config={"temperature": 0.0}
                )
                print("Analysis complete!")
                return response.text
            except Exception as e:
                if attempt < max_retries - 1:
                    wait_time = 2 ** (attempt + 1)
                    print(f"\n[Warning] Gemini API unavailable/busy. Retrying in {wait_time}s (Attempt {attempt + 1}/{max_retries})...")
                    time.sleep(wait_time)
                else:
                    raise e
        
    finally:
        # Clean up file on Google servers to maintain privacy
        print("Deleting file from Gemini File API servers...")
        try:
            client.files.delete(name=audio_file.name)
            print("File deleted from API successfully.")
        except Exception as e:
            print(f"Warning: Failed to delete remote file: {e}")

def get_auto_device_indexes():
    """
    Attempts to locate the device indexes for the active microphone and BlackHole.
    Returns (mic_idx, sys_idx) or raises ValueError if not found.
    """
    devices = sd.query_devices()
    mic_idx = None
    sys_idx = None
    
    # 1. Find BlackHole
    for idx, dev in enumerate(devices):
        if dev['max_input_channels'] > 0 and "blackhole" in dev['name'].lower():
            sys_idx = idx
            break
            
    # 2. Find active microphone matching macOS default active input
    try:
        active_input_name = audio_detector.get_active_input()
        for idx, dev in enumerate(devices):
            if dev['max_input_channels'] > 0 and active_input_name in dev['name']:
                mic_idx = idx
                break
    except Exception as e:
        print(f"Warning: Failed to query active input via SwitchAudioSource: {e}", file=sys.stderr)
        sys.stderr.flush()
                
    # Fallback to the system default input device
    if mic_idx is None:
        default_in = sd.default.device[0]
        if default_in >= 0:
            mic_idx = default_in
        else:
            # Last resort: find first input-capable device
            for idx, dev in enumerate(devices):
                if dev['max_input_channels'] > 0:
                    mic_idx = idx
                    break
                    
    if sys_idx is None:
        raise ValueError("Could not automatically locate 'BlackHole 2ch' input device. Is it installed?")
    if mic_idx is None:
        raise ValueError("Could not locate any active microphone input device.")
        
    return mic_idx, sys_idx

def main():
    parser = argparse.ArgumentParser(description="Record meetings (mic + system) and transcribe/summarize with Gemini.")
    parser.add_argument("--list", action="store_true", help="List all available audio devices and exit")
    parser.add_argument("--mic", type=int, help="Device index for your active Microphone (optional, auto-detected)")
    parser.add_argument("--sys", type=int, help="Device index for BlackHole (optional, auto-detected)")
    parser.add_argument("--duration", type=int, help="Fixed duration to record (seconds). If omitted, records until Ctrl+C.")
    parser.add_argument("--out-dir", type=str, default=str(config.get_temp_dir()),
                        help="Directory to save temporary/output audio files")
    parser.add_argument("--notes-dir", type=str, default=str(config.get_notes_dir()),
                        help="Directory to save final markdown notes")
    
    args = parser.parse_args()
    
    if args.list:
        list_audio_devices()
        return

    # Check for Gemini API Key
    api_key = config.get_api_key()
    if not api_key:
        print("Error: Gemini API Key is not set in your macOS Keychain or environment.")
        print("Please run: python setup_key.py")
        sys.exit(1)

    # Auto-resolve device indexes if not provided
    mic_idx = args.mic
    sys_idx = args.sys
    if mic_idx is None or sys_idx is None:
        try:
            auto_mic, auto_sys = get_auto_device_indexes()
            if mic_idx is None:
                mic_idx = auto_mic
            if sys_idx is None:
                sys_idx = auto_sys
            print(f"Auto-detected devices:")
            print(f"  - Microphone: Index {mic_idx} ({sd.query_devices(mic_idx)['name']})")
            print(f"  - System Audio (BlackHole): Index {sys_idx} ({sd.query_devices(sys_idx)['name']})")
        except Exception as e:
            print(f"Error auto-detecting devices: {e}")
            list_audio_devices()
            print("Please specify device indexes manually using --mic and --sys parameters.")
            sys.exit(1)

    # 1. Record the meeting
    audio_path = record_meeting(
        mic_idx=mic_idx, 
        sys_idx=sys_idx, 
        duration=args.duration, 
        output_dir=args.out_dir
    )
    
    # 2. Transcribe and summarize
    try:
        notes_md = run_gemini_analysis(audio_path, api_key)
        
        # 3. Save notes to file
        notes_dir = Path(args.notes_dir)
        notes_dir.mkdir(parents=True, exist_ok=True)
        
        timestamp = time.strftime("%Y-%m-%d_%H-%M")
        notes_path = notes_dir / f"{timestamp}.md"
        
        with open(notes_path, "w", encoding="utf-8") as f:
            f.write(notes_md)
            
        print(f"\nSuccess! Meeting notes saved to: {notes_path}")
        
        # Clean up local MP3
        if audio_path.exists():
            audio_path.unlink()
            print("Temporary MP3 file deleted.")
            
    except Exception as e:
        print(f"\nError processing with Gemini API: {e}")
        print(f"Your recording has been saved for manual recovery at: {audio_path}")

if __name__ == "__main__":
    main()
