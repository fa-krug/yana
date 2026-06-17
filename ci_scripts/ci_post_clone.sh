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

# Resolve Swift Package Manager dependencies and write Package.resolved.
# Xcode Cloud builds with automatic dependency resolution disabled, so the
# resolved file must exist before the build step runs. The generated
# .xcodeproj is gitignored, so we cannot commit it — resolve it here instead.
echo "Resolving Swift package dependencies..."
xcodebuild -resolvePackageDependencies -project Yana.xcodeproj -scheme Yana

# Set build number to Xcode Cloud build number for unique TestFlight builds
if [ -n "$CI_BUILD_NUMBER" ]; then
    echo "Setting build number to $CI_BUILD_NUMBER..."
    xcrun agvtool new-version -all "$CI_BUILD_NUMBER"
    echo "Build number set to $CI_BUILD_NUMBER"
fi

echo "=== ci_post_clone.sh complete ==="
