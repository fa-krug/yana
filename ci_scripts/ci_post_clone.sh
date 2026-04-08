#!/bin/bash
set -e

echo "=== ci_post_clone.sh ==="

# Install Homebrew if not available (Xcode Cloud provides it)
if ! command -v brew &> /dev/null; then
    echo "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# Install XcodeGen
echo "Installing XcodeGen..."
brew install xcodegen

# Generate Xcode project from project.yml
echo "Generating Xcode project..."
cd "$CI_PRIMARY_REPOSITORY_PATH"
xcodegen generate

# Set build number to Xcode Cloud build number for unique TestFlight builds
if [ -n "$CI_BUILD_NUMBER" ]; then
    echo "Setting build number to $CI_BUILD_NUMBER..."
    xcrun agvtool new-version -all "$CI_BUILD_NUMBER"
    echo "Build number set to $CI_BUILD_NUMBER"
fi

echo "=== ci_post_clone.sh complete ==="
