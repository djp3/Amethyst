#!/bin/sh
# Puts the window titles profile into the app's resources. When the app is being signed with a Developer ID, the
# profile is signed with that same certificate so System Settings shows it as verified; otherwise it is copied as is.
# Xcode runs this as a build phase of the app target.
set -eu

source="$SRCROOT/Amethyst/RevealWindowTitles.mobileconfig"
target="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/RevealWindowTitles.mobileconfig"
mkdir -p "$(dirname "$target")"

case "${EXPANDED_CODE_SIGN_IDENTITY_NAME:-}" in
    "Developer ID Application"*)
        ;;
    *)
        cp "$source" "$target"
        echo "note: window titles profile copied unsigned; the app is not being signed with a Developer ID"
        exit 0
        ;;
esac

# The signing tool picks a certificate by subject key ID, so look that up from the fingerprint Xcode chose.
key_id=$(security find-certificate -a -Z -p -c "$EXPANDED_CODE_SIGN_IDENTITY_NAME" \
    | awk -v wanted="$EXPANDED_CODE_SIGN_IDENTITY" '/SHA-1 hash:/ { keep = ($3 == wanted) } keep' \
    | openssl x509 -noout -ext subjectKeyIdentifier | tail -1 | tr -d ' :')
if [ -z "$key_id" ]; then
    echo "error: no certificate with fingerprint $EXPANDED_CODE_SIGN_IDENTITY in the keychain"
    exit 1
fi

security cms -S -Z "$key_id" -G -i "$source" -o "$target"
echo "note: window titles profile signed with $EXPANDED_CODE_SIGN_IDENTITY_NAME"
