#!/bin/bash
# Audiologue Launcher

# Resolve the directory where this script is located
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

# Execute the status bar app directly, replacing the shell process
# This preserves the AppleScript permission context so the app inherits macOS microphone permissions.
exec venv/bin/python app.py
