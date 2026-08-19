#!/bin/bash
# Builds Marina.app and the marina CLI, then installs both.
#
#   ./build.sh            build + install to Applications and a bin dir on PATH
#   ./build.sh --no-install   build only, leaves the bundle in ./dist
#   ./build.sh --run          build, install, and relaunch the app
#   ./build.sh --forever      build, install, and enable launch at login
#   ./build.sh --release      signed + notarized ZIP

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="$ROOT/dist"
APP="$DIST/Marina.app"
INSTALL=1
RUN=0
FOREVER=0
RELEASE=0
RUNNING_SERVERS=()

for arg in "$@"; do
  case "$arg" in
    --no-install) INSTALL=0 ;;
    --run) RUN=1 ;;
    --forever) FOREVER=1 ;;
    --release) RELEASE=1; INSTALL=0 ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

echo "==> Building (release)"
cd "$ROOT"
if [ "$RELEASE" -eq 1 ]; then
  swift build -c release --triple arm64-apple-macosx14.0 --product MarinaApp
  swift build -c release --triple x86_64-apple-macosx14.0 --product MarinaApp
  swift build -c release --triple arm64-apple-macosx14.0 --product marina
  swift build -c release --triple x86_64-apple-macosx14.0 --product marina
  ARM64_BIN_DIR="$(swift build -c release --triple arm64-apple-macosx14.0 --show-bin-path)"
  X86_64_BIN_DIR="$(swift build -c release --triple x86_64-apple-macosx14.0 --show-bin-path)"
  BIN_DIR="$ARM64_BIN_DIR"
else
  swift build -c release --product MarinaApp
  swift build -c release --product marina
  BIN_DIR="$(swift build -c release --show-bin-path)"
fi

VERSION="$(grep -o '"[0-9][^"]*"' "$ROOT/Sources/MarinaCore/Version.swift" | tr -d '"')"

echo "==> Assembling Marina.app"
if [ -e "$APP" ]; then
  trash "$APP"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [ "$RELEASE" -eq 1 ]; then
  lipo -create "$ARM64_BIN_DIR/MarinaApp" "$X86_64_BIN_DIR/MarinaApp" -output "$APP/Contents/MacOS/Marina"
  ARCHITECTURES="$(lipo -archs "$APP/Contents/MacOS/Marina")"
  case " $ARCHITECTURES " in
    *" arm64 "*) ;;
    *) echo "Universal build is missing arm64: $ARCHITECTURES" >&2; exit 1 ;;
  esac
  case " $ARCHITECTURES " in
    *" x86_64 "*) ;;
    *) echo "Universal build is missing x86_64: $ARCHITECTURES" >&2; exit 1 ;;
  esac
  echo "    architectures: $ARCHITECTURES"
else
  cp "$BIN_DIR/MarinaApp" "$APP/Contents/MacOS/Marina"
