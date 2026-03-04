#!/bin/bash

set -e

TARGET_DIR=${1:-$(pwd)}

if [ -z "${APPLE_ID}" ]; then
    echo "APPLE_ID has not been set."
    exit 1
fi

if [ -z "${APPLE_APP_PASSWORD}" ]; then
    echo "APPLE_APP_PASSWORD has not been set."
    exit 1
fi

if [ -z "${APPLE_DEVELOPER_NAME}" ]; then
    echo "APPLE_DEVELOPER_NAME has not been set."
    exit 1
fi

if [ -z "${APPLE_TEAM_ID}" ]; then
    echo "APPLE_TEAM_ID has not been set."
    exit 1
fi

if [ -z "${MACOS_CERTIFICATE}" ]; then
    echo "MACOS_CERTIFICATE has not been set."
    exit 1
fi

if [ -z "${MACOS_CERTIFICATE_PWD}" ]; then
    echo "MACOS_CERTIFICATE_PWD has not been set."
    exit 1
fi

if [ -z "${MACOS_KEYCHAIN_PASSWORD}" ]; then
    echo "MACOS_KEYCHAIN_PASSWORD has not been set."
    exit 1
fi

CERTIFICATE_PATH="certificate.p12"
KEYCHAIN_PATH="build-signing.keychain"

cleanup() {
    if [[ -e "${CERTIFICATE_PATH}" ]]; then
        rm -f certificate.p12
    fi

    security delete-keychain "${KEYCHAIN_PATH}" 2>/dev/null || true
    security list-keychains -d user -s login.keychain || true
}

trap cleanup EXIT

import_cert() {
    echo -n "${MACOS_CERTIFICATE}" | base64 --decode -o "${CERTIFICATE_PATH}"

    security create-keychain -p "${MACOS_KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}"
    security default-keychain -s "${KEYCHAIN_PATH}"
    security unlock-keychain -p "${MACOS_KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}"

    security list-keychains -d user -s "${KEYCHAIN_PATH}" $(security list-keychains -d user | sed 's/\"//g')

    security import "${CERTIFICATE_PATH}" -k "${KEYCHAIN_PATH}" -P "${MACOS_CERTIFICATE_PWD}" -T /usr/bin/codesign -T /usr/bin/productsign -A

    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "${MACOS_KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}"

    security set-keychain-settings -lut 21600 "${KEYCHAIN_PATH}"
}

function sign_and_notarize() {
    VARIANTS=("template_debug" "template_release")

    for VARIANT in "${VARIANTS[@]}"; do
        FRAMEWORK="${TARGET_DIR%/}/libRhythmGameUtilities.macos.${VARIANT}.framework"

        ZIP_PATH="${FRAMEWORK}.zip"

        if [[ ! -e "${FRAMEWORK}" ]]; then
            echo "${FRAMEWORK} file not found."
            exit 1
        fi

        if [[ ! -e "${FRAMEWORK}/Resources/Info.plist" ]]; then
            echo "${FRAMEWORK}/Resources/Info.plist not found."
            exit 1
        fi

        codesign --force --deep --timestamp --options runtime \
            -s "Developer ID Application: ${APPLE_DEVELOPER_NAME} (${APPLE_TEAM_ID})" \
            "${FRAMEWORK}"

        codesign --verify --deep --strict "${FRAMEWORK}"

        ditto -c -k --keepParent "${FRAMEWORK}" "${ZIP_PATH}"

        NOTARY_JSON=$(xcrun notarytool submit "${ZIP_PATH}" \
            --apple-id "${APPLE_ID}" \
            --password "${APPLE_APP_PASSWORD}" \
            --team-id "${APPLE_TEAM_ID}" \
            --output-format json \
            --wait)

        NOTARY_STATUS=$(echo "${NOTARY_JSON}" | jq -r '.status')
        SUBMISSION_ID=$(echo "${NOTARY_JSON}" | jq -r '.id')

        if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
            xcrun notarytool log "${SUBMISSION_ID}" --apple-id "${APPLE_ID}" --password "${APPLE_APP_PASSWORD}" --team-id "${APPLE_TEAM_ID}"
            exit 1
        fi

        rm "${ZIP_PATH}"
    done
}

import_cert

sign_and_notarize
