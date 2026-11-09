#!/usr/bin/env bash
set -euo pipefail

SCHEME="${SCHEME:-bbbbbb}"
CONFIGURATION="${CONFIGURATION:-Release}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
MARKETING_VERSION="${MARKETING_VERSION:-1.0.0}"

echo "==> Building ${SCHEME} ${MARKETING_VERSION} (${BUILD_NUMBER})"

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
  build

APP_PATH="build/Build/Products/${CONFIGURATION}-iphoneos/${SCHEME}.app"
if [ ! -d "${APP_PATH}" ]; then
  echo "error: app bundle not found at ${APP_PATH}" >&2
  exit 1
fi

rm -rf Payload bbbbbb.ipa bbbbbb.ipa.sha256
mkdir -p Payload
cp -R "${APP_PATH}" Payload/

zip -qry bbbbbb.ipa Payload
rm -rf Payload

shasum -a 256 bbbbbb.ipa > bbbbbb.ipa.sha256
cat bbbbbb.ipa.sha256
echo "==> bbbbbb.ipa ready"
