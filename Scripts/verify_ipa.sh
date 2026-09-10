#!/bin/bash
# Verifies a final IPA against a reference (pre-injection) IPA. Fails loudly if:
#   1. any .appex survives outside Payload/*.app/PlugIns/
#   2. any Info.plist still references AppMigrationExtension
#   3. any surviving bundle's CFBundleIdentifier differs from the reference IPA
#
# Usage: verify_ipa.sh <final.ipa> <reference_original.ipa>

set -uo pipefail

FINAL_IPA="${1:?usage: verify_ipa.sh <final.ipa> <reference_original.ipa>}"
REF_IPA="${2:?usage: verify_ipa.sh <final.ipa> <reference_original.ipa>}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAIL=0
fail() { echo "FAIL: $1"; FAIL=1; }
ok()   { echo "OK:   $1"; }

echo "== Unpacking =="
mkdir -p "$WORK/final" "$WORK/ref"
unzip -q "$FINAL_IPA" -d "$WORK/final"
unzip -q "$REF_IPA" -d "$WORK/ref"

FINAL_APP="$(find "$WORK/final/Payload" -maxdepth 1 -name '*.app' -type d | head -n1)"
REF_APP="$(find "$WORK/ref/Payload" -maxdepth 1 -name '*.app' -type d | head -n1)"

if [ -z "$FINAL_APP" ] || [ -z "$REF_APP" ]; then
  echo "FAIL: could not locate .app inside one of the IPAs"
  exit 1
fi

echo
echo "== Check 1: no .appex outside PlugIns/ =="
BAD_APPEX="$(find "$FINAL_APP" -name '*.appex' -type d | grep -v '/PlugIns/' || true)"
if [ -n "$BAD_APPEX" ]; then
  fail "found .appex outside PlugIns/:"
  printf '  %s\n' "$BAD_APPEX"
else
  ok "no .appex outside PlugIns/"
fi

echo
echo "== Check 2: no reference to AppMigrationExtension in config files (plist/entitlements) =="
# Scoped to actual configuration, excluding _CodeSignature/ and SC_Info/: those are
# Apple's signature-manifest and FairPlay metadata, regenerated/discarded on re-sign,
# not an extension declaration.
REFS="$(find "$FINAL_APP" \( -name '*.plist' -o -name '*.entitlements' \) \
          -not -path '*/_CodeSignature/*' -not -path '*/SC_Info/*' \
          -exec grep -l "AppMigrationExtension" {} \; 2>/dev/null || true)"
if [ -n "$REFS" ]; then
  fail "AppMigrationExtension still referenced in:"
  printf '  %s\n' "$REFS"
else
  ok "no AppMigrationExtension references remain"
fi

echo
echo "== Check 3: bundle IDs of surviving bundles must be unchanged vs reference =="
BUNDLE_ID_MISMATCH=0
# Parent app
REF_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$REF_APP/Info.plist" 2>/dev/null || echo "")"
FINAL_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$FINAL_APP/Info.plist" 2>/dev/null || echo "")"
if [ "$REF_ID" != "$FINAL_ID" ]; then
  fail "parent app CFBundleIdentifier changed: '$REF_ID' -> '$FINAL_ID'"
  BUNDLE_ID_MISMATCH=1
fi
# Every surviving appex must have the exact same id it had in the reference
while IFS= read -r final_appex; do
  name="$(basename "$final_appex")"
  ref_appex="$(find "$REF_APP" -name "$name" -type d | head -n1)"
  if [ -z "$ref_appex" ]; then
    fail "$name exists in final IPA but not in reference (unexpected new bundle)"
    BUNDLE_ID_MISMATCH=1
    continue
  fi
  ref_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$ref_appex/Info.plist" 2>/dev/null || echo "")"
  final_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$final_appex/Info.plist" 2>/dev/null || echo "")"
  if [ "$ref_id" != "$final_id" ]; then
    fail "$name CFBundleIdentifier changed: '$ref_id' -> '$final_id'"
    BUNDLE_ID_MISMATCH=1
  fi
done < <(find "$FINAL_APP" -name '*.appex' -type d)

if [ "$BUNDLE_ID_MISMATCH" -eq 0 ]; then
  ok "all bundle IDs match the reference IPA"
fi

echo
if [ "$FAIL" -eq 1 ]; then
  echo "==> VERIFICATION FAILED"
  exit 1
else
  echo "==> VERIFICATION PASSED"
  exit 0
fi
