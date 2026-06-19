import subprocess
import shutil
import threading
import time
from pathlib import Path

# Path to SwitchAudioSource (check typical Homebrew paths first)
SWITCH_AUDIO_BIN = "/opt/homebrew/bin/SwitchAudioSource"

# Global monitor reference
_route_monitor = None

def get_switch_audio_path() -> str:
    """Returns the available path to SwitchAudioSource binary."""
    if Path(SWITCH_AUDIO_BIN).exists():
        return SWITCH_AUDIO_BIN
    # Fallback to system PATH search
    path_in_env = shutil.which("SwitchAudioSource")
    if path_in_env:
        return path_in_env
    raise FileNotFoundError("SwitchAudioSource binary was not found on your system. Please ensure switchaudio-osx is installed via Homebrew.")

def run_switch_audio_cmd(args: list) -> str:
    """Helper to execute SwitchAudioSource with arguments and return output."""
    binary_path = get_switch_audio_path()
    try:
        result = subprocess.run(
            [binary_path] + args,
            capture_output=True,
            text=True,
            check=True
        )
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"SwitchAudioSource failed (exit {e.returncode}): {e.stderr.strip()}")

def get_active_output() -> str:
    """Returns the current active audio output device name."""
    return run_switch_audio_cmd(["-c", "-t", "output"])

def get_active_input() -> str:
    """Returns the current active audio input device name."""
    return run_switch_audio_cmd(["-c", "-t", "input"])

def set_active_output(device_name: str):
    """Sets the active system audio output to the specified device."""
    run_switch_audio_cmd(["-s", device_name, "-t", "output"])

def get_available_outputs() -> list:
    """Returns a list of all available audio output devices."""
    outputs_raw = run_switch_audio_cmd(["-a", "-t", "output"])
    return [line.strip() for line in outputs_raw.split("\n") if line.strip()]


class AudioRouteMonitor(threading.Thread):
    """
    Background thread that monitors active audio output.
    If the output changes mid-meeting (e.g. user connects AirPods),
    it automatically re-routes system output to the correct Multi-Output Device.
    """
    def __init__(self, check_interval=2.0):
        super().__init__()
        self.check_interval = check_interval
        self.stop_event = threading.Event()
        self.current_aggregate = None
        self.original_output = None
        
        # Cache available devices to avoid constant list queries
        self.available_devices = get_available_outputs()

    def run(self):
        while not self.stop_event.is_set():
            try:
                current_device = get_active_output()
                
                # Check if system audio output has drifted away from our active aggregate device
                if current_device != self.current_aggregate:
                    target_routing = None
                    
                    # Heuristic: Check if user switched to a Bluetooth/AirPods output
                    if "AirPods" in current_device or "Bluetooth" in current_device:
                        target_routing = "Meeting-AirPods"
                    # Or switched back to physical speakers
                    elif any(speaker in current_device for speaker in ["Speaker", "Speakers", "Built-in", "Internal"]):
                        target_routing = "Meeting-Speakers"
                        
                    # Trigger auto-routing update if the target aggregate device exists
                    if target_routing and target_routing in self.available_devices:
                        if target_routing != self.current_aggregate:
                            set_active_output(target_routing)
                            print(f"\n[AudioMonitor] Dynamic Switch: Detected output '{current_device}'. Auto-routing to '{target_routing}'.")
                            self.current_aggregate = target_routing
                            
            except Exception as e:
                import sys
                print(f"\n[AudioMonitor] Error: {e}", file=sys.stderr)
                sys.stderr.flush()
                
            self.stop_event.wait(self.check_interval)

    def stop(self):
        self.stop_event.set()


def configure_meeting_routing() -> tuple:
    """
    Checks the active audio device, routes system audio to the correct
    Multi-Output loopback device, and starts the background route monitor.
    Returns:
        (original_device_name, routed_device_name)
    """
    global _route_monitor
    
    # 1. Stop any existing monitor just in case
    if _route_monitor and _route_monitor.is_alive():
        _route_monitor.stop()
        _route_monitor.join()

    original_output = get_active_output()
    available_devices = get_available_outputs()
    
    # Check if a physical Bluetooth/AirPods output device is actually connected and available.
    # We look for any device containing "airpods" or "bluetooth", ignoring our custom aggregate "Meeting-AirPods".
    airpods_available = any(
        ("airpods" in dev.lower() or "bluetooth" in dev.lower()) and "meeting-airpods" not in dev.lower()
        for dev in available_devices
    )
    
    # Decide target routing based on active selection and physical availability.
    # We only route to Meeting-AirPods if the user's active output is currently AirPods/Bluetooth
    # (or was left set to Meeting-AirPods) AND physical AirPods are actually connected/available.
    is_active_output_bluetooth = "airpods" in original_output.lower() or "bluetooth" in original_output.lower()
    
    if is_active_output_bluetooth and airpods_available:
        target_routing = "Meeting-AirPods"
    else:
        target_routing = "Meeting-Speakers"
        # If the original output was a custom meeting aggregate but we have no AirPods connected,
        # we should reset the original_output to physical speakers so we don't restore to a silent route.
        if "meeting-airpods" in original_output.lower():
            physical_speakers = next(
                (dev for dev in available_devices if any(s in dev for s in ["Speaker", "Speakers", "Built-in", "Internal"])),
                None
            )
            if physical_speakers:
                original_output = physical_speakers
        
    routed_device = original_output
    if target_routing in available_devices:
        set_active_output(target_routing)
        print(f"Routed system audio output from '{original_output}' -> '{target_routing}'")
        routed_device = target_routing
    else:
        print(f"Warning: Target Multi-Output device '{target_routing}' was not found.")
        print("Please configure it in Audio MIDI Setup. Continuing with original audio routing.")

    # 2. Start the background route monitor to handle mid-meeting switches
    _route_monitor = AudioRouteMonitor()
    _route_monitor.original_output = original_output
    _route_monitor.current_aggregate = routed_device
    _route_monitor.start()

    return original_output, routed_device

def restore_audio_routing(original_device: str):
    """
    Stops the background route monitor and restores the system audio output
    to the original device.
    """
    global _route_monitor
    
    # 1. Stop the background monitor
    if _route_monitor:
        _route_monitor.stop()
        _route_monitor.join()
        _route_monitor = None
        print("Audio monitor thread stopped.")

    # 2. Restore active device
    if not original_device:
        return
    try:
        set_active_output(original_device)
        print(f"Restored system audio output -> '{original_device}'")
    except Exception as e:
        print(f"Error restoring audio routing: {e}")
