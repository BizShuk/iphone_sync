#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PROJECT="${PROJECT:-iPhoneSync.xcodeproj}"
SCHEME="${SCHEME:-iPhoneSyncIOS}"
BUNDLE_ID="${BUNDLE_ID:-com.shuk.iphonesync.ios}"
APP_NAME="${APP_NAME:-iPhone Sync}"
CONFIGURATION="${CONFIGURATION:-Debug}"
BUILD_ROOT="${BUILD_ROOT:-build/iphone}"
ARCHIVE_PATH="$BUILD_ROOT/iPhoneSync.xcarchive"
DERIVED_DATA_PATH="$BUILD_ROOT/DerivedData"
APP_PATH="$ARCHIVE_PATH/Products/Applications/${APP_NAME}.app"
MODE="run"

step() {
  printf '\n▸ %s\n' "$*"
}

fail() {
  printf '\n錯誤: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: ./scripts/run-iphone.sh [--profile=debug|production] [--build-only|--console|--help]

  (no option)   Build, install, and launch iPhone Sync on one paired iPhone.
  --profile=... Select debug (Debug) or production (Release); debug is the default.
  --build-only  Create a signed iPhone archive without requiring a device.
  --console     Relaunch the installed app and attach its process console.
  --help        Show this help.

Examples:
  ./scripts/run-iphone.sh
  ./scripts/run-iphone.sh --profile=production
  ./scripts/run-iphone.sh --profile=production --build-only

Optional environment:
  DEVICE_UDID                 Select a specific paired iPhone.
  DEVELOPMENT_TEAM            Override the Apple Development team ID.
  CONFIGURATION               Xcode configuration (default: Debug);
                              --profile overrides it.
  BUILD_ROOT                  Generated output directory (default: build/iphone).
  APP_NAME                    Archive product name (default: iPhone Sync).
  ALLOW_PROVISIONING_UPDATES  Set to 0 to omit -allowProvisioningUpdates.
USAGE
}

while (( $# > 0 )); do
  case "$1" in
    --profile=debug)
      CONFIGURATION="Debug"
      ;;
    --profile=production)
      CONFIGURATION="Release"
      ;;
    --profile=*)
      fail "不支援的 profile: ${1#--profile=}（使用 debug 或 production）"
      ;;
    --build-only)
      [[ "$MODE" == "run" ]] || fail "只能指定一種執行模式"
      MODE="build-only"
      ;;
    --console)
      [[ "$MODE" == "run" ]] || fail "只能指定一種執行模式"
      MODE="console"
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      fail "未知參數: $1（使用 --help 查看說明）"
      ;;
  esac
  shift
done

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "缺少 $1"
}

select_device() {
  if [[ -n "${DEVICE_UDID:-}" ]]; then
    printf '%s\n' "$DEVICE_UDID"
    return
  fi

  local devices_json
  devices_json="$(mktemp "${TMPDIR:-/tmp}/iphonesync-devices.XXXXXX")"
  local list_output
  if ! list_output="$(
    xcrun devicectl list devices \
      --quiet \
      --json-output "$devices_json" 2>&1
  )"; then
    rm -f "$devices_json"
    fail "devicectl 無法列出裝置${list_output:+：$list_output}"
  fi

  local devices=()
  local identifier
  local index=0
  while identifier="$(
    /usr/bin/plutil -extract "result.devices.$index.identifier" \
      raw -o - "$devices_json" 2>/dev/null
  )"; do
    local device_type platform reality pairing_state tunnel_state transport_type
    device_type="$(
      /usr/bin/plutil -extract "result.devices.$index.hardwareProperties.deviceType" \
        raw -o - "$devices_json" 2>/dev/null || true
    )"
    platform="$(
      /usr/bin/plutil -extract "result.devices.$index.hardwareProperties.platform" \
        raw -o - "$devices_json" 2>/dev/null || true
    )"
    reality="$(
      /usr/bin/plutil -extract "result.devices.$index.hardwareProperties.reality" \
        raw -o - "$devices_json" 2>/dev/null || true
    )"
    pairing_state="$(
      /usr/bin/plutil -extract "result.devices.$index.connectionProperties.pairingState" \
        raw -o - "$devices_json" 2>/dev/null || true
    )"
    tunnel_state="$(
      /usr/bin/plutil -extract "result.devices.$index.connectionProperties.tunnelState" \
        raw -o - "$devices_json" 2>/dev/null || true
    )"
    transport_type="$(
      /usr/bin/plutil -extract "result.devices.$index.connectionProperties.transportType" \
        raw -o - "$devices_json" 2>/dev/null || true
    )"

    if [[ "$device_type" == "iPhone" &&
          "$platform" == "iOS" &&
          "$reality" == "physical" &&
          "$pairing_state" == "paired" &&
          ( "$tunnel_state" == "connected" || "$transport_type" == "wired" ) ]]; then
      devices+=("$identifier")
    fi
    ((index += 1))
  done
  rm -f "$devices_json"

  case "${#devices[@]}" in
    0)
      fail "找不到 connected + paired iPhone；請連線、解鎖並確認 Developer Mode"
      ;;
    1)
      printf '%s\n' "${devices[0]}"
      ;;
    *)
      fail "找到多台 paired iPhone；請設定 DEVICE_UDID 明確指定"
      ;;
  esac
}

