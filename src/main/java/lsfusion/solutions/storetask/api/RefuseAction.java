package lsfusion.solutions.storetask.api;

import lsfusion.server.language.ScriptingLogicsModule;
import lsfusion.server.logics.action.controller.context.ExecutionContext;
import lsfusion.server.logics.action.flow.LSFStatusException;
import lsfusion.server.logics.classes.ValueClass;
import lsfusion.server.logics.property.classes.ClassPropertyInterface;
import lsfusion.server.physics.dev.integration.internal.to.InternalAction;

/**
 * Отказ по существу — тем же исключением, что <code>throwException</code>, но с кодом ответа
 * 422 вместо 500.
 *
 * <p><code>throwException</code> статуса не несёт, поэтому отказ («задача не назначена», «бланк
 * уже завершён», констрейнт) и настоящий сбой (запрос к базе, NPE) приходили телефону одним
 * и тем же 500, и очередь не могла понять, ждать ли ей или показывать причину. Теперь 4xx —
 * ответ ручки по существу, 500 — сбой.
 *
 * <p>Статус ответу платформа берёт у исключения, если он у него есть
 * (<code>LSFStatusException</code> — <code>RemoteInternalException.status</code> —
 * <code>ExternalRequestHandler</code>), и 500 иначе. Так отвечает веб-клиент, через который
 * ходят телефоны, на 6.2 и на master; встроенный HTTP сервера приложений (порт
 * <code>http.port</code>) на 6.2 отвечает 500 на любое исключение — там отказ узнаётся по
 * классу <code>LSFStatusException</code> в тексте ответа (<code>api_client.dart</code>).
 *
 * <p>Всё остальное — как у <code>throwException</code>: исключение прерывает действие и
 * откатывает сессию, текст тот же, <code>TRY … CATCH</code> его ловит
 * (<code>LSFStatusException</code> — наследник <code>LSFException</code>). С пустым
 * сообщением действие не зовётся вовсе: платформа не исполняет INTERNAL с NULL-параметром.
 */
public class RefuseAction extends InternalAction {

    /** Unprocessable Content: запрос понят, но выполнить его по правилам нельзя. */
    public static final int STATUS = 422;

    public RefuseAction(ScriptingLogicsModule LM, ValueClass... classes) {
        super(LM, classes);
    }

    @Override
    protected void executeInternal(ExecutionContext<ClassPropertyInterface> context) {
        throw new LSFStatusException((String) context.getSingleKeyObject(), STATUS);
    }
}
