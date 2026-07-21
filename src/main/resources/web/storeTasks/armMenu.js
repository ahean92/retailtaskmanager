// Custom object view for the ARM (FORM storeTaskArm, OBJECTS m = ArmMenuItem CUSTOM
// 'armMenu'). Draws the home screen as a wms-style vertical LIST of menu items —
// a header plus one big, full-width, clickable row per item. A tap runs the row's
// `openMenuItem` action. The item set is data-driven and filtered per role on the
// server; this view just renders whatever rows it receives.
// No build step — plain global function on window (no-build custom-component path).
function armMenu() {
    return {
        render: function (element, controller) {
            var header = document.createElement('div');
            header.className = 'arm-header';

            var title = document.createElement('div');
            title.className = 'arm-title';
            title.textContent = 'Рабочее место';
            header.appendChild(title);

            var sub = document.createElement('div');
            sub.className = 'arm-sub';
            header.appendChild(sub);

            var listEl = document.createElement('div');
            listEl.className = 'arm-list';

            element.appendChild(header);
            element.appendChild(listEl);
            element.armList = listEl;
            element.armSub = sub;
        },
        update: function (element, controller, list) {
            var listEl = element.armList;
            while (listEl.firstChild) listEl.removeChild(listEl.firstChild);

            var rows = list || [];
            var badged = rows.filter(function (r) { return r.badge; })[0];
            element.armSub.textContent = badged ? ('Открытых задач: ' + badged.badge) : '';

            rows.forEach(function (row) {
                var item = document.createElement('div');
                item.className = 'arm-row';

                var icon = document.createElement('div');
                icon.className = 'arm-row-icon';
                icon.textContent = row.icon || '▪';
                item.appendChild(icon);

                var cap = document.createElement('div');
                cap.className = 'arm-row-cap';
                cap.textContent = row.title || '';
                item.appendChild(cap);

                if (row.badge !== null && row.badge !== undefined && row.badge !== '') {
                    var badge = document.createElement('div');
                    badge.className = 'arm-row-badge';
                    badge.textContent = row.badge;
                    item.appendChild(badge);
                }

                var chev = document.createElement('div');
                chev.className = 'arm-row-chevron';
                chev.textContent = '›';
                item.appendChild(chev);

                item.onclick = function () {
                    controller.changeProperty('openMenuItem', row);
                };
                listEl.appendChild(item);
            });
        }
    };
}
