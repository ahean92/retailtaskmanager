// Kanban board rendering for the task board (a CUSTOM object component of the tasks form).
// storetaskkanban.js calls kanban(config) with accessors over the form's properties; everything
// else — the board/column scaffold, the cards, initials avatars, localized dates, drag-and-drop
// and the click preview popup (the Edit/Delete affordance; double-click also edits) — lives here.
// Adapted from the kanban component of lsfusion-solutions/mycompany (Apache 2.0).
//
// The scaffold is built once and survives updates: columns are rebuilt only when the status list
// itself changes. Cards are added, refilled, moved and removed through controller.diff(), so an
// update touches the cards that actually changed. Column nodes, and with them their scroll
// position, live as long as the scaffold; the single dragula instance lives as long as the component.

// deterministic hue from a string — same hashing the shift schedule / activity calendar use for
// avatars, so a person keeps the same colour across the app
function kanbanHueOf(str) {
    let h = 0;
    str = str || "?";
    for (let i = 0; i < str.length; i++) h = (h * 31 + str.charCodeAt(i)) % 360;
    return h;
}

function kanbanInitialsOf(str) {
    let parts = (str || "").trim().split(/\s+/).filter(Boolean);
    if (!parts.length) return "?";
    let s = parts[0][0] + (parts.length > 1 ? parts[parts.length - 1][0] : "");
    return s.toUpperCase();
}

function kanbanAvatar(el, name) {
    el.style.setProperty("--ahue", kanbanHueOf(name));
    el.textContent = kanbanInitialsOf(name);
}

// localized short weekday (Mon-first) and full month names in the browser locale, mirroring the
// activity calendar so kanban dates read the same as in Activities
let kanbanDateNamesCache;
function kanbanDateNames() {
    if (kanbanDateNamesCache !== undefined) return kanbanDateNamesCache;
    try {
        const cap = (s) => s ? s.charAt(0).toUpperCase() + s.slice(1) : s;
        const wd = [], mo = [];
        const fw = new Intl.DateTimeFormat(undefined, { weekday: "short" });
        for (let i = 0; i < 7; i++) wd.push(cap(fw.format(new Date(2024, 0, 1 + i)))); // 2024-01-01 is a Monday
        const fm = new Intl.DateTimeFormat(undefined, { month: "long" });
        for (let i = 0; i < 12; i++) mo.push(cap(fm.format(new Date(2024, i, 1))));
        kanbanDateNamesCache = { wd, mo };
    } catch (e) {
        kanbanDateNamesCache = null;
    }
    return kanbanDateNamesCache;
}

// "Чт, 18 Июнь 2026" — full localized date in the browser locale, like the activity calendar's date row
function kanbanFormatDate(dateVal) {
    const m = moment(dateVal);
    const names = kanbanDateNames();
    return names
        ? names.wd[(m.day() + 6) % 7] + ", " + m.date() + " " + names.mo[m.month()] + " " + m.year()
        : m.format("YYYY-MM-DD");
}

// "type : name" header text, omitting either side / the separator when absent
function kanbanHeader(type, name) {
    return (type ? type : "") + (name && type ? " : " : "") + (name ? name : "");
}

// Map an lsFusion Color id (see utils/Color.lsf) to a badge's colour classes. Base ids (warning,
// danger, secondary, …) use Bootstrap's solid .text-bg-*, which the web client bundles. The "*Subtle"
// ids (warningSubtle, dangerSubtle, …) have NO Bootstrap equivalent in the bundle — there is no
// .text-bg-*-subtle utility, and lsFusion ships neither .text-*-emphasis nor .border-*-subtle — so
// "text-bg-warningSubtle" matched nothing and the badge rendered with no colour. Subtle ids instead
// get the board's own .kanban-tag-subtle-* classes (defined in kanban.css), which paint from the
// --bs-*-bg-subtle vars (themed in dark mode where lsFusion defines them) with a fixed RGB fallback.
function kanbanBadgeClasses(id, fallback) {
    id = id || fallback;
    const subtle = /^(.+)Subtle$/.exec(id);
    if (subtle) return "kanban-tag-subtle kanban-tag-subtle-" + subtle[1];
    return "text-bg-" + id;
}

