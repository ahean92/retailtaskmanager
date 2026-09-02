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

    function activator(controller, name) {
        return function (event) {
            try {
                controller.activate(name, event);
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

    // ===== левый рельс =====
    window.PulseNav = function (props) {
        var h = react().createElement;
        var data = props.data || { root: [], byName: {} };
        var controller = props.controller;

        function item(entry, depth) {
            return h('button', {
                key: entry.name,
                type: 'button',
                className: 'pnav-item' + (entry.selected ? ' is-selected' : '')
                    + (depth > 1 ? ' is-nested' : '')
                    + (entry.elementClass ? ' ' + entry.elementClass : ''),
                onClick: activator(controller, entry.name)
            }, image(entry, 'pnav-ico'), caption(entry, 'pnav-cap'));
        }

        // Папка рисуется подписью раздела, а её пункты — сразу под ней, без
        // раскрытия: в макете разделы всегда открыты. Клик по заголовку всё же
        // оставлен рабочим — от выбора раздела зависит, какие элементы платформа
        // кладёт в «корзину» окна.
        function group(entry, depth) {
            return h('div', { key: entry.name, className: 'pnav-section' },
                h('button', {
                    type: 'button',
                    className: 'pnav-group' + (entry.selected ? ' is-selected' : ''),
                    onClick: activator(controller, entry.name)
                }, caption(entry, 'pnav-cap')),
                children(data, entry).map(function (kid) { return node(kid, depth + 1); })
            );
        }

        function node(entry, depth) {
            return entry.folder ? group(entry, depth) : item(entry, depth);
        }

        var list = roots(data);

        // Пустая «корзина» — штатное состояние (раздел ещё не выбран), и окно с
        // кастомным видом платформа не прячет, а отдаёт его нам. Рисуем пустоту явно,
        // иначе рельс выглядит сломанным.
        if (!list.length)
            return h('div', { className: 'pnav pnav-empty' }, 'Выберите раздел');

        return h('nav', { className: 'pnav' }, list.map(function (entry) { return node(entry, 0); }));
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
            return h('button', {
                key: entry.name,
                type: 'button',
                className: 'ptop-brand',
                onClick: activator(controller, entry.name)
            }, image(entry, 'ptop-mark'), caption(entry, 'ptop-word'));
        }));
    };

    // ===== верхняя панель: корневые разделы =====
    window.PulseRoot = function (props) {
        var h = react().createElement;
        var controller = props.controller;

        return h('nav', { className: 'ptop ptop-root' }, roots(props.data).map(function (entry) {
            return h('button', {
                key: entry.name,
                type: 'button',
                className: 'ptop-tab' + (entry.selected ? ' is-selected' : ''),
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
            // подпись платформа может отдать разметкой — для tooltip нужен текст
            var title = entry.caption ? entry.caption.replace(/<[^>]*>/g, '').trim() : entry.name;
            return h('button', {
                key: entry.name,
                type: 'button',
                className: 'ptop-act' + (entry.selected ? ' is-selected' : ''),
                title: title,
                'aria-label': title,
                onClick: activator(controller, entry.name)
            }, image(entry, 'ptop-ico'));
        }));
    };
})();
