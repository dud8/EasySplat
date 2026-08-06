#!/bin/bash -p
# Submit a signed Mac App Store package to App Store Connect.
#
# The App Store Connect key is the one credential this repository never sees:
# altool reads it from ~/.appstoreconnect/private_keys by key id, so this script
# checks that the file is a private regular file and then names it, nothing more.
set -euo pipefail

PACKAGE=""
KEY_ID=""
ISSUER_ID=""
ACTION=""

PRIVATE_KEY_DIR="$HOME/.appstoreconnect/private_keys"
XCRUN=/usr/bin/xcrun

while [[ $# -gt 0 ]]; do
  case "$1" in
    --package)
      PACKAGE="$2"
      shift 2
      ;;
    --key-id)
      KEY_ID="$2"
      shift 2
      ;;
    --issuer-id)
      ISSUER_ID="$2"
      shift 2
      ;;
    --validate)
      if [ -n "$ACTION" ]; then
        echo "Choose exactly one of --validate or --upload." >&2
        exit 1
      fi
      ACTION=validate
      shift
      ;;
    --upload)
      if [ -n "$ACTION" ]; then
        echo "Choose exactly one of --validate or --upload." >&2
        exit 1
      fi
      ACTION=upload
      shift
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [ -z "$PACKAGE" ] || [ -z "$KEY_ID" ] || [ -z "$ISSUER_ID" ] || [ -z "$ACTION" ]; then
  echo "Usage: upload_mas_package.sh --package <signed.pkg> --key-id <id> --issuer-id <uuid> (--validate | --upload)" >&2
  exit 1
fi

if ! [[ "$KEY_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "App Store Connect key id must be exactly 10 uppercase letters or digits." >&2
  exit 1
fi
if ! [[ "$ISSUER_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
  echo "App Store Connect issuer id must be a lowercase UUID." >&2
  exit 1
fi

# A caller-supplied command would defeat every check below it.
if [ -n "${EASYSPLAT_ALTOOL_BIN:-}" ]; then
  echo "Upload command overrides are not permitted." >&2
  exit 1
fi
unset GITHUB_PERSONAL_ACCESS_TOKEN GH_TOKEN GITHUB_TOKEN
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

PACKAGE="$(/usr/bin/python3 -I - "$PACKAGE" <<'PY'
import os
import stat
import sys

package = sys.argv[1]
if not os.path.isabs(package) or os.path.normpath(package) != package:
    raise SystemExit("Package path must be absolute and normalized.")
if os.path.realpath(package) != package:
    raise SystemExit("Package path must contain no symlink ancestry.")
if not package.endswith(".pkg"):
    raise SystemExit("App Store submission requires an installer package.")
try:
    metadata = os.lstat(package)
except FileNotFoundError:
    raise SystemExit(f"Package does not exist: {package}")
if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
    raise SystemExit("Package must be an ordinary, non-hardlinked regular file.")
if metadata.st_size == 0:
    raise SystemExit("Package must not be empty.")
print(package)
PY
)" || exit 1

/usr/bin/python3 -I - "$PRIVATE_KEY_DIR" "$KEY_ID" <<'PY'
import os
import stat
import sys

directory, key_id = sys.argv[1:]
path = os.path.join(directory, f"AuthKey_{key_id}.p8")
try:
    metadata = os.lstat(path)
except FileNotFoundError:
    raise SystemExit(
        f"App Store Connect key AuthKey_{key_id}.p8 is not in {directory}."
    )
if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
    raise SystemExit("App Store Connect key must be an ordinary regular file.")
if metadata.st_uid != os.geteuid():
    raise SystemExit("App Store Connect key must be owned by the current user.")
if stat.S_IMODE(metadata.st_mode) & 0o077:
    raise SystemExit("App Store Connect key must not be group- or world-readable.")
if metadata.st_size == 0:
    raise SystemExit("App Store Connect key must not be empty.")
PY

# The installer signature is what the store checks first, so a package that
# cannot prove its own signature should never reach the upload endpoint.
if ! /usr/sbin/pkgutil --check-signature "$PACKAGE" >/dev/null 2>&1; then
  echo "Package is not signed, so App Store Connect would reject it." >&2
  exit 1
fi
if ! /usr/sbin/pkgutil --check-signature "$PACKAGE" 2>/dev/null \
  | /usr/bin/grep -Fq "3rd Party Mac Developer Installer:"; then
  echo "Package is not signed with a Mac Installer Distribution certificate." >&2
  exit 1
fi

case "$ACTION" in
  validate) altool_action=--validate-app ;;
  upload) altool_action=--upload-app ;;
esac

"$XCRUN" altool "$altool_action" \
  --file "$PACKAGE" \
  --type macos \
  --apiKey "$KEY_ID" \
  --apiIssuer "$ISSUER_ID"

if [ "$ACTION" = upload ]; then
  echo "Uploaded $(/usr/bin/basename "$PACKAGE") to App Store Connect."
else
  echo "Validated $(/usr/bin/basename "$PACKAGE") against App Store Connect."
fi
