#!/bin/bash
set -euo pipefail
export LC_ALL=C
root="$(cd "$(dirname "$0")/.." && pwd)"
src="$root/src/main/lsfusion"
base="$root/src/main/resources/StoreTaskResourceBundle.properties"
en="$root/src/main/resources/StoreTaskResourceBundle_en.properties"
ru="$root/src/main/resources/StoreTaskResourceBundle_ru.properties"

for f in "$src" "$base" "$en" "$ru"; do
    [ -e "$f" ] || { echo "не найден: $f" >&2; exit 2; }
done

literals() {
    find "$src" -name '*.lsf' -exec awk '
        FNR == 1 { instr = 0 }
        {
            out = ""
            n = length($0)
            for (i = 1; i <= n; i++) {
                c = substr($0, i, 1)
                if (instr) {
                    if (c == "\\") { out = out c substr($0, i + 1, 1); i++; continue }
                    if (c == "\047") { instr = 0; out = out "\n"; continue }
                    out = out c
                } else {
                    if (c == "/" && substr($0, i + 1, 1) == "/") break
                    if (c == "\047") instr = 1
                }
            }
            if (out != "") print out
        }' {} +
}

bundle_keys() {
    { grep -oE '^[[:space:]]*[A-Za-z_][A-Za-z_0-9.]*[[:space:]]*[=:]' "$1" || true; } \
        | tr -d '=: \t' | sort -u
}

code=$(literals | { grep -oE '\{[A-Za-z_][A-Za-z_0-9.]*\}' || true; } | tr -d '{}' | sort -u)
bnd=$(bundle_keys "$base")
bnd_en=$(bundle_keys "$en")
eng=$(printf '%s\n%s\n' "$bnd" "$bnd_en" | sed '/^$/d' | sort -u)
tr_=$(bundle_keys "$ru")

count() { if [ -n "$1" ]; then printf '%s\n' "$1" | wc -l | tr -d ' '; else echo 0; fi; }
diffs() { comm "$1" <(printf '%s\n' "$2" | sed '/^$/d') <(printf '%s\n' "$3" | sed '/^$/d'); }
pick() { printf '%s\n' "$1" | { grep "$2" '^storeTask\.' || true; } | sed '/^$/d'; }

echo "ключей в коде:          $(count "$code")"
echo "ключей в базовом файле: $(count "$bnd")"
echo "ключей в _en:           $(count "$bnd_en")"
echo "ключей в переводе _ru:  $(count "$tr_")"

if [ -z "$code" ] || [ -z "$eng" ] || [ -z "$tr_" ]; then
    echo "сверять нечего: пустая выборка ключей — проверка не состоялась" >&2
    exit 2
fi

status=0
report() {
    local title="$1" list="$2"
    echo "--- $title:"
    if [ -n "$list" ]; then
        printf '%s\n' "$list"
        status=1
    fi
}
report "в коде есть, в базовом и _en нет" "$(diffs -23 "$code" "$eng")"
report "в базовом или _en есть, в коде нет" "$(diffs -13 "$code" "$eng")"
report "в базовом или _en есть, в _ru нет" "$(diffs -23 "$eng" "$tr_")"
report "в _ru есть, в базовом и _en нет" "$(diffs -13 "$eng" "$tr_")"
report "storeTask.* в базовом файле — место им в _en" "$(pick "$bnd" -e)"
report "без префикса storeTask. в _en — место им в базовом файле" "$(pick "$bnd_en" -v)"

if [ "$status" -eq 0 ]; then echo "расхождений нет"; else echo "есть расхождения" >&2; fi
exit "$status"
