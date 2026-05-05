#!/bin/bash
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
echo "Installing Voiceeee..."
echo "Moving Voiceeee.app to Applications folder..."
sudo cp -R "$DIR/Voiceeee.app" /Applications/
echo "Removing macOS Quarantine flag..."
sudo xattr -cr /Applications/Voiceeee.app
echo "Opening Voiceeee..."
open /Applications/Voiceeee.app
echo "Installation Complete! You can close this terminal."
sleep 2
