#!/usr/bin/env bash
set -euo pipefail

SCHEME="${SCHEME:-bbbbbb}"
CONFIGURATION="${CONFIGURATION:-Release}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
MARKETING_VERSION="${MARKETING_VERSION:-1.0.0}"
IPA_NAME="${IPA_NAME:-bbbbbb}"
BUNDLE_ID_OVERRIDE="${BBBBBB_BUNDLE_ID:-com.apple.mobile.MobileHouseArrest}"

echo "==> Building ${SCHEME} ${MARKETING_VERSION} (${BUILD_NUMBER}) ipa=${IPA_NAME} bundle=${BUNDLE_ID_OVERRIDE}"

xcodebuild \
  -project "${SCHEME}.xcodeproj" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -sdk iphoneos \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  MARKETING_VERSION="${MARKETING_VERSION}" \
  CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
  BBBBBB_BUNDLE_ID="${BUNDLE_ID_OVERRIDE}" \
  build

APP_PATH="build/Build/Products/${CONFIGURATION}-iphoneos/${SCHEME}.app"
if [ ! -d "${APP_PATH}" ]; then
  echo "error: app bundle not found at ${APP_PATH}" >&2
  exit 1
fi

rm -rf Payload "${IPA_NAME}.ipa" "${IPA_NAME}.ipa.sha256"
mkdir -p Payload
cp -R "${APP_PATH}" Payload/

zip -qry "${IPA_NAME}.ipa" Payload
rm -rf Payload

shasum -a 256 "${IPA_NAME}.ipa" > "${IPA_NAME}.ipa.sha256"
cat "${IPA_NAME}.ipa.sha256"
echo "==> ${IPA_NAME}.ipa ready (bundle ${BUNDLE_ID_OVERRIDE})"
