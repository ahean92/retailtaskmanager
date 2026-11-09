#!/bin/bash
# Проверка без сервера: новая редакция шаблона и клон не теряют настроек.
#
# 1. У каждого DATA-свойства шаблона, раздела, поля, колонки и заготовки строки есть
#    правило копирования в шве copyTemplate/copySection/copyField/copyColumn/copyRow
#    (fillable/TemplateClone.lsf или шов модуля, объявившего свойство) либо запись в
#    списке исключений ниже — с причиной. Иначе редакция и клон молча теряют настройку:
#    так потерялись отдельный итог и порог раздела, «фото/комментарий обязательно» и
#    «уведомить выбранного» у поля.
# 2. У каждой ссылки DATA Template (X) есть перевод в шве rebindTemplate
#    (fillable/TemplateVersion.lsf) либо запись в списке исключений: при публикации новой
#    редакции такая ссылка либо перевешивается на неё, либо сознательно остаётся.
#
# Выход: 0 — всё решено, 1 — есть свойства без решения, 2 — проверка не состоялась.
set -euo pipefail
export LC_ALL=C
root="$(cd "$(dirname "$0")/.." && pwd)"
src="$root/src/main/lsfusion"
[ -d "$src" ] || { echo "не найден: $src" >&2; exit 2; }

# --- исключения: свойство уровня шаблона, которое НЕ копируется, и почему ---
copy_excluded="
Template.code             уникален: копия с тем же кодом не сохранится, редакция берёт код при публикации
Template.archived         копию заводят, чтобы ею пользоваться
Template.family           служебное поле редакции, ставит newVersion
Template.version          служебное поле редакции, ставит newVersion
Template.previousVersion  служебное поле редакции, ставит newVersion
Template.draft            служебное поле редакции, ставит newVersion
Section.template          структура: обход дерева ставит копии свой шаблон
Section.sortingOrder      порядок воспроизводит обход по index
Field.section             структура: обход дерева ставит копии свой раздел
Field.sortingOrder        порядок воспроизводит обход по index
Column.tableField         структура: обход дерева ставит копии своё поле
TemplateRow.tableField    структура: обход дерева ставит копии своё поле
"

# --- исключения: ссылка на шаблон, которая при публикации НЕ перевешивается, и почему ---
rebind_excluded="
AiRequest.template        журнал: по какому шаблону запрос был — это прошлое
Filling.template          документ: заполнение остаётся на редакции, по которой заполнено
Task.template             не начатые задачи переводит форма редакции (TemplateVersion), начатые — нельзя
TaskBatch.template        разовое действие, после создания задач не используется
Template.family           служебное поле редакции
Template.previousVersion  служебное поле редакции
Section.template          структура шаблона
"

levels='Template|Section|Field|Column|TemplateRow'

# DATA-свойства уровней шаблона: «Класс.имя файл:строка» (LOCAL — не данные шаблона)
declared=$(grep -rnE "^[[:space:]]*[A-Za-z_][A-Za-z_0-9]*[^=]*=[[:space:]]*DATA[[:space:]]+[^(]*\(($levels)\)" \
        --include='*.lsf' "$src" | grep -v 'DATA LOCAL' \
    | sed -E "s#^$src/##; s#^([^:]+):([0-9]+):[[:space:]]*([A-Za-z_][A-Za-z_0-9]*).*\(($levels)\).*#\4.\3 \1:\2#" \
    | sort -u -k1,1)