fi
# SwiftTerm ships a resource bundle; carry it along if this build produced one.
for bundle in "$BIN_DIR"/*.bundle; do
  [ -e "$bundle" ] || continue
  cp -R "$bundle" "$APP/Contents/Resources/"
done

# The downloadable app performs agent setup itself, so it must carry both the
# distributable skill and a CLI matching the app's architectures.
cp -R "$ROOT/skills/marina" "$APP/Contents/Resources/marina-skill"
if [ "$RELEASE" -eq 1 ]; then
  lipo -create "$ARM64_BIN_DIR/marina" "$X86_64_BIN_DIR/marina" -output "$APP/Contents/Resources/marina-cli"
else
  cp "$BIN_DIR/marina" "$APP/Contents/Resources/marina-cli"
fi
chmod +x "$APP/Contents/Resources/marina-cli"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>Marina</string>
	<key>CFBundleDisplayName</key>
	<string>Marina</string>
	<key>CFBundleIdentifier</key>
	<string>dev.marina.app</string>
	<key>CFBundleExecutable</key>
	<string>Marina</string>
	<key>CFBundleIconFile</key>
	<string>Marina</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${VERSION}</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.developer-tools</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSSupportsAutomaticTermination</key>
	<false/>
	<key>NSSupportsSuddenTermination</key>
	<false/>
</dict>
</plist>
PLIST

echo "==> Icon"
if swift "$ROOT/Tools/makeicon.swift" "$APP/Contents/Resources/Marina.icns" >/dev/null 2>&1; then
  echo "    generated"
else
  echo "    skipped (icon generation failed, using the default)"
fi

if [ "$RELEASE" -eq 1 ]; then
  SIGN_IDENTITY="${MARINA_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}"
  if [ -z "$SIGN_IDENTITY" ]; then
    echo "No Developer ID Application identity is available in the keychain." >&2
    exit 1
  fi
  echo "==> Signing for Developer ID distribution"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" \
    "$APP/Contents/Resources/marina-cli"
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP/Contents/Resources/marina-cli"
  codesign --verify --deep --strict --verbose=2 "$APP"

  ARCHIVE="$DIST/Marina-macOS.zip"
  if [ -e "$ARCHIVE" ]; then
    trash "$ARCHIVE"
  fi
  echo "==> Archiving"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"

  echo "==> Notarizing with Apple"
  asc notarization submit --file "$ARCHIVE" --wait --timeout 1h --output table
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"

  # The final archive contains the stapled ticket, so it works even when the
  # first launch cannot reach Apple's notarization service.
  trash "$ARCHIVE"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
  spctl --assess --type execute --verbose=2 "$APP"

  echo "    $ARCHIVE"
else
  echo "==> Signing (ad-hoc)"
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "    ad-hoc signing failed, continuing"
fi

if [ "$INSTALL" -eq 1 ]; then
  echo "==> Installing"
  if pgrep -x Marina >/dev/null 2>&1; then
    if command -v marina >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
      while IFS= read -r server_id; do
        [ -n "$server_id" ] && RUNNING_SERVERS+=("$server_id")
      done < <(marina status --json 2>/dev/null | jq -r '.projects[].servers[] | select(.state != "stopped" and .state != "failed") | .id')
    fi
    echo "    quitting the running Marina (this stops your servers)"
    if command -v marina >/dev/null 2>&1; then
      marina quit >/dev/null 2>&1 || true
    fi
    osascript -e 'quit app "Marina"' >/dev/null 2>&1 || true
    for _ in {1..20}; do
      pgrep -x Marina >/dev/null 2>&1 || break
      sleep 0.25
    done
    if pgrep -x Marina >/dev/null 2>&1; then
      echo "    Marina did not quit; close its open sheet and run the installer again" >&2
      exit 1
    fi
  fi
  # A standard (non-admin) account cannot write to /Applications, so fall back
  # to the per-user Applications folder, which Spotlight and Launchpad index
  # just the same.
  if [ -w /Applications ]; then
    APP_TARGET="/Applications/Marina.app"
  else
    mkdir -p "$HOME/Applications"
    APP_TARGET="$HOME/Applications/Marina.app"
  fi
  if [ -e "$APP_TARGET" ]; then
    trash "$APP_TARGET"
  fi
  cp -R "$APP" "$APP_TARGET"
  echo "    $APP_TARGET"

  # First writable directory that is already on PATH wins.
  CLI_TARGET=""
  for candidate in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin"; do
    if [ -d "$candidate" ] && [ -w "$candidate" ]; then
      CLI_TARGET="$candidate/marina"
      break
    fi
  done

  if [ -n "$CLI_TARGET" ]; then
    cp "$APP/Contents/Resources/marina-cli" "$CLI_TARGET"
    chmod +x "$CLI_TARGET"
    echo "    $CLI_TARGET"
  else
    echo "    no writable bin directory found, run:"
    echo "      sudo cp '$BIN_DIR/marina' /usr/local/bin/marina"
  fi

  SKILL_TARGET="$HOME/.agents/skills/marina"
  mkdir -p "$HOME/.agents/skills"
  LEGACY_SKILL="$HOME/.agents/skills/portly"
  if [ -e "$LEGACY_SKILL" ] || [ -L "$LEGACY_SKILL" ]; then
    trash "$LEGACY_SKILL"
    echo "    removed $LEGACY_SKILL (installed under the old name)"
  fi
  if [ -e "$SKILL_TARGET" ] || [ -L "$SKILL_TARGET" ]; then
    trash "$SKILL_TARGET"
  fi
  cp -R "$ROOT/skills/marina" "$SKILL_TARGET"
  echo "    $SKILL_TARGET"

  RULE_SNIPPET="$(mktemp "${TMPDIR:-/tmp}/marina-rule.XXXXXX")"
  cat > "$RULE_SNIPPET" <<'RULE'
<!-- marina:managed-rule:start -->
## Development servers

- Always use Marina (`marina ...`) to start, stop, restart, inspect, or keep local development servers running.
- Start with `marina status`. Use `marina status --details` only for the full inventory and metrics, and `--json` only for machine-readable fields. Reuse a healthy managed server; if an in-scope server is running outside Marina, register it and use `marina take-over <project/server> --json`.
- For long-lived or reusable work, create a project and server.
- For builds, tests, code generation, previews, demos, and other bounded one-off work, run `job_id="$(marina temp '<command>' --path <folder> --timeout 30m)"`, then `marina wait "$job_id"`. `temp` returns immediately with an ID; `wait` prints captured logs and exits with the command's real code. A timeout kills the whole process group and exits with code `124`.
- Never launch persistent development servers directly, in the background, or through another supervisor.
<!-- marina:managed-rule:end -->
RULE

  # Both files the app manages at runtime, so the installer never leaves one of
  # them holding a rule that contradicts the other.
  for AGENTS_FILE in "$HOME/.agents/AGENTS.md" "$HOME/.claude/CLAUDE.md"; do
    mkdir -p "$(dirname "$AGENTS_FILE")"

    if [ -f "$AGENTS_FILE" ] && grep -q 'portly:managed-rule:start' "$AGENTS_FILE"; then
      STRIPPED_RULES="$(mktemp "${TMPDIR:-/tmp}/marina-legacy.XXXXXX")"
      awk '
        /<!-- portly:managed-rule:start -->/ { dropping = 1; next }
        dropping && /<!-- portly:managed-rule:end -->/ { dropping = 0; next }
        !dropping { print }
      ' "$AGENTS_FILE" > "$STRIPPED_RULES"
      mv "$STRIPPED_RULES" "$AGENTS_FILE"
      echo "    $AGENTS_FILE (rules from the old name removed)"
    fi

    if [ -f "$AGENTS_FILE" ] && grep -q 'marina:managed-rule:start' "$AGENTS_FILE" && grep -q 'marina:managed-rule:end' "$AGENTS_FILE"; then
      UPDATED_RULES="$(mktemp "${TMPDIR:-/tmp}/marina-agents.XXXXXX")"
      awk -v rule_file="$RULE_SNIPPET" '
        /<!-- marina:managed-rule:start -->/ {
          while ((getline line < rule_file) > 0) print line
          close(rule_file)
          replacing = 1
          next
        }
        replacing && /<!-- marina:managed-rule:end -->/ { replacing = 0; next }
        !replacing { print }
      ' "$AGENTS_FILE" > "$UPDATED_RULES"
      mv "$UPDATED_RULES" "$AGENTS_FILE"
      echo "    $AGENTS_FILE (Marina rules updated)"
    else
      if [ -s "$AGENTS_FILE" ]; then printf '\n' >> "$AGENTS_FILE"; fi
      cat "$RULE_SNIPPET" >> "$AGENTS_FILE"
      echo "    $AGENTS_FILE (Marina rules added)"
    fi
  done
  trash "$RULE_SNIPPET"
fi

if [ "$FOREVER" -eq 1 ]; then
  if [ "$INSTALL" -ne 1 ]; then
    echo "    --forever requires installation; remove --no-install" >&2
    exit 1
  fi
  echo "==> Enabling launch at login"
  marina forever enable
elif [ "$RUN" -eq 1 ]; then
  echo "==> Launching"
  if [ -e "$HOME/Applications/Marina.app" ] && [ ! -e /Applications/Marina.app ]; then
    open "$HOME/Applications/Marina.app"
  else
    open /Applications/Marina.app
  fi
fi

if { [ "$FOREVER" -eq 1 ] || [ "$RUN" -eq 1 ]; } && [ "${#RUNNING_SERVERS[@]}" -gt 0 ]; then
  echo "==> Restoring active servers"
  for server_id in "${RUNNING_SERVERS[@]}"; do
    marina start "$server_id" --json >/dev/null
    echo "    $server_id"
  done
fi

echo "Done."
