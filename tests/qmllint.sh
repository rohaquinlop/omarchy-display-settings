#!/usr/bin/env bash
# QML lint with the accepted warning baseline.
#
# Two things make a naive `qmllint -I /usr/share/omarchy/shell *.qml` useless:
#
#   1. /usr/bin/qmllint on Arch is the *Qt5* binary (owned by qt5-declarative)
#      and exits 255 without a word on Qt6 QML. The Qt6 one lives under
#      /usr/lib/qt6/bin.
#   2. `qs.Ui` resolves to <importPath>/qs/Ui, but the shell ships that module
#      at <shell>/Ui. Pointing -I at the shell root leaves every qs.* type
#      unresolved, so the run "passes" while checking almost nothing. A shim
#      directory containing `qs -> <shell>` fixes it.
#
# Baseline: the first-party plugins themselves emit `missing-property`,
# `unqualified`, and `uncreatable-type` — `bar` is typed QtObject, the Style
# singleton's members are not statically known, and Quickshell's PanelWindow is
# not creatable from qmllint's point of view. Those are accepted. Any other
# warning class is a real finding and fails this script.

set -euo pipefail

SHELL_DIR="${OMARCHY_SHELL_DIR:-/usr/share/omarchy/shell}"
QMLLINT="${QMLLINT:-/usr/lib/qt6/bin/qmllint}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ACCEPTED="missing-property unqualified uncreatable-type"

if [[ ! -x $QMLLINT ]]; then
  echo "qmllint (Qt6) not found at $QMLLINT; set QMLLINT to override" >&2
  exit 127
fi
if [[ ! -d $SHELL_DIR/Ui ]]; then
  echo "Omarchy shell not found at $SHELL_DIR; set OMARCHY_SHELL_DIR to override" >&2
  exit 127
fi

shim="$(mktemp -d)"
trap 'rm -rf "$shim"' EXIT
ln -s "$SHELL_DIR" "$shim/qs"

mapfile -t files < <(find "$REPO" -maxdepth 1 -name '*.qml' | sort)
[[ ${#files[@]} -gt 0 ]] || { echo "no QML files found in $REPO" >&2; exit 1; }

output="$("$QMLLINT" -I "$shim" "${files[@]}" 2>&1 || true)"

# Anything that is not a warning line with an accepted category is a finding.
unexpected="$(
  grep '^Warning:' <<<"$output" | sed 's/.*\[\(.*\)\]$/\1/' | sort -u |
    while read -r category; do
      [[ " $ACCEPTED " == *" $category "* ]] || echo "$category"
    done
)"

grep '^Warning:' <<<"$output" | sed 's/.*\[\(.*\)\]$/\1/' | sort | uniq -c | sort -rn

if [[ -n $unexpected ]]; then
  echo
  echo "Unexpected qmllint warning categories:" >&2
  echo "$unexpected" >&2
  echo >&2
  grep -A3 -E "\[($(tr ' ' '|' <<<"$unexpected"))\]" <<<"$output" >&2 || true
  exit 1
fi

echo "qmllint: only baseline warning categories present"