// The base Bootstrap colour name behind a Color id, dropping the "Subtle" suffix (warningSubtle ->
// warning). Used for the thin card left-accent and the popup top border, where a full-strength hue
// reads better than the near-invisible subtle tone (the soft fill is reserved for the badges).
function kanbanBaseColor(id) {
    return id ? id.replace(/Subtle$/, "") : id;
}

// a calendar-icon + localized-date row; `overdue` paints it red (used for a passed due date)
function kanbanDateRow(cls, dateVal, overdue) {
    let row = document.createElement("div");
    row.className = cls;
    if (overdue) row.classList.add("overdue");
    let icon = document.createElement("i");
    icon.className = "bi bi-calendar-event";
    row.appendChild(icon);
    let text = document.createElement("span");
    text.textContent = kanbanFormatDate(dateVal);
    row.appendChild(text);
    return row;
}

// after a drag, collect the new order of the cards in a column into a changeProperties batch.
// Orders are 1-based: the web client turns a JS 0 into NULL on its way to the server, so a card
// dropped at the top of a column would lose its order entirely if we sent 0.
function kanbanCollectReorder(batch, elements, key) {
    for (let i = 0; i < elements.length; i++)
        if (elements[i][key] && elements[i][key].currentOrder !== i + 1) {
            batch.properties.push("currentOrder");
            batch.objects.push(elements[i][key]);
            batch.values.push(i + 1);
        }
}

