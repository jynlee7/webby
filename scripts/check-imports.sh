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
      printf '%s\n' "AppKit SwiftUI Foundation CoreGraphics WebbyCore"
      ;;
    WebbyBridge)
      printf '%s\n' "Foundation WebbyCore"
      ;;
    WebbyCoreTests)
      # Darwin/Glibc are platform shims used behind #if canImport.
      printf '%s\n' "Testing Foundation CoreGraphics WebbyCore Darwin Glibc"
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

    if [[ "$rest" =~ ^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]+((struct|class|enum|func|var|let|typealias|protocol)[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*) ]]; then
      module="${BASH_REMATCH[4]}"
    else
      continue
    fi

    if [[ " $allowed " != *" $module "* ]]; then
      report "$file: target '$target' may not import '$module'"
    fi
  done < <(grep -rEn '^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]+' "$dir" || true)
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
  local block

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

  if printf '%s' "$block" | grep -Eq '\.(product|package)[[:space:]]*\('; then
    report "$package: WebbyCore must not declare a third-party package dependency"
  fi
}

check_imports "$sources"
check_imports "$tests"
check_macros
check_webbycore_dependencies

if [[ "$status" -ne 0 ]]; then
  exit 1
fi
echo "Imports and macros OK"
