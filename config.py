import os
import keyring
from pathlib import Path

# Constants for Keychain storage
SERVICE_NAME = "Audiologue"
KEY_NAME = "api_key"

def get_api_key() -> str:
    """
    Retrieves the Gemini API Key.
    First checks the macOS system Keychain, then falls back to the environment variable.
    """
    try:
        # Retrieve key from macOS Keychain
        key = keyring.get_password(SERVICE_NAME, KEY_NAME)
        if key:
            return key
    except Exception as e:
        print(f"Warning: Failed to access macOS Keychain: {e}")
    
    # Fallback to environment variable
    return os.environ.get("GEMINI_API_KEY", "")

def save_api_key(key: str) -> bool:
    """
    Saves the Gemini API Key securely to the macOS system Keychain.
    """
    if not key or not key.strip():
        raise ValueError("API Key cannot be empty.")
    try:
        keyring.set_password(SERVICE_NAME, KEY_NAME, key.strip())
        return True
    except Exception as e:
        print(f"Error: Failed to save API Key to macOS Keychain: {e}")
        return False

def delete_api_key() -> bool:
    """
    Deletes the Gemini API Key from the macOS system Keychain.
    """
    try:
        keyring.delete_password(SERVICE_NAME, KEY_NAME)
        return True
    except Exception as e:
        print(f"Error: Failed to delete API Key from macOS Keychain: {e}")
        return False

def get_notes_dir() -> Path:
    """
    Returns the Path to the default meeting notes directory.
    Creates the directory with strict 0o700 permissions if it does not exist.
    """
    base_dir = Path.home() / "Library" / "Application Support" / "Audiologue"
    notes_dir = base_dir / "MeetingNotes"
    
    # Create directories
    base_dir.mkdir(parents=True, exist_ok=True)
    notes_dir.mkdir(parents=True, exist_ok=True)
    
    # Restrict to owner read/write/execute only for local security/privacy
    base_dir.chmod(0o700)
    notes_dir.chmod(0o700)
    
    return notes_dir

def get_temp_dir() -> Path:
    """
    Returns the Path to the temporary audio storage directory.
    Creates the directory with strict 0o700 permissions if it does not exist.
    """
    base_dir = Path.home() / "Library" / "Application Support" / "Audiologue"
    temp_dir = base_dir / "temp"
    
    # Create directories
    base_dir.mkdir(parents=True, exist_ok=True)
    temp_dir.mkdir(parents=True, exist_ok=True)
    
    # Restrict to owner read/write/execute only for local security/privacy
    base_dir.chmod(0o700)
    temp_dir.chmod(0o700)
    
    return temp_dir
