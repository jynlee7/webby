#!/usr/bin/env bash
# Fail on imports outside a target's allowlist, a third-party package in WebbyCore,
# and macros that only ship with full Xcode (they break the Command Line Tools build).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sources="$root/mac/Sources"
tests="$root/mac/Tests"
package="$root/mac/Package.swift"

status=0

report() {
  printf 'check-imports: %s\n' "$*" >&2
  status=1
}

allowed_for() {
  case "$1" in
    WebbyCore)
      printf '%s\n' "Foundation CoreGraphics"
      ;;
    Webby)
      # OSLog: Logger keeps URLs and titles private in the unified log (plan.md §6.1).
      # Carbon: RegisterEventHotKey for the global New Note shortcut (plan.md Step 3b).
      # Observation: @Observable models such as LibraryModel (its plugin ships with the CLT).
      # WebKit: the locked-down Compiled view, app-only and never used by WebbyCore.
      printf '%s\n' "AppKit SwiftUI Foundation CoreGraphics OSLog Carbon Observation WebbyCore WebKit"
      ;;
    WebbyBridge)
      printf '%s\n' "Foundation WebbyCore"
      ;;
    WebbySkinArchive)
      # ImageIO and AVFAudio are decode-level checks in SkinAssetChecker (plan.md §5.4.6).
      printf '%s\n' "Foundation WebbyCore ZIPFoundation ImageIO AVFAudio"
      ;;
    WebbyAgent)
      # #24 keeps the agent tests-only and limited to Core (plan.md Step 12a).
      printf '%s\n' "Foundation WebbyCore"
      ;;
    WebbyCoreTests)
      # Darwin/Glibc are platform shims used behind #if canImport.
      printf '%s\n' "Testing Foundation CoreGraphics WebbyCore Darwin Glibc"
      ;;
    WebbySkinArchiveTests)
      printf '%s\n' "Testing Foundation CryptoKit WebbyCore WebbySkinArchive ZIPFoundation"
      ;;
    WebbyAgentTests)
      printf '%s\n' "Testing Foundation WebbyAgent WebbyCore"
      ;;
    WebbyTests)
      # WebKit is allowed only for direct compiled-view configuration and security tests.
      printf '%s\n' "Testing Foundation AppKit SwiftUI Webby WebbyCore WebKit"
      ;;
    *)
      return 1
      ;;
  esac
}

check_imports() {
  local dir="$1"
  local line file rest target allowed module

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    file="${line%%:*}"
    rest="${line#*:}"
    rest="${rest#*:}"

    case "$file" in
      "$sources"/*)
        target="${file#"$sources"/}"
        target="${target%%/*}"
        ;;
      "$tests"/*)
        target="${file#"$tests"/}"
        target="${target%%/*}"
        ;;
      *)
        continue
        ;;
    esac

    if ! allowed="$(allowed_for "$target")"; then
      report "$file: no import allowlist for target '$target'"
      continue
    fi

    # Allow any run of attributes (@testable, @preconcurrency, @_exported, ...)
    # before the import keyword, not just a leading @testable.
    if [[ "$rest" =~ ^[[:space:]]*((@[A-Za-z_][A-Za-z0-9_]*)[[:space:]]+)*import[[:space:]]+((struct|class|enum|func|var|let|typealias|protocol)[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*) ]]; then
      module="${BASH_REMATCH[5]}"
    else
      continue
    fi

    if [[ " $allowed " != *" $module "* ]]; then
      report "$file: target '$target' may not import '$module'"
    fi
  done < <(grep -rEn '^[[:space:]]*((@[A-Za-z_][A-Za-z0-9_]*)[[:space:]]+)*import[[:space:]]+' "$dir" || true)
}

check_macros() {
  local matches line

  matches="$(grep -rnE '@Entry|@Previewable|#Preview|@Model' "$sources" "$tests" || true)"
  if [[ -n "$matches" ]]; then
    while IFS= read -r line; do
      report "$line: @Entry, @Previewable, #Preview and @Model need full Xcode"
    done <<< "$matches"
  fi
}

check_webbycore_dependencies() {
  local block deps

  block="$(awk '
    function parens(s,    t) {
      t = s
      return gsub(/\(/, "(", t) - gsub(/\)/, ")", t)
    }
    /\.target[[:space:]]*\(/ {
      collecting = 1
      buf = $0 ORS
      depth = parens($0)
      if (depth <= 0) {
        if (buf ~ /name[[:space:]]*:[[:space:]]*"WebbyCore"/) print buf
        collecting = 0
        buf = ""
      }
      next
    }
    collecting {
      buf = buf $0 ORS
      depth += parens($0)
      if (depth <= 0) {
        if (buf ~ /name[[:space:]]*:[[:space:]]*"WebbyCore"/) print buf
        collecting = 0
        buf = ""
      }
    }
  ' "$package")"

  [[ -z "$block" ]] && return 0

  deps="$(printf '%s\n' "$block" | awk '
    function brackets(s,    t) {
      t = s
      return gsub(/\[/, "[", t) - gsub(/\]/, "]", t)
    }
    /dependencies[[:space:]]*:/ {
      line = $0
      sub(/^.*dependencies[[:space:]]*:[[:space:]]*/, "", line)
      buf = line
      depth = brackets(line)
      collecting = (depth > 0)
      if (depth <= 0) { print buf; buf = "" }
      next
    }
    collecting {
      buf = buf " " $0
      depth += brackets($0)
      if (depth <= 0) { print buf; collecting = 0; buf = "" }
    }
  ')"

  if printf '%s' "$deps" | grep -Eq '\.(product|package)[[:space:]]*\('; then
    report "$package: WebbyCore must not declare a third-party package dependency"
    return 0
  fi

  # SwiftPM also accepts a product as a plain string ("SomePackage") or as
  # .byName("SomePackage"), so inspect the dependencies list for those forms.
  local names entry
  # WebbyCore may depend only on the pre-existing dependency-free local targets.
  # In particular, allowing WebbySkinArchive here would let ZIPFoundation leak into Core.
  local localTargets=" WebbyCore Webby WebbyBridge WebbyCoreTests "
  names="$(printf '%s\n' "$deps" | grep -oE '\.byName[[:space:]]*\([[:space:]]*"[^"]*"|"[^"]*"' | sed -E 's/^\.byName[[:space:]]*\([[:space:]]*"//; s/^"//; s/"$//' || true)"

  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    case "$localTargets" in
      *" $entry "*) ;;
      *) report "$package: WebbyCore dependency '$entry' is not a local target" ;;
    esac
  done <<< "$names"
}

check_imports "$sources"
check_imports "$tests"
check_macros
check_webbycore_dependencies

if [[ "$status" -ne 0 ]]; then
  exit 1
fi
echo "Imports and macros OK"
