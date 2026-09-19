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
# We write CFBundleVersion directly into each app's Info.plist rather than using
# `agvtool new-version -all`: agvtool scans every target and misreads the
# GENERATE_INFOPLIST_FILE boolean (false/true) as Info.plist paths, emitting
# `Cannot find ".../NO"` / `".../YES"`. On Xcode Cloud's toolchain that returns
# a non-zero status, which `set -e` turns into a failed post-clone step. Both app
# targets use an explicit INFOPLIST_FILE with GENERATE_INFOPLIST_FILE=false, so
# these plists are the build's source of truth for the build number.
#
# Both are stamped because the Mac app is its own native target (Yana-macOS,
# Info-macOS.plist) rather than a Mac Catalyst variant of the iOS one. A Mac
# workflow must archive the `Yana-macOS` scheme against `generic/platform=macOS`;
# the old `platform=macOS,variant=Mac Catalyst` destination no longer resolves on
# any scheme in this project, and the `Yana` scheme is iOS-only.
if [ -n "$CI_BUILD_NUMBER" ]; then
    echo "Setting build number to $CI_BUILD_NUMBER..."
    for plist in Yana/Info-iOS.plist Yana/Info-macOS.plist; do
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $CI_BUILD_NUMBER" "$plist"
    done
    echo "Build number set to $CI_BUILD_NUMBER"
fi

echo "=== ci_post_clone.sh complete ==="
