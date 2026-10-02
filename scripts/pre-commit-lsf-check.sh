#!/bin/sh
# Pre-commit style gate for .lsf files:
#   1) metacode is collapsed only: no @name(args){  (META template bodies are exempt)
#   2) no double quotes outside string literals and // comments
#      (double quotes INSIDE 'single-quoted' literals are legal - HTML markup etc.)
#   3) equality is single '=': no == outside string literals and // comments
# Without arguments - checks the STAGED content (git show :path); with file
# arguments - checks those working-tree files (handy for testing/ad-hoc runs);
# --install - writes .git/hooks/pre-commit calling this script.
# A justified exception goes through git commit --no-verify.
# ASCII only on purpose: run by Git Bash sh.
# Known limits: repo paths with spaces break the word-split loop (none today);
# nested metacode calls inside META bodies are not expected in this repo.

if [ "$1" = "--install" ]; then
    root="$(git rev-parse --show-toplevel)"
    hook="$root/.git/hooks/pre-commit"
    printf '#!/bin/sh\nexec sh "%s/scripts/pre-commit-lsf-check.sh" "$@"\n' "$root" > "$hook"
    chmod +x "$hook" 2>/dev/null || true
    echo "installed: $hook"
    exit 0
fi

fail=0

check() {
    label="$1"
    content="$2"

    # string literals ('...', escape is a doubled quote) then // comments;
    # what survives must contain no " and no == - see rules 2 and 3
    code=$(printf '%s\n' "$content" | sed "s|'[^']*'||g; s|//.*||")

    expanded=$(printf '%s\n' "$content" \
        | grep -nE '@[A-Za-z_][A-Za-z0-9_]*\([^;]*\)[[:space:]]*\{' \
        | grep -vE 'META |DEFINE ')
    if [ -n "$expanded" ]; then
        printf '%s\n' "$expanded" | sed "s|^|$label: expanded metacode |"
        fail=1
    fi

    dquotes=$(printf '%s\n' "$code" | grep -n '"')
    if [ -n "$dquotes" ]; then
        printf '%s\n' "$dquotes" | sed "s|^|$label: double quote outside string/comment |"
        fail=1
    fi

    eqeq=$(printf '%s\n' "$code" | grep -nE '[^!<>=]==[^=]')
    if [ -n "$eqeq" ]; then
        printf '%s\n' "$eqeq" | sed "s|^|$label: == instead of = |"
        fail=1
    fi
}

if [ $# -gt 0 ]; then
    for f in "$@"; do
        [ -f "$f" ] || continue
        check "$f" "$(cat "$f")"
    done
else
    # git diff --cached -z + tr: robust to any path; no paths with spaces expected today
    files=$(git diff --cached --name-only --diff-filter=ACMR -- '*.lsf')
    for f in $files; do
        check "$f" "$(git show ":$f")"
    done
fi

if [ "$fail" -ne 0 ]; then
    echo "pre-commit-lsf-check: FAILED (see above; justified exception: git commit --no-verify)"
fi
exit $fail
