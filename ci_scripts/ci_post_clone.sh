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

# Set build number to Xcode Cloud build number for unique TestFlight builds.
# We write CFBundleVersion directly into the app's Info.plist rather than using
# `agvtool new-version -all`: agvtool scans every target and misreads the
# GENERATE_INFOPLIST_FILE boolean (false/true) as Info.plist paths, emitting
# `Cannot find ".../NO"` / `".../YES"`. On Xcode Cloud's toolchain that returns
# a non-zero status, which `set -e` turns into a failed post-clone step. The
# app target uses an explicit INFOPLIST_FILE with GENERATE_INFOPLIST_FILE=false,
# so this plist is the build's source of truth for the build number.
if [ -n "$CI_BUILD_NUMBER" ]; then
    echo "Setting build number to $CI_BUILD_NUMBER..."
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $CI_BUILD_NUMBER" Yana/Info-iOS.plist
    echo "Build number set to $CI_BUILD_NUMBER"
fi

echo "=== ci_post_clone.sh complete ==="
