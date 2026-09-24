#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ARCHIVE="${1:-$HOME/Downloads/DiscordSocialSdk-1.10.19337.zip}"
TARGET_DIR="$ROOT_DIR/App/Vendor/DiscordSocialSDK"
HEADER_DIR="$ROOT_DIR/App/Sources/DiscordSocialSDKBridge/sdk-include"

if [[ ! -f "$ARCHIVE" ]]; then
  echo "Discord Social SDK archive not found: $ARCHIVE" >&2
  exit 1
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
unzip -q "$ARCHIVE" \
  'discord_social_sdk/lib/release/discord_partner_sdk.framework/*' \
  'discord_social_sdk/include/discordpp.h' \
  'discord_social_sdk/include/cdiscord.h' \
  'discord_social_sdk/License-Notices.txt' \
  -d "$STAGING"

SOURCE="$STAGING/discord_social_sdk/lib/release/discord_partner_sdk.framework"
if [[ ! -f "$SOURCE/discord_partner_sdk" ]]; then
  echo "Archive has no macOS release framework." >&2
  exit 1
fi

mkdir -p "$TARGET_DIR" "$HEADER_DIR"
ditto "$SOURCE" "$TARGET_DIR/discord_partner_sdk.framework"
cp "$STAGING/discord_social_sdk/include/discordpp.h" "$HEADER_DIR/"
cp "$STAGING/discord_social_sdk/include/cdiscord.h" "$HEADER_DIR/"
cp "$STAGING/discord_social_sdk/License-Notices.txt" "$TARGET_DIR/"
codesign --verify "$TARGET_DIR/discord_partner_sdk.framework"
echo "Installed local Discord Social SDK; binaries and headers are gitignored."