# Правила копирования: присваивания «имя(t) <-» внутри блоков copyX (… f, … t) + { … }
copied=$(find "$src" -name '*.lsf' -exec awk '
    /^copy(Template|Section|Field|Column|Row)[[:space:]]*\(/ && /\+[[:space:]]*\{/ {
        cls = $0; sub(/^copy/, "", cls); sub(/[[:space:]]*\(.*/, "", cls)
        if (cls == "Row") cls = "TemplateRow"
        inblk = 1; next
    }
    inblk && /^\}/ { inblk = 0; next }
    inblk {
        line = $0; sub(/\/\/.*/, "", line)
        if (match(line, /[A-Za-z_][A-Za-z_0-9]*\(t\)[[:space:]]*<-/)) {
            name = substr(line, RSTART, RLENGTH); sub(/\(t\).*/, "", name)
            print cls "." name
        }
    }' {} + | sort -u)

# Ссылки на шаблон: «Владелец.имя файл:строка»
refs=$(grep -rnE "^[[:space:]]*[A-Za-z_][A-Za-z_0-9]*[^=]*=[[:space:]]*DATA[[:space:]]+Template[[:space:]]*\([A-Za-z_][A-Za-z_0-9]*\)" \
        --include='*.lsf' "$src" \
    | sed -E "s#^$src/##; s#^([^:]+):([0-9]+):[[:space:]]*([A-Za-z_][A-Za-z_0-9]*).*DATA[[:space:]]+Template[[:space:]]*\(([A-Za-z_][A-Za-z_0-9]*)\).*#\4.\3 \1:\2#" \
    | sort -u -k1,1)

# Переводы: «template(Класс r) <- t» внутри блоков rebindTemplate (…) + { … }
rebound=$(find "$src" -name '*.lsf' -exec awk '
    /^rebindTemplate[[:space:]]*\(/ && /\+[[:space:]]*\{/ { inblk = 1; next }
    inblk && /^\}/ { inblk = 0; next }
    inblk && match($0, /[A-Za-z_][A-Za-z_0-9]*\([A-Za-z_][A-Za-z_0-9]*[[:space:]]+[A-Za-z_][A-Za-z_0-9]*\)[[:space:]]*<-/) {
        s = substr($0, RSTART, RLENGTH)
        name = s; sub(/\(.*/, "", name)
        cls = s; sub(/^[^(]*\(/, "", cls); sub(/[[:space:]].*/, "", cls)
        print cls "." name
    }' {} + | sort -u)

keys() { printf '%s\n' "$1" | awk 'NF { print $1 }' | sort -u; }

count() { if [ -n "$1" ]; then printf '%s\n' "$1" | sed '/^$/d' | wc -l | tr -d ' '; else echo 0; fi; }

echo "свойств шаблона, раздела, поля, колонки, строки: $(count "$declared")"
echo "из них с правилом копирования:                  $(count "$copied")"
echo "ссылок DATA Template:                           $(count "$refs")"
echo "из них переводятся при публикации:              $(count "$rebound")"

if [ -z "$declared" ] || [ -z "$copied" ] || [ -z "$refs" ] || [ -z "$rebound" ]; then
    echo "сверять нечего: пустая выборка — проверка не состоялась" >&2
    exit 2
fi

status=0

decided=$(printf '%s\n%s\n' "$copied" "$(keys "$copy_excluded")" | sed '/^$/d' | sort -u)
missing=$(comm -23 <(keys "$declared") <(printf '%s\n' "$decided"))
if [ -n "$missing" ]; then
    status=1
    echo
    echo "НЕ КОПИРУЮТСЯ и не в списке исключений (редакция и клон их потеряют):"
    while read -r k; do
        printf '  %-36s %s\n' "$k" "$(printf '%s\n' "$declared" | awk -v k="$k" '$1 == k { print $2; exit }')"
    done <<< "$missing"
    echo "  → добавить присваивание в шов copy* (fillable/TemplateClone.lsf или шов своего модуля)"
    echo "    либо строку с причиной в copy_excluded этого скрипта"
fi

stale=$(comm -12 <(keys "$copy_excluded") <(printf '%s\n' "$copied"))
gone=$(comm -23 <(keys "$copy_excluded") <(keys "$declared"))
if [ -n "$stale$gone" ]; then
    status=1
    echo
    echo "Список исключений копирования устарел:"
    [ -n "$stale" ] && printf '  %s — копируется, исключение лишнее\n' $stale
    [ -n "$gone" ] && printf '  %s — такого свойства больше нет\n' $gone
fi

decided_refs=$(printf '%s\n%s\n' "$rebound" "$(keys "$rebind_excluded")" | sed '/^$/d' | sort -u)
missing_refs=$(comm -23 <(keys "$refs") <(printf '%s\n' "$decided_refs"))
if [ -n "$missing_refs" ]; then
    status=1
    echo
    echo "ССЫЛКИ НА ШАБЛОН без решения при публикации редакции:"
    while read -r k; do
        printf '  %-36s %s\n' "$k" "$(printf '%s\n' "$refs" | awk -v k="$k" '$1 == k { print $2; exit }')"
    done <<< "$missing_refs"
    echo "  → реализация rebindTemplate (Template f, Template t) + { … } в модуле ссылки"
    echo "    либо строка с причиной в rebind_excluded этого скрипта"
fi

stale_refs=$(comm -12 <(keys "$rebind_excluded") <(printf '%s\n' "$rebound"))
gone_refs=$(comm -23 <(keys "$rebind_excluded") <(keys "$refs"))
if [ -n "$stale_refs$gone_refs" ]; then
    status=1
    echo
    echo "Список исключений перевода устарел:"
    [ -n "$stale_refs" ] && printf '  %s — перевешивается, исключение лишнее\n' $stale_refs
    [ -n "$gone_refs" ] && printf '  %s — такой ссылки больше нет\n' $gone_refs
fi

[ "$status" -eq 0 ] && { echo; echo "все свойства и ссылки решены"; }
exit "$status"
