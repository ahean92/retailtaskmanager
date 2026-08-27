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
        description: function (t) { return t.description; }
    });
}
