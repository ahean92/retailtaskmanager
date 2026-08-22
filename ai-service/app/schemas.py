"""Контракт с lsFusion: что приезжает в сервис и что уезжает обратно.

Ответ намеренно ПЛОСКИЙ — ни одного вложенного объекта. Разбирает его lsFusion
(`IMPORT FROM JSONFILE ... TO()`), и вложенность там пришлось бы разбирать формой
импорта ради двух десятков скаляров.

Ключевое в контракте — пары «id + подсказка». Модель называет id, если узнала объект
в присланном списке, и подсказку («магазин на Ленина», «Иванову») — если не узнала.
Подсказку разрешает lsFusion по всему справочнику; выдумывать значения модели нельзя,
и пустая пара — это не ошибка, а повод задать вопрос.
"""

from typing import List, Optional

from pydantic import BaseModel, Field


class ObjectItem(BaseModel):
    id: str
    name: Optional[str] = None
    address: Optional[str] = None


class TaskTypeItem(BaseModel):
    id: str
    name: Optional[str] = None
    usesTemplate: Optional[bool] = None


class TemplateItem(BaseModel):
    code: str
    name: Optional[str] = None
    note: Optional[str] = None


class PerformerItem(BaseModel):
    id: str
    name: Optional[str] = None
    roles: Optional[str] = None
    openTasks: Optional[int] = None


class PriorityItem(BaseModel):
    id: str
    name: Optional[str] = None


class HistoryItem(BaseModel):
    """Шаг разговора: что человек сказал и о чём его после этого спросили."""

    step: Optional[int] = None
    text: Optional[str] = None
    question: Optional[str] = None


class DraftRequest(BaseModel):
    dialogId: Optional[str] = None
    step: Optional[int] = None
    text: str = ""
    today: Optional[str] = None
    now: Optional[str] = None
    author: Optional[str] = None
    atObjectId: Optional[str] = None
    atObjectName: Optional[str] = None

    objects: List[ObjectItem] = Field(default_factory=list)
    taskTypes: List[TaskTypeItem] = Field(default_factory=list)
    templates: List[TemplateItem] = Field(default_factory=list)
    performers: List[PerformerItem] = Field(default_factory=list)
    priorities: List[PriorityItem] = Field(default_factory=list)
    history: List[HistoryItem] = Field(default_factory=list)


class DraftResponse(BaseModel):
    """Плоский ответ. NULL-поля lsFusion просто не увидит — и это нормально."""

    outcome: str = "ok"  # ok | clarify | error

    taskName: Optional[str] = None
    typeId: Optional[str] = None
    typeHint: Optional[str] = None
    objectId: Optional[str] = None
    objectHint: Optional[str] = None
    performerId: Optional[str] = None
    performerHint: Optional[str] = None
    templateCode: Optional[str] = None
    templateHint: Optional[str] = None
    priorityId: Optional[str] = None
    deadline: Optional[str] = None
    photoRequired: Optional[bool] = None
    description: Optional[str] = None
    confidence: Optional[float] = None
    clarificationQuestion: Optional[str] = None

    # техническое — для журнала на стороне lsFusion
    model: Optional[str] = None
    llmMillis: Optional[int] = None
    raw: Optional[str] = None
    errorCode: Optional[str] = None
    error: Optional[str] = None


class HealthResponse(BaseModel):
    status: str
    llm: str  # up | down
    model: Optional[str] = None
    detail: Optional[str] = None
