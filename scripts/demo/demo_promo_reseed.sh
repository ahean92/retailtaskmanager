#!/usr/bin/env bash
# Пересев демо-promo на erp-стенде (база Санты): каталог -> остатки -> шаблоны ->
# гипотезы -> демо-заполнения -> прогоны. Скрипты идемпотентны, прогон повторяет
# только то, чего нет. Гипотезы на ЖИВОМ стенде обновляются новыми версиями
# (констрейнт «утверждённую версию править нельзя») — при смене кода проверки
# заводите версию руками или чистите гипотезы перед пересевом.
# Запуск из корня репо: bash scripts/demo/demo_promo_reseed.sh
set -e
cd "$(dirname "$0")/.."

for s in \
    demo_promo_01_catalog.lsf \
    demo_promo_02_barcodes.lsf \
    demo_promo_03_stock.lsf \
    demo_promo_04_expiry_template.lsf \
    demo_promo_05_withdraw.lsf \
    demo_promo_07_expiry_fillings.lsf \
    demo_promo_09_weigh.lsf \
    demo_promo_06_expired_hypothesis.lsf \
    demo_promo_10_weigh_hypothesis.lsf \
    demo_promo_08_run.lsf \
    demo_promo_11_weigh_run.lsf \
    demo_promo_12_promo_prep.lsf \
    demo_promo_13_maintenance.lsf \
    demo_promo_14_recall.lsf \
    demo_promo_15_quickaction.lsf \
; do
    echo "=== $s"
    bash scripts/demo/mcp-eval.sh "scripts/demo/$s" | tail -n +2
done
