import getpass
import sys
import os

try:
    import config
except ImportError:
    # Append current directory to path just in case
    sys.path.append(os.path.dirname(os.path.abspath(__file__)))
    import config

def main():
    print("=== Audiologue API Key Setup ===")
    print("This script will store your Gemini API Key securely in your macOS system Keychain.\n")
    
    # Prompt securely for the API key (characters will be hidden as you type/paste)
    api_key = getpass.getpass("Enter your Gemini API Key (hidden): ").strip()
    
    if not api_key:
        print("Error: API Key cannot be empty.")
        sys.exit(1)
        
    # Attempt to save to keychain
    success = config.save_api_key(api_key)
    
    if success:
        print("\nAPI Key saved successfully to macOS Keychain!")
        
        # Verify read-back
        retrieved_key = config.get_api_key()
        if retrieved_key:
            masked_key = retrieved_key[:6] + "..." + retrieved_key[-4:] if len(retrieved_key) > 10 else "..."
            print(f"Verification: Successfully read key back from Keychain: {masked_key}")
            print("Setup complete.")
        else:
            print("Warning: Saved key, but verification read-back failed.")
    else:
        print("Error: Could not save API Key to macOS Keychain.")
        sys.exit(1)

if __name__ == "__main__":
    main()
