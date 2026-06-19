#!/bin/bash
# setup.sh - Initialize virtual environment and install dependencies
set -e

echo "=== Initializing Audiologue Development Environment ==="

# 1. Create virtual environment if it doesn't exist
if [ ! -d "venv" ]; then
    echo "Creating virtual environment..."
    python3 -m venv venv
else
    echo "Virtual environment already exists."
fi

# 2. Upgrade pip and install dependencies
echo "Installing python packages..."
venv/bin/pip install --upgrade pip
venv/bin/pip install -r requirements.txt

echo "=== Setup complete! ==="
echo "You can now run './build.sh' to package and install the application."
