// Отрисовка навигатора «Пульс»: левый рельс и три окна верхней панели.
//
// Каждое окно навигатора подключается отдельно (WINDOW ... CUSTOM 'Имя'), но данные
// и действия у всех одни и те же, поэтому компоненты живут в одном файле и делят
// разбор подписи, картинки и активацию.
//
//   props.data       = { root: [имена], byName: { имя: entry } }
//   entry            = { name, caption, image, elementClass, hidden, folder,
//                        selected, children: [имена] }
//   props.controller = { activate(canonicalName, event), exec, eval, change }
//
// Элементы перечисляются НЕ поимённо, а обходом root/children: состав меню у нас
// собирают модули, и компонент, знающий имена, устаревал бы с каждым новым.
//
// Мобильный вид сюда не попадает — GNavigatorController.getNavigatorWidgetView
// возвращает mobileViews раньше, чем доходит до кастомного. Механика открепления и
// всплытия тоже не наша: ReactNavigatorView наследует ParkedNavigatorView, мы
// заменяем только отрисовку.
(function () {
    "use strict";

    // React читается в момент отрисовки, а не загрузки файла: приложение может
    // подменить его ресурсом с меньшим порядком инициализации.
    function react() { return window.React; }

    // Подпись может быть и текстом, и разметкой: HEADER в PulseRail.lsf отдаёт
    // счётчик тегом. Правило распознавания — платформенное (тег где угодно внутри),
    // а не «первый символ <»: у подписи тег может стоять и в середине.
    function isHtml(value) {
        return window.containsHtmlTag ? window.containsHtmlTag(value) : /<[a-z/!]/i.test(value);
    }

    // Текст подписи без разметки — нужен для поиска, подсказки и aria-label.
    function plain(entry) {
        var value = entry.caption || '';
        return value.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim();
    }

    // Подпись всегда одинаковой формы: строка-флекс, внутри название отдельным
    // .pulse-title. Обычную оборачиваем здесь, размеченную (со счётчиком) отдаёт уже
    // обёрнутой HEADER. Иначе название остаётся текстовым узлом, и обрезать его
    // многоточием нечем — в узком рельсе оно просто уезжает под край окна.
    function caption(entry, className) {
        var h = react().createElement;
        var value = entry.caption;
        if (!value) return null;
        return isHtml(value)
            ? h('span', { className: className, dangerouslySetInnerHTML: { __html: value } })
            : h('span', { className: className }, h('span', { className: 'pulse-title' }, value));
    }

    // Иконку платформа отдаёт двумя способами: готовым элементом (у шрифтовой иконки
    // адреса нет вовсе) и адресом картинки. Различаются по ведущему '<', которого у
    // адреса не бывает.
    function image(entry, className) {
        var h = react().createElement;
        var value = entry.image;
        if (!value) return null;
        if (value.charAt(0) === '<')
            return h('span', { className: className, dangerouslySetInnerHTML: { __html: value } });
        return h('img', { className: className, src: value, alt: '' });
    }

    function activator(controller, name, after) {
        return function (event) {
            try {
                controller.activate(name, event);
                if (after) after(name);
            } catch (e) {
                // activate бросает на скрытом или несуществующем элементе. Роняя
                // рендер, мы увели бы в ошибку всё окно (граница React снимает целый
                // корень), поэтому здесь только в консоль.
                window.console.error('PulseNav: не удалось открыть ' + name, e);
            }
        };
    }

    // Видимые элементы окна в порядке, который дала платформа.
    function roots(data) {
        var byName = (data && data.byName) || {};
        return ((data && data.root) || [])
            .map(function (name) { return byName[name]; })
            .filter(function (entry) { return entry && !entry.hidden; });
    }

    function children(data, entry) {
        var byName = data.byName || {};
        return (entry.children || [])
            .map(function (name) { return byName[name]; })
            .filter(function (kid) { return kid && !kid.hidden; });
    }

    // Свёрнутые разделы переживают перезагрузку: свернуть половину меню и получить
    // его развёрнутым обратно на каждом F5 — worse than useless. Хранилище может
    // быть недоступно (приватное окно, запрет на данные сайта), поэтому обе
    // операции защищены: недоступное хранилище означает «ничего не свёрнуто», а не
    // сломанный рельс.
    var COLLAPSED_KEY = 'pulse.nav.collapsed';

    function readCollapsed() {
        try {
            return JSON.parse(window.localStorage.getItem(COLLAPSED_KEY)) || {};
        } catch (e) {
            return {};
        }
    }

    function writeCollapsed(state) {
        try {
            window.localStorage.setItem(COLLAPSED_KEY, JSON.stringify(state));
        } catch (e) { /* не за что держаться — состояние живёт до перезагрузки */ }
    }

    // ===== левый рельс =====
    window.PulseNav = function (props) {
        var React = react();
        var h = React.createElement;
        var data = props.data || { root: [], byName: {} };
        var controller = props.controller;

        var queryState = React.useState('');
        var query = queryState[0], setQuery = queryState[1];

        var collapsedState = React.useState(readCollapsed);
        var collapsed = collapsedState[0], setCollapsed = collapsedState[1];

        // Какой пункт открыт, компонент помнит сам: selected в проекции платформа
        // выставляет на выбранную ВЕТКУ, а не на открытую форму, поэтому лист им не
        // подсвечивается. Состояние сессионное и не переживает перезагрузку — это
        // правда: после неё ни одна форма не открыта, и подсвечивать нечего.
        var openState = React.useState(null);
        var opened = openState[0], setOpened = openState[1];

        var needle = query.trim().toLowerCase();

        function matches(entry) {
            return !needle || plain(entry).toLowerCase().indexOf(needle) >= 0;
        }

        function toggle(name) {
            var next = {};
            for (var k in collapsed) next[k] = collapsed[k];
            next[name] = !next[name];
            setCollapsed(next);
            writeCollapsed(next);
        }

        function item(entry, depth) {
            var text = plain(entry);
            return h('button', {
                key: entry.name,
                type: 'button',
                // подсказка целиком — в узком рельсе длинное название обрезается
                // многоточием, и прочитать его иначе негде
                title: text,
                className: 'pnav-item'
                    + (entry.selected || opened === entry.name ? ' is-selected' : '')
                    + (depth > 1 ? ' is-nested' : '')
                    + (entry.elementClass ? ' ' + entry.elementClass : ''),
                onClick: activator(controller, entry.name, setOpened)
            }, image(entry, 'pnav-ico'), caption(entry, 'pnav-cap'));
        }

        // Раздел: подпись плюс пункты под ней. Клик по подписи активирует папку — от
        // выбора раздела зависит, что платформа кладёт в «корзину» окна, — а
        // сворачивание вынесено на отдельную кнопку-стрелку, иначе одно действие
        // отняло бы другое.
        function group(entry, depth) {
            var kids = children(data, entry).filter(matches);
            if (needle && !kids.length && !matches(entry)) return null;

            // при поиске раздел раскрыт всегда: иначе найденное осталось бы спрятанным
            var isCollapsed = !needle && !!collapsed[entry.name];

            return h('div', { key: entry.name, className: 'pnav-section' },
                h('div', { className: 'pnav-grouprow' },
                    h('button', {
                        type: 'button',
                        className: 'pnav-group' + (entry.selected ? ' is-selected' : ''),
                        onClick: activator(controller, entry.name)
                    }, caption(entry, 'pnav-cap')),
                    h('button', {
                        type: 'button',
                        className: 'pnav-toggle' + (isCollapsed ? ' is-collapsed' : ''),
                        title: isCollapsed ? 'Развернуть раздел' : 'Свернуть раздел',
                        'aria-label': isCollapsed ? 'Развернуть раздел' : 'Свернуть раздел',
                        'aria-expanded': isCollapsed ? 'false' : 'true',
                        onClick: function () { toggle(entry.name); }
                    })
                ),
                isCollapsed ? null : kids.map(function (kid) { return node(kid, depth + 1); })
            );
        }

        function node(entry, depth) {
            return entry.folder ? group(entry, depth) : (matches(entry) ? item(entry, depth) : null);
        }

        var list = roots(data);

        // Пустая «корзина» — штатное состояние (раздел ещё не выбран), и окно с
        // кастомным видом платформа не прячет, а отдаёт его нам. Рисуем пустоту явно,
        // иначе рельс выглядит сломанным.
        if (!list.length)
            return h('div', { className: 'pnav pnav-empty' }, 'Выберите раздел');

        var drawn = list.map(function (entry) { return node(entry, 0); }).filter(Boolean);

        // Фильтр показывается от десятка пунктов: на коротком меню он только отнимает
        // строку, глазами быстрее.
        var searchable = Object.keys(data.byName || {}).length >= 10;

        return h('div', { className: 'pnav' },
            searchable ? h('div', { className: 'pnav-search' },
                h('input', {
                    type: 'search',
                    className: 'pnav-input',
                    value: query,
                    placeholder: 'Поиск по меню',
                    'aria-label': 'Поиск по меню',
                    onChange: function (e) { setQuery(e.target.value); },
                    onKeyDown: function (e) { if (e.key === 'Escape') setQuery(''); }
                })
            ) : null,
            h('nav', { className: 'pnav-list' },
                drawn.length ? drawn
                    : h('div', { className: 'pnav-nothing' }, 'Ничего не найдено')
            )
        );
    };

    // ===== верхняя панель: логотип =====
    // В окне ровно один элемент — logoAction платформы. Фон красим сами: цвет окна
    // задаёт logoWindowClass, а он ABSTRACT с эксклюзивными сигнатурами и уже
    // реализован платформой — вторую реализацию добавить нельзя (проверено: старт
    // падает с «signature intersection of property»).
    window.PulseLogo = function (props) {
        var h = react().createElement;
        var controller = props.controller;

        return h('div', { className: 'ptop ptop-logo' }, roots(props.data).map(function (entry) {
            // logoHeader() отдаёт подпись только в мобильном и вертикальном режимах,
            // так что на десктопе её нет — имя задаём сами. Канонический идентификатор
            // сюда подставлять нельзя: «SystemEvents.logoAction» в качестве имени
            // кнопки хуже, чем его отсутствие.
            var title = plain(entry) || 'Пульс';
            return h('button', {
                key: entry.name,
                type: 'button',
                className: 'ptop-brand',
                'aria-label': title,
                onClick: activator(controller, entry.name)
            }, image(entry, 'ptop-mark'), caption(entry, 'ptop-word'));
        }));
    };

    // ===== верхняя панель: корневые разделы =====
    window.PulseRoot = function (props) {
        var h = react().createElement;
        var controller = props.controller;

        // Имя задаётся явно: подпись лежит во вложенном span, и доступное имя у
        // кнопки не вычисляется — в дереве доступности вкладки были безымянными.
        return h('nav', { className: 'ptop ptop-root' }, roots(props.data).map(function (entry) {
            var title = plain(entry);
            return h('button', {
                key: entry.name,
                type: 'button',
                className: 'ptop-tab' + (entry.selected ? ' is-selected' : ''),
                title: title || null,
                'aria-label': title || null,
                onClick: activator(controller, entry.name)
            }, image(entry, 'ptop-ico'), caption(entry, 'ptop-cap'));
        }));
    };

    // ===== верхняя панель: системные действия =====
    // Только иконки, подпись уходит в tooltip и aria-label: в макете правый край
    // шапки — ряд значков. Раньше подписи прятало платформенное правило по классу
    // navbar-text-hidden; у нашей разметки этого класса нет, поэтому решение
    // принимается здесь явно, а не достаётся по наследству.
    window.PulseSystem = function (props) {
        var h = react().createElement;
        var controller = props.controller;

        return h('nav', { className: 'ptop ptop-system' }, roots(props.data).map(function (entry) {
            var title = plain(entry);
            return h('button', {
                key: entry.name,
                type: 'button',
                className: 'ptop-act' + (entry.selected ? ' is-selected' : ''),
                title: title || null,
                'aria-label': title || null,
                onClick: activator(controller, entry.name)
            }, image(entry, 'ptop-ico'));
        }));
    };
})();
