#!/usr/bin/env bash
set -euo pipefail

# check-global-discipline.sh
# Verifies that every Core type referenced by extension packages via
# 'implements' or 'extends' is declared 'global' (not 'public').
# This catches the most common 2GP namespace-wall mistake.
# Compatible with bash 3+ (no associative arrays).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_DIR="$ROOT_DIR/packages/pulse-core/force-app/main/default/classes"
EXTENSION_DIRS=(
  "$ROOT_DIR/packages/pulse-ai-anthropic/force-app/main/default/classes"
  "$ROOT_DIR/packages/pulse-tools-core/force-app/main/default/classes"
  "$ROOT_DIR/packages/pulse-conversations-recall/force-app/main/default/classes"
  "$ROOT_DIR/packages/pulse-conversations-core/force-app/main/default/classes"
)

errors=0

# Build list of global type names in Core
CORE_GLOBALS=""
for f in "$CORE_DIR"/*.cls; do
  [[ ! -f "$f" ]] && continue
  classname="$(basename "$f" .cls)"
  if grep -Eq '^\s*global\s+(abstract\s+|virtual\s+)?(class|interface)\s+' "$f" 2>/dev/null; then
    CORE_GLOBALS="$CORE_GLOBALS $classname"
  fi
done

echo "Global types in pulse-core:$CORE_GLOBALS"
echo ""

is_global() {
  local name="$1"
  for g in $CORE_GLOBALS; do
    if [[ "$g" == "$name" ]]; then
      return 0
    fi
  done
  return 1
}

# Check extension classes that implement or extend a Core type
for dir in "${EXTENSION_DIRS[@]}"; do
  [[ ! -d "$dir" ]] && continue
  pkg_name="$(basename "$(dirname "$(dirname "$(dirname "$(dirname "$dir")")")")")"

  for f in "$dir"/*.cls; do
    [[ ! -f "$f" ]] && continue
    classname="$(basename "$f" .cls)"

    # Extract types after 'implements' or 'extends' keywords
    refs=$(grep -oE '(implements|extends)\s+[A-Za-z_][A-Za-z0-9_, ]+' "$f" 2>/dev/null | sed 's/^[a-z]*\s*//' || true)
    [[ -z "$refs" ]] && continue

    # Split comma-separated type list
    IFS=', ' read -ra type_list <<< "$refs"
    for ref_type in "${type_list[@]}"; do
      ref_type="$(echo "$ref_type" | xargs)"  # trim
      [[ -z "$ref_type" ]] && continue

      # Only check types that exist as a class file in Core
      core_file="$CORE_DIR/${ref_type}.cls"
      [[ ! -f "$core_file" ]] && continue

      if ! is_global "$ref_type"; then
        echo "ERROR: $pkg_name/$classname references Core type '$ref_type' which is 'public', not 'global'"
        errors=$((errors + 1))
      fi
    done
  done
done

if [[ $errors -gt 0 ]]; then
  echo ""
  echo "FAIL: $errors cross-package reference(s) to non-global Core types"
  exit 1
fi

echo "OK — all cross-package Core references are global"
