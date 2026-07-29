#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
source_app="${repo_dir}/build-no-updater/Build/Products/Release/Squirrel.app"
target_app="/Library/Input Methods/Squirrel.app"
signing_identity="9BC6967A09C8895548E4566D59C6CF72475B3807"
signing_certificate_hash="9bc6967a09c8895548e4566d59c6cf72475b3807"
signing_requirement="identifier \"im.rime.inputmethod.Squirrel\" and certificate root = H\"${signing_certificate_hash}\""

if (( EUID != 0 )); then
  echo "Run this installer with administrator privileges." >&2
  exit 1
fi

test -d "${source_app}"
signing_user=$(/usr/bin/stat -f "%Su" "${source_app}")
signing_home=$(/usr/bin/dscl . -read "/Users/${signing_user}" NFSHomeDirectory | /usr/bin/awk '{print $2}')
signing_keychain="${signing_home}/Library/Keychains/login.keychain-db"

test -f "${signing_keychain}"
/usr/bin/sudo -u "${signing_user}" \
  /usr/bin/codesign \
  --force \
  --deep \
  --sign "${signing_identity}" \
  --keychain "${signing_keychain}" \
  "${source_app}"
/usr/bin/sudo -u "${signing_user}" \
  /usr/bin/codesign \
  --verify \
  --deep \
  --strict \
  --requirement "${signing_requirement}" \
  "${source_app}"

/usr/bin/killall Squirrel >/dev/null 2>&1 || true
/bin/rm -rf "${target_app}"
/usr/bin/ditto --norsrc --noextattr "${source_app}" "${target_app}"
/usr/sbin/chown -R root:wheel "${target_app}"
/usr/bin/sudo -u "${signing_user}" \
  /usr/bin/codesign \
  --verify \
  --deep \
  --strict \
  --requirement "${signing_requirement}" \
  "${target_app}"
"${target_app}/Contents/MacOS/Squirrel" --register-input-source
