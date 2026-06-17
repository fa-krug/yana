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

# Put Package.resolved in place for Swift Package Manager.
# Xcode Cloud builds with automatic dependency resolution disabled, so the
# resolved file must already exist before the build step runs. The generated
# .xcodeproj is gitignored, and `xcodebuild -resolvePackageDependencies` also
# honors the disabled-resolution setting (so it fails with no resolved file
# yet). Instead we keep a committed copy at ci_scripts/Package.resolved and
# copy it into the generated workspace here.
# NOTE: regenerate ci_scripts/Package.resolved whenever package dependencies
# change (cp from Yana.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/).
echo "Installing committed Package.resolved..."
RESOLVED_DIR="Yana.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$RESOLVED_DIR"
cp ci_scripts/Package.resolved "$RESOLVED_DIR/Package.resolved"

# Set build number to Xcode Cloud build number for unique TestFlight builds
if [ -n "$CI_BUILD_NUMBER" ]; then
    echo "Setting build number to $CI_BUILD_NUMBER..."
    xcrun agvtool new-version -all "$CI_BUILD_NUMBER"
    echo "Build number set to $CI_BUILD_NUMBER"
fi

echo "=== ci_post_clone.sh complete ==="