resolve_development_team() {
  if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
    printf '%s\n' "$DEVELOPMENT_TEAM"
    return
  fi

  require_command security
  require_command openssl
  local identity_names=()
  local identity_name
  while IFS= read -r identity_name; do
    [[ -n "$identity_name" ]] && identity_names+=("$identity_name")
  done < <(
    security find-identity -v -p codesigning |
      sed -nE 's/.*"(Apple Development:[^"]+)".*/\1/p'
  )

  local teams=()
  local team
  for identity_name in "${identity_names[@]}"; do
    team="$(
      security find-certificate -c "$identity_name" -p 2>/dev/null |
        openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null |
        sed -nE 's/^subject=.*OU[[:space:]]*=[[:space:]]*([A-Z0-9]{10})(,|$).*/\1/p' || true
    )"
    [[ -n "$team" ]] && teams+=("$team")
  done

  local unique_teams=()
  if (( ${#teams[@]} > 0 )); then
    while IFS= read -r team; do
      [[ -n "$team" ]] && unique_teams+=("$team")
    done < <(printf '%s\n' "${teams[@]}" | sort -u)
  fi
  teams=("${unique_teams[@]}")

  case "${#teams[@]}" in
    0)
      fail "找不到 Apple Development signing identity；請先登入 Apple ID 並建立憑證"
      ;;
    1)
      printf '%s\n' "${teams[0]}"
      ;;
    *)
      fail "找到多組 Apple Development team；請設定 DEVELOPMENT_TEAM 明確指定"
      ;;
  esac
}

build_archive() {
  require_command xcodegen
  require_command xcodebuild
  local development_team
  development_team="$(resolve_development_team)"

  step "Regenerating Xcode project"
  xcodegen generate

  local args=(
    -project "$PROJECT"
    -scheme "$SCHEME"
    -configuration "$CONFIGURATION"
    -destination "generic/platform=iOS"
    -derivedDataPath "$DERIVED_DATA_PATH"
    -archivePath "$ARCHIVE_PATH"
  )
  if [[ "${ALLOW_PROVISIONING_UPDATES:-1}" != "0" ]]; then
    args+=( -allowProvisioningUpdates )
  fi
  args+=( "DEVELOPMENT_TEAM=$development_team" )
  args+=( archive )

  step "Archiving $SCHEME ($CONFIGURATION) for iPhone"
  xcodebuild "${args[@]}"
  [[ -d "$APP_PATH" ]] || fail "archive 中找不到 app: $APP_PATH"
  printf '\nArchive: %s\n' "$ARCHIVE_PATH"
}

case "$MODE" in
  build-only)
    build_archive
    ;;
  console)
    require_command xcrun
    device="$(select_device)"
    step "Launching $BUNDLE_ID with console on $device"
    xcrun devicectl device process launch \
      --device "$device" --terminate-existing --console "$BUNDLE_ID"
    ;;
  run)
    require_command xcrun
    device="$(select_device)"
    build_archive
    step "Installing on $device"
    xcrun devicectl device install app --device "$device" "$APP_PATH"
    step "Launching $BUNDLE_ID"
    xcrun devicectl device process launch \
      --device "$device" --terminate-existing "$BUNDLE_ID"
    ;;
esac