// Allowlist sanitizer for the stored rich-text description (RICHTEXT/HTML), shown in the card popup.
// Renders the Quill formatting while dropping scripts, event handlers, inline styles and unsafe URLs
// so stored markup can't execute. Parsing happens in a detached <template> whose content is inert (no
// scripts run, no images load); we rebuild from scratch keeping only allowed tags. Same sanitizer as
// the comments / activities components.
function kanbanSanitizeHtml(html) {
    const ALLOWED = { A: 1, B: 1, STRONG: 1, I: 1, EM: 1, U: 1, S: 1, P: 1, BR: 1, OL: 1, UL: 1, LI: 1, SPAN: 1, BLOCKQUOTE: 1, PRE: 1, CODE: 1, H1: 1, H2: 1, H3: 1, H4: 1 };
    const SAFE_HREF = /^(https?:|mailto:|tel:|#|\/)/i;
    const tpl = document.createElement("template");
    tpl.innerHTML = String(html == null ? "" : html);
    const clean = (src, dst) => {
        for (const node of Array.from(src.childNodes)) {
            if (node.nodeType === 3) {
                dst.appendChild(document.createTextNode(node.nodeValue));
            } else if (node.nodeType === 1 && ALLOWED[node.tagName]) {
                const el = document.createElement(node.tagName);
                if (node.getAttribute("class")) el.setAttribute("class", node.getAttribute("class"));
                if (node.tagName === "A") {
                    const href = (node.getAttribute("href") || "").trim();
                    if (SAFE_HREF.test(href)) {
                        el.setAttribute("href", href);
                        el.setAttribute("target", "_blank");
                        el.setAttribute("rel", "noopener noreferrer");
                    }
                }
                clean(node, el);
                dst.appendChild(el);
            } else if (node.nodeType === 1) {
                clean(node, dst); // disallowed tag: keep its sanitized children, drop the wrapper
            }
        }
    };
    const out = document.createElement("div");
    clean(tpl.content, out);
    return out.innerHTML;
}

// config = {
//   key,            // "task" — the field stored on the card element, used by drop/reorder/refill
//   createStatus,   // action alias to create a new item in a status column
//   header(item)   -> string,             // card header (type : object); falsy = no header
//   subtitle(item) -> string,             // muted title line (author)
//   text(item)     -> string,             // main line (name); falsy/absent = no line
//   created(item)  -> date|null,          // creation date at the top, never highlighted
//   assignee(item) -> string,             // assignee name (initials avatar + name); falsy = no block
//   due(item)      -> date|null,          // due date footer, red once it has passed
//   status(item)   -> string,             // popup only: status-name pill
//   priority(item) -> string,             // popup only: priority name (coloured via item.idColorPriority)
//   description(item) -> string|null,     // popup only: rich-text (HTML), sanitized before render
//   canDrop(item, statusId) -> boolean,   // may the card move to that status column (a workflow rule
//                                         //   on the server); absent = any open column accepts it
//   canClose(item) -> boolean,            // may the card be dropped into a closed column, i.e. be
//                                         //   closed from the board; absent = closed columns are
//                                         //   read-only for every card
// }
function kanban(config) {
    const key = config.key;

    // ---- click popup ("красивая форма-подсказка", mirroring the activity calendar's .acal-pop) ----
    // One popup element is reused for every card. Clicking a card opens it; it previews the card and
    // exposes only the two quick actions the user asked for — Edit and Delete. It stays open until the
    // user clicks outside it, scrolls the board, drags a card, or runs an action.
    function hidePopup(st) {
        st.pop.style.display = "none";
        st.popCard = null;
    }

    // Bootstrap theme colour for a priority, matching the card's left-accent mapping in kanban.css,
    // used here for the popup's top border so it reads as the same card.
    const PRIO_VAR = { danger: "--bs-danger", warning: "--bs-warning", success: "--bs-success",
                       info: "--bs-info", primary: "--bs-primary", secondary: "--bs-secondary" };

    function popButton(cls, icon, label, title, onClick) {
        let b = document.createElement("button");
        b.type = "button";
        b.className = "kanban-pop-btn " + cls;
        if (title) b.title = title;
        let i = document.createElement("i");
        i.className = icon;
        b.appendChild(i);
        if (label) { let s = document.createElement("span"); s.textContent = label; b.appendChild(s); }
        b.addEventListener("click", onClick);
        return b;
    }

    function showPopup(st, item, anchor) {
        const i18n = st.i18n || {};
        const pop = st.pop;
        pop.className = "kanban-pop";
        const prioColor = kanbanBaseColor(item.idColorPriority);
        pop.style.borderTopColor = (prioColor && PRIO_VAR[prioColor])
            ? "var(" + PRIO_VAR[prioColor] + ")" : "var(--bs-primary, #2563eb)";
        pop.innerHTML = "";

        // header (type : object) as a quiet uppercase label
        let header = config.header(item);
        if (header) {
            let h = document.createElement("div");
            h.className = "kanban-pop-type";
            h.textContent = header;
            pop.appendChild(h);
        }

        // status + priority badges (status is a neutral pill; priority is tinted with its colour)
        let statusName = config.status ? config.status(item) : null;
        let priorityName = config.priority ? config.priority(item) : null;
        if (statusName || priorityName) {
            let badges = document.createElement("div");
            badges.className = "kanban-pop-badges";
            if (statusName) {
                let b = document.createElement("span");
                b.className = "kanban-pop-status";
                b.textContent = statusName;
                badges.appendChild(b);
            }
            if (priorityName) {
                let b = document.createElement("span");
                b.className = "kanban-pop-prio badge rounded-pill " + kanbanBadgeClasses(item.idColorPriority, "secondary");
                b.textContent = priorityName;
                badges.appendChild(b);
            }
            pop.appendChild(badges);
        }

        // subtitle (author)
        let subtitle = config.subtitle(item);
        if (subtitle) {
            let s = document.createElement("div");
            s.className = "kanban-pop-subtitle";
            s.textContent = subtitle;
            pop.appendChild(s);
        }

        // main text (task name)
        let text = config.text ? config.text(item) : null;
        if (text != null && text !== "") {
            let t = document.createElement("div");
            t.className = "kanban-pop-title";
            t.textContent = text;
            pop.appendChild(t);
        }

        // created / due dates (due turns red once it has passed)
        let meta = document.createElement("div");
        meta.className = "kanban-pop-meta";
        let created = config.created(item);
        if (created)
            meta.appendChild(kanbanDateRow("kanban-pop-row", created, false));
        let due = config.due(item);
        if (due) {
            let overdue = moment(due).isBefore(moment(), "day");
            meta.appendChild(kanbanDateRow("kanban-pop-row", due, overdue));
        }
        if (meta.childElementCount) pop.appendChild(meta);

        let assignee = config.assignee ? config.assignee(item) : null;
        if (assignee) {
            let row = document.createElement("div");
            row.className = "kanban-pop-assignee";
            let avatar = document.createElement("span");
            avatar.className = "kanban-card-avatar";
            kanbanAvatar(avatar, assignee);
            row.appendChild(avatar);
            let name = document.createElement("span");
            name.className = "kanban-pop-assignee-name";
            name.textContent = assignee;
            row.appendChild(name);
            pop.appendChild(row);
        }

        // tags
        if (item.tags && item.tags.length) {
            let tags = document.createElement("div");
            tags.className = "kanban-pop-tags";
            for (const tag of item.tags) {
                let badge = document.createElement("span");
                badge.className = "kanban-card-tag badge rounded-pill " + kanbanBadgeClasses(tag.idColor, "secondary");
                badge.textContent = tag.name;
                tags.appendChild(badge);
            }
            pop.appendChild(tags);
        }

        // description (RICHTEXT/HTML) — sanitized; skipped when it's empty rich-text (e.g. "<p><br></p>")
        let description = config.description ? config.description(item) : null;
        if (description) {
            let clean = kanbanSanitizeHtml(description);
            let probe = document.createElement("div");
            probe.innerHTML = clean;
            if (probe.textContent.trim()) {
                let d = document.createElement("div");
                d.className = "kanban-pop-desc ql-editor ql-bubble";
                d.innerHTML = clean;
                pop.appendChild(d);
            }
        }

        let editLabel = i18n.edit || "Edit";
        let deleteLabel = i18n.delete || "Delete";
        let actions = document.createElement("div");
        actions.className = "kanban-pop-actions";
        actions.appendChild(popButton("kanban-pop-edit", "bi bi-pencil", editLabel, editLabel, function () {
            let popped = st.popCard;
            hidePopup(st);
            if (popped) st.controller.changeProperty("edit", popped[key]);
        }));
        if (!config.canDelete || config.canDelete(item))
            actions.appendChild(popButton("kanban-pop-delete", "bi bi-trash", "", deleteLabel, function () {
                let popped = st.popCard;
                hidePopup(st);
                if (popped) st.controller.changeProperty("delete", popped[key]);
            }));
        pop.appendChild(actions);

        // position next to the card (fixed → not clipped by the board/column overflow), flipping to
        // the card's left and clamping vertically so it always stays on-screen
        pop.style.display = "block";
        const ar = anchor.getBoundingClientRect();
        const pw = pop.offsetWidth, ph = pop.offsetHeight;
        const vw = window.innerWidth, vh = window.innerHeight;
        let left = ar.right + 8;
        if (left + pw > vw - 6) left = ar.left - pw - 8;
        if (left < 6) left = Math.max(6, (vw - pw) / 2);
        let top = ar.top - 2;
        if (top + ph > vh - 6) top = Math.max(6, vh - ph - 6);
        if (top < 6) top = 6;
        pop.style.left = Math.round(left) + "px";
        pop.style.top = Math.round(top) + "px";
        st.popCard = anchor;
    }

    function buildCard(st, item) {
        let card = document.createElement("div");
        card.classList.add("kanban-card");
        card.classList.add("card");
        // a click selects the card and opens its popup (no standard edit dialog); the popup
        // and double-click are the edit/delete affordances
        card.addEventListener("click", function () {
            st.controller.changeObject(card[key], true, card);
            showPopup(st, card[key], card);
        });
        card.addEventListener("dblclick", function () {
            hidePopup(st);
            st.controller.changeProperty("edit", card[key]);
        });
        fillCard(st, card, item);
        return card;
    }

    function cardSignature(item) {
        return JSON.stringify([config.header(item), config.subtitle(item),
            config.text ? config.text(item) : null, config.created(item), config.due(item),
            config.assignee(item), item.tags, item.idColorPriority]);
    }

    function fillCard(st, card, item) {
        card[key] = item;

        const signature = cardSignature(item);
        if (card.kanbanSignature === signature) return;
        card.kanbanSignature = signature;

        for (const cls of Array.from(card.classList))
            if (cls.indexOf("text-bg-") === 0) card.classList.remove(cls);
        if (item.idColorPriority) card.classList.add("text-bg-" + kanbanBaseColor(item.idColorPriority));

        while (card.lastElementChild) card.removeChild(card.lastElementChild);

        let header = config.header(item);
        if (header) {
            let h = document.createElement("h5");
            h.classList.add("kanban-card-header");
            h.classList.add("card-header");
            h.textContent = header;
            card.appendChild(h);
        }

        let content = document.createElement("ul");
        content.classList.add("kanban-card-content");
        content.classList.add("list-group");
        content.classList.add("list-group-flush");
        card.appendChild(content);

        let body = document.createElement("li");
        body.classList.add("kanban-card-body");
        body.classList.add("list-group-item");
        content.appendChild(body);

        // creation date at the top — same format as the due date, never highlighted
        let created = config.created(item);
        if (created)
            body.appendChild(kanbanDateRow("kanban-card-created", created, false));

        let subtitle = config.subtitle(item);
        if (subtitle) {
            let s = document.createElement("h6");
            s.classList.add("kanban-card-subtitle");
            s.classList.add("card-title");
            s.classList.add("text-body-secondary");
            s.textContent = subtitle;
            body.appendChild(s);
        }

        let text = config.text ? config.text(item) : null;
        if (text != null && text !== "") {
            let t = document.createElement("div");
            t.classList.add("kanban-card-text");
            t.classList.add("card-text");
            t.textContent = text;
            body.appendChild(t);
        }

        if (item.tags) {
            let tags = document.createElement("li");
            tags.classList.add("kanban-card-tags");
            tags.classList.add("list-group-item");
            for (const tag of item.tags) {
                let badge = document.createElement("span");
                badge.className = "kanban-card-tag badge rounded-pill " + kanbanBadgeClasses(tag.idColor, "secondary");
                badge.textContent = tag.name;
                tags.appendChild(badge);
            }
            content.appendChild(tags);
        }

        // assignee block: only when someone is assigned, shown with an initials avatar
        let assignee = config.assignee(item);
        if (assignee) {
            let li = document.createElement("li");
            li.classList.add("kanban-card-assigned");
            li.classList.add("list-group-item");
            let avatar = document.createElement("span");
            avatar.classList.add("kanban-card-avatar");
            kanbanAvatar(avatar, assignee);
            li.appendChild(avatar);
            let name = document.createElement("span");
            name.classList.add("kanban-card-assigned-name");
            name.textContent = assignee;
            li.appendChild(name);
            content.appendChild(li);
        }

        let due = config.due(item);
        if (due) {
            let overdue = moment(due).isBefore(moment(), "day");
            let footer = kanbanDateRow("kanban-card-due", due, overdue);
            footer.classList.add("card-footer");
            card.appendChild(footer);
        }
    }

    function buildScaffold(element, st, statuses) {
        const board = element.kanban;
        hidePopup(st);
        while (board.lastElementChild) board.removeChild(board.lastElementChild);
        element.drake.containers.length = 0;
        element.kanbanNodes = [];
        element.kanbanCols = {};

        statuses.forEach(function (status, i) {
            let statusDiv = document.createElement("div");
            statusDiv.classList.add("kanban-status");
            if (i) statusDiv.classList.add("border-start");
            if (status.closed) statusDiv.classList.add("kanban-status-closed");

            let statusHeader = document.createElement("div");
            statusHeader.classList.add("kanban-status-header");
            statusDiv.appendChild(statusHeader);

            let statusName = document.createElement("div");
            statusName.classList.add("kanban-status-name");
            statusName.classList.add("h5");
            statusName.textContent = status.name;
            statusHeader.appendChild(statusName);

            // count badge (how many cards are in this column)
            let statusCount = document.createElement("span");
            statusCount.classList.add("kanban-status-count");
            statusCount.classList.add("badge");
            statusCount.classList.add("rounded-pill");
            statusHeader.appendChild(statusCount);

            if (!status.closed) {
                let statusNew = document.createElement("button");
                statusNew.classList.add("kanban-status-new");
                statusNew.classList.add("btn");
                statusNew.classList.add("btn-light");
                statusNew.innerHTML = "<i class=\"bi bi-plus\"></i>";
                statusHeader.appendChild(statusNew);
                statusNew.addEventListener("click", function () {
                    st.controller.form.exec(config.createStatus, status.id);
                });
            }

            let statusBody = document.createElement("div");
            statusBody.classList.add("kanban-status-body");
            statusBody.status = status;
            statusDiv.appendChild(statusBody);

            element.drake.containers.push(statusBody);
            board.appendChild(statusDiv);
            element.kanbanCols[String(status.id)] = { body: statusBody, count: statusCount };
        });
    }

    function layout(element) {
        const cols = element.kanbanCols;
        const byCol = {};
        for (const node of element.kanbanNodes) {
            let id = String(node[key].status);
            if (cols[id]) node.kanbanColumn = id;
            else id = node.kanbanColumn;
            if (!id) continue;
            (byCol[id] || (byCol[id] = [])).push(node);
        }
        for (const id in cols) {
            const body = cols[id].body;
            const wanted = byCol[id] || [];
            let ref = body.firstChild;
            for (const node of wanted) {
                if (ref === node) { ref = ref.nextSibling; continue; }
                body.insertBefore(node, ref);
            }
            while (ref) {
                const next = ref.nextSibling;
                body.removeChild(ref);
                ref = next;
            }
            cols[id].count.textContent = wanted.length;
        }
    }

    const AUTO_SCROLL_EDGE = 48;
    const AUTO_SCROLL_STEP = 14;

    function startAutoScroll(element) {
        stopAutoScroll(element);
        const scroll = { x: 0, y: 0, frame: 0 };
        scroll.onMove = function (e) {
            const p = e.touches && e.touches.length ? e.touches[0] : e;
            scroll.x = p.clientX;
            scroll.y = p.clientY;
        };
        scroll.tick = function () {
            for (const id in element.kanbanCols) {
                const body = element.kanbanCols[id].body;
                const r = body.getBoundingClientRect();
                if (scroll.x < r.left || scroll.x > r.right) continue;
                if (scroll.y > r.bottom - AUTO_SCROLL_EDGE && scroll.y < r.bottom + AUTO_SCROLL_EDGE)
                    body.scrollTop += AUTO_SCROLL_STEP;
                else if (scroll.y < r.top + AUTO_SCROLL_EDGE && scroll.y > r.top - AUTO_SCROLL_EDGE)
                    body.scrollTop -= AUTO_SCROLL_STEP;
                break;
            }
            scroll.frame = requestAnimationFrame(scroll.tick);
        };
        document.addEventListener("mousemove", scroll.onMove);
        document.addEventListener("touchmove", scroll.onMove);
        scroll.frame = requestAnimationFrame(scroll.tick);
        element.kanbanAutoScroll = scroll;
    }

    function stopAutoScroll(element) {
        const scroll = element.kanbanAutoScroll;
        if (!scroll) return;
        cancelAnimationFrame(scroll.frame);
        document.removeEventListener("mousemove", scroll.onMove);
        document.removeEventListener("touchmove", scroll.onMove);
        element.kanbanAutoScroll = null;
    }

    return {
        render: function (element, controller) {
            element.classList.add("kanban-host");
            let board = document.createElement("div");
            board.classList.add("kanban");
            board.classList.add(key + "-kanban"); // entity hook for any board-specific css
            element.appendChild(board);
            element.kanban = board;
            element.kanbanNodes = [];
            element.kanbanCols = {};
            element.kanbanStatuses = null;
            element.kanbanOptionStatuses = null;

            // single popup, reused for every card. Appended to <body> (not `element`) so it
            // escapes the form's stacking contexts and panel/column overflow — otherwise the form's
            // own panels and filter fields paint over it. Fixed-positioned next to the clicked card.
            if (element.kanbanPop && element.kanbanPop.pop && element.kanbanPop.pop.parentNode)
                element.kanbanPop.pop.parentNode.removeChild(element.kanbanPop.pop); // guard a re-render
            let pop = document.createElement("div");
            pop.className = "kanban-pop";
            pop.style.display = "none";
            document.body.appendChild(pop);
            const st = { pop: pop, popCard: null, controller: controller, i18n: {} };
            // any scroll inside the board (capture also catches the column bodies) dismisses the popup,
            // since it's fixed-positioned and would otherwise float away from its card
            board.addEventListener("scroll", function () { hidePopup(st); }, true);
            // the popup opens on a card click, so a click anywhere outside it closes it. A click on
            // a card is skipped here (that card's own handler reopens the popup for it).
            const onDocClick = function (e) {
                if (st.pop.style.display === "none") return;
                if (st.pop.contains(e.target)) return;
                if (e.target.closest && e.target.closest(".kanban-card")) return;
                hidePopup(st);
            };
            document.addEventListener("click", onDocClick);
            element.kanbanDocClick = onDocClick;
            element.kanbanPop = st;

            if (element.drake) element.drake.destroy();
            // A column whose status is closed (status.closed) shows what was finished lately.
            // Nothing is dragged out of it (reopening belongs to the item itself), and a card is
            // dropped into it only when config.canClose allows that card: closing belongs to the
            // item's own flow (a task with a form closes by finishing the form), and a drop would
            // bypass it — except for whom the host lets close from the board.
            // A column the workflow does not allow for this card (config.canDrop) refuses the drop
            // while it is still being dragged, instead of the server refusing it after the drop;
            // reordering inside the card's own column is not a status change and is always allowed.
            element.drake = dragula({
                moves: function (el, source) { return !(source.status && source.status.closed); },
                revertOnSpill: true,
                accepts: function (el, target, source) {
                    if (target === source) return true;
                    if (target.status && target.status.closed
                            && !(config.canClose && el[key] && config.canClose(el[key])))
                        return false;
                    if (!config.canDrop || !el[key]) return true;
                    return config.canDrop(el[key], target.status.id);
                }
            });

            element.drake.on("drop", function (el, target) {
                if (!target || !target.status) return;
                // one changeProperties batch (orders first, status last) = one server request;
                // separate changeProperty calls would each go out as a request of their own.
                let batch = { properties: [], objects: [], values: [] };
                kanbanCollectReorder(batch, target.children, key);
                if (el[key].status !== target.status.id) {
                    batch.properties.push("status");
                    batch.objects.push(el[key]);
                    batch.values.push(target.status.id);
                }
                if (batch.properties.length)
                    st.controller.changeProperties(batch.properties, batch.objects, batch.values);
            });

            // while dragging: hide the popup, so it can't hang over a drop target, and scroll the
            // column under the pointer near its edge
            element.drake.on("drag", function () { hidePopup(st); startAutoScroll(element); });
            element.drake.on("dragend", function () { stopAutoScroll(element); });
        },

        update: function (element, controller, list, options) {
            const st = element.kanbanPop;
            st.controller = controller;
            if (options) {
                st.i18n = options.i18n || {};
                if (options.statuses) element.kanbanOptionStatuses = options.statuses;
            }

            const statuses = element.kanbanOptionStatuses || [];
            const signature = JSON.stringify(statuses.map(function (s) {
                return [s.id, s.name, s.closed ? 1 : 0];
            }));
            if (element.kanbanStatuses !== signature) {
                buildScaffold(element, st, statuses);
                element.kanbanStatuses = signature;
                controller.clearDiff();
            }

            const nodes = element.kanbanNodes;
            const held = {};
            controller.diff(list, function (type, index, item) {
                if (type === "remove") {
                    const node = nodes[index];
                    nodes.splice(index, 1);
                    if (!node) return;
                    if (st.popCard === node) hidePopup(st);
                    if (item && item.key != null) held[item.key] = node;
                    else if (node.parentNode) node.parentNode.removeChild(node);
                    return;
                }
                if (type === "add") {
                    const node = item && item.key != null ? held[item.key] : null;
                    if (node) {
                        delete held[item.key];
                        fillCard(st, node, item);
                    }
                    nodes.splice(index, 0, node || buildCard(st, item));
                    return;
                }
                const node = nodes[index];
                if (!node) {
                    nodes.splice(index, 0, buildCard(st, item));
                    return;
                }
                fillCard(st, node, item);
                if (st.popCard === node) showPopup(st, item, node);
            }, true, true);
            for (const k in held) {
                const node = held[k];
                if (st.popCard === node) hidePopup(st);
                if (node.parentNode) node.parentNode.removeChild(node);
            }

            layout(element);
        },

        clear: function (element, controller) {
            stopAutoScroll(element);
            if (element.drake) { element.drake.destroy(); element.drake = null; }
            if (element.kanbanDocClick) document.removeEventListener("click", element.kanbanDocClick);
            if (element.kanbanPop) {
                hidePopup(element.kanbanPop);
                // the popup lives on <body>; remove it so it doesn't outlive the board
                let p = element.kanbanPop.pop;
                if (p && p.parentNode) p.parentNode.removeChild(p);
            }
            if (controller && controller.clearDiff) controller.clearDiff();
            element.kanbanNodes = [];
            element.kanbanCols = {};
            element.kanbanStatuses = null;
            element.kanbanOptionStatuses = null;
        }
    };
}
