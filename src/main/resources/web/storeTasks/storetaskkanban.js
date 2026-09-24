function storeTaskKanban() {
    return kanban({
        key: "task",
        createStatus: "createTaskStatus",
        header: function (t) { return kanbanHeader(t.nameType, t.nameObject); },
        subtitle: function (t) { return t.nameAuthor; },
        text: function (t) { return t.name; },
        status: function (t) { return t.nameStatus; },
        priority: function (t) { return t.namePriority; },
        created: function (t) { return { date: t.start, text: t.startText }; },
        due: function (t) { return { date: t.deadline, text: t.deadlineText }; },
        assignee: function (t) { return t.nameAssignedTo; },
        description: function (t) { return t.description; },
        // nextStatuses — статусы, в которые правила смены статуса (StoreTaskWorkflow) пускают
        // эту задачу для текущего пользователя; нет поля — ограничений нет
        canDrop: function (t, statusId) {
            return !t.nextStatuses || t.nextStatuses.some(function (s) { return s.id === statusId; });
        },
        // закрыть задачу с доски может её автор (closeOnBoard, StoreTaskKanban); остальные
        // закрывают её из карточки. Сервер держит то же правило в обработчике смены status
        canClose: function (t) { return !!t.closeOnBoard; }
    });
}
