#!/bin/bash
# Build, sign with the stable self-signed identity, and relaunch.
#
# Signing with a fixed identity (instead of Xcode's ad-hoc signature) keeps the
# app's Designated Requirement stable across rebuilds, so the Accessibility /
# TCC grant survives — no need to re-approve every build.
#
# One-time setup created the identity "NotchIsland Dev" in the login keychain
# (a self-signed code-signing cert). If you're on a fresh machine, recreate it
# via Keychain Access → Certificate Assistant → Create a Certificate
# (self-signed, type: Code Signing), named exactly "NotchIsland Dev".
set -e

IDENTITY="NotchIsland Dev"
APP="$HOME/Library/Developer/Xcode/DerivedData/NotchIsland-dvjdqhbjxzaunlchxshtyorbimmr/Build/Products/Debug/NotchIsland.app"

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project NotchIsland.xcodeproj -scheme NotchIsland \
  -configuration Debug -destination 'platform=macOS' build | tail -2

codesign --force --sign "$IDENTITY" "$APP"
echo "signed:"
codesign -dvv "$APP" 2>&1 | grep -E "Authority|flags"

pkill -9 NotchIsland 2>/dev/null || true
sleep 1
open -n "$APP"
echo "relaunched"
