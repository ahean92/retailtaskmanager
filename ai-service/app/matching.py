"""Отбор кандидатов по буквам: кого из присланного показать модели.

Зачем это здесь, а не в lsFusion. Сервер отбирает кандидатов по делу — объект рядом,
объект назван в тексте, на объекте есть роль у автора; это знание о предметной области,
и его место там. Но сервер не умеет дёшево сравнивать «магазин на Ленина» из фразы со
строкой «Санта на Ленина» из справочника: морфология, опечатки, разный порядок слов.
Здесь это стоит десяток строк на difflib и делается ровно перед тем, как собрать prompt.

Отбор — не решение. Кого бы мы ни оставили, окончательный выбор делает lsFusion:
модель называет id или подсказку, а разрешает их сервер по всему справочнику.
"""

import re
from difflib import SequenceMatcher
from typing import Callable, Iterable, List, Sequence, TypeVar

T = TypeVar("T")

_WORD = re.compile(r"[0-9a-zа-яё]+", re.IGNORECASE)

# Служебные слова: встречаются в каждой второй фразе и в половине названий магазинов,
# поэтому совпадение по ним не значит ничего, кроме шума в оценке.
STOP_WORDS = frozenset(
    """
    и в во на по до за из от с со у к не а но что как для при про об о the
    магазин магазине магазина маркет тц торговый точка объект объекте
    задача задачу задачи проверить проверка сделать поставить нужно надо
    сегодня завтра послезавтра утром днём днем вечером ночью срочно
    """.split()
)


def normalize(text: str) -> str:
    """ё→е и нижний регистр: «Артём» и «Артем» — один человек."""
    return (text or "").lower().replace("ё", "е")


def tokens(text: str, keep_stop_words: bool = False) -> List[str]:
    words = _WORD.findall(normalize(text))
    if keep_stop_words:
        return words
    return [w for w in words if len(w) > 2 and w not in STOP_WORDS]


def _word_score(query_word: str, cand_word: str) -> float:
    """Насколько слово из справочника похоже на слово из фразы.

    Три ступени, от дешёвой к дорогой: точное совпадение, общее начало (русский
    хвост «Иванову» / «Иванов» отваливается сам), и уже потом посимвольное сходство —
    оно ловит опечатки, но и ошибается чаще, поэтому вес у него ниже.
    """
    if query_word == cand_word:
        return 1.0
    shortest = min(len(query_word), len(cand_word))
    if shortest >= 4 and (query_word.startswith(cand_word[:shortest - 1])
                          or cand_word.startswith(query_word[:shortest - 1])):
        return 0.85
    ratio = SequenceMatcher(None, query_word, cand_word).ratio()
    return ratio * 0.7 if ratio >= 0.75 else 0.0


def similarity(query_words: Sequence[str], candidate: str) -> float:
    """Оценка кандидата: лучшее совпадение плюс надбавка за каждое следующее.

    Максимум, а не среднее: у «Санта на Ленина» три слова, из которых человек назовёт
    одно, и среднее утопило бы верного кандидата. Надбавка нужна, чтобы «Ленина 15»
    обошёл «Ленина», когда в запросе есть и то и другое.
    """
    cand_words = tokens(candidate)
    if not cand_words or not query_words:
        return 0.0
    scores = sorted(
        (max((_word_score(q, c) for q in query_words), default=0.0) for c in cand_words),
        reverse=True,
    )
    top = scores[0]
    if top == 0.0:
        return 0.0
    return min(1.0, top + sum(scores[1:3]) * 0.15)


def prune(
    items: Iterable[T],
    text: Callable[[T], str],
    query: str,
    limit: int,
    keep: Callable[[T], bool] = lambda _: False,
) -> List[T]:
    """Оставить самых похожих, сохранив порядок сервера при равных оценках.

    `keep` — кандидаты, которые остаются всегда, как бы ни легли буквы: объект, на
    котором человек стоит, обязан оказаться перед моделью, потому что «поставь
    проверку здесь» не содержит ни одного слова из его названия.
    """
    query_words = tokens(query)
    ranked = []
    for index, item in enumerate(items):
        score = 1.0 if keep(item) else similarity(query_words, text(item))
        ranked.append((-score, index, item))
    ranked.sort(key=lambda row: (row[0], row[1]))
    return [item for _, _, item in ranked[:limit]]
