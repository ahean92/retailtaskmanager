package lsfusion.solutions.storetask.push;

import lsfusion.server.data.sql.exception.SQLHandledException;
import lsfusion.server.language.ScriptingErrorLog;
import lsfusion.server.language.ScriptingLogicsModule;
import lsfusion.server.logics.action.controller.context.ExecutionContext;
import lsfusion.server.logics.classes.ValueClass;
import lsfusion.server.logics.property.classes.ClassPropertyInterface;
import lsfusion.server.physics.dev.integration.internal.to.InternalAction;

import java.nio.charset.StandardCharsets;
import java.security.KeyFactory;
import java.security.PrivateKey;
import java.security.Signature;
import java.security.spec.PKCS8EncodedKeySpec;
import java.sql.SQLException;
import java.time.Instant;
import java.util.Base64;

/**
 * Подписанный JWT для получения OAuth2-токена сервисного аккаунта Google (#36720).
 *
 * <p>Простой серверный ключ FCM (<code>Authorization: key=...</code>) Google отключил, а
 * актуальный HTTP v1 требует OAuth2-токена, который выдаётся в обмен на JWT, подписанный
 * приватным ключом сервисного аккаунта. Подпись RS256 — единственное во всей цепочке,
 * чего lsFusion не умеет сам, и Java здесь ровно на неё.
 *
 * <p>Всё остальное осталось снаружи и намеренно: ключевой файл разбирает
 * <code>IMPORT JSON</code>, обмен на токен и отправку сообщения делают обычные
 * <code>EXTERNAL HTTP</code> в PushFcm.lsf — их статусы видно в логе рядом со всеми
 * прочими запросами, чего про внутренности Java-класса не скажешь. Поэтому здесь нет ни
 * разбора JSON, ни HTTP, ни единой новой зависимости: RSA-подпись и Base64 есть в JDK.
 *
 * <p>Действие ничего не бросает наружу. Неразобранный ключ — это не сбой сервера, а
 * неверно загруженный администратором файл, и человеку нужна строка «что не так», а не
 * Java-стек в HTTP 500: ошибка уходит в <code>fcmKeyError</code> и оседает в строке
 * доставки, которую видно в журнале уведомлений.
 */
public class FcmAssertionAction extends InternalAction {

    /** Что именно разрешено делать выданным токеном — отправлять сообщения FCM, и только. */
    private static final String SCOPE = "https://www.googleapis.com/auth/firebase.messaging";

    /** Google отвергает JWT со сроком жизни больше часа. */
    private static final long LIFETIME_SECONDS = 3600;

    private final ClassPropertyInterface clientEmailInterface;
    private final ClassPropertyInterface tokenUriInterface;
    private final ClassPropertyInterface privateKeyInterface;

    public FcmAssertionAction(ScriptingLogicsModule LM, ValueClass... classes) {
        super(LM, classes);
        clientEmailInterface = getOrderInterfaces().get(0);
        tokenUriInterface = getOrderInterfaces().get(1);
        privateKeyInterface = getOrderInterfaces().get(2);
    }

    @Override
    protected void executeInternal(ExecutionContext<ClassPropertyInterface> context)
            throws SQLException, SQLHandledException {
        try {
            findProperty("fcmAssertion[]").change((Object) null, context);
            findProperty("fcmKeyError[]").change((Object) null, context);

            String clientEmail = readParam(clientEmailInterface, context);
            String tokenUri = readParam(tokenUriInterface, context);
            String privateKeyPem = readParam(privateKeyInterface, context);

            if (clientEmail == null || tokenUri == null || privateKeyPem == null) {
                findProperty("fcmKeyError[]").change((Object) ("Файл не похож на ключ сервисного"
                        + " аккаунта: нет client_email, token_uri или private_key"), context);
                return;
            }

            long now = Instant.now().getEpochSecond();
            String header = "{\"alg\":\"RS256\",\"typ\":\"JWT\"}";
            String claims = "{\"iss\":\"" + escape(clientEmail) + "\""
                    + ",\"scope\":\"" + SCOPE + "\""
                    + ",\"aud\":\"" + escape(tokenUri) + "\""
                    + ",\"iat\":" + now
                    + ",\"exp\":" + (now + LIFETIME_SECONDS) + "}";

            String signingInput = base64Url(header.getBytes(StandardCharsets.UTF_8))
                    + "." + base64Url(claims.getBytes(StandardCharsets.UTF_8));

            Signature rsa = Signature.getInstance("SHA256withRSA");
            rsa.initSign(readPrivateKey(privateKeyPem));
            rsa.update(signingInput.getBytes(StandardCharsets.UTF_8));

            findProperty("fcmAssertion[]").change(
                    (Object) (signingInput + "." + base64Url(rsa.sign())), context);
        } catch (ScriptingErrorLog.SemanticErrorException e) {
            // сюда попадаем, только если в .lsf нет объявленных выше свойств — это ошибка
            // сборки, а не эксплуатации, и молчать о ней нельзя
            throw new RuntimeException(e);
        } catch (Exception e) {
            writeError(context, e);
        }
    }

    private String readParam(ClassPropertyInterface param,
                             ExecutionContext<ClassPropertyInterface> context) {
        Object value = context.getKeyValue(param).getValue();
        if (value == null) {
            return null;
        }
        String text = value.toString().trim();
        return text.isEmpty() ? null : text;
    }

    private void writeError(ExecutionContext<ClassPropertyInterface> context, Exception e) {
        try {
            String message = e.getMessage() == null ? e.getClass().getSimpleName() : e.getMessage();
            findProperty("fcmKeyError[]").change(
                    (Object) ("Не удалось подписать запрос к Google: " + message), context);
        } catch (Exception ignored) {
            // писать ошибку об ошибке некуда, а бросать отсюда значит подменить понятный
            // отказ доставки невнятным падением регламента
        }
    }

    /**
     * Приватный ключ из ключевого файла — PEM в кодировке PKCS#8. Переводы строк внутри
     * приходят как настоящие \n, но встречаются файлы, где их заменили на \r\n, поэтому
     * выкидывается любой пробельный символ, а не только перевод строки.
     */
    private PrivateKey readPrivateKey(String pem) throws Exception {
        String body = pem
                .replace("-----BEGIN PRIVATE KEY-----", "")
                .replace("-----END PRIVATE KEY-----", "")
                .replaceAll("\\s", "");
        byte[] der = Base64.getDecoder().decode(body);
        return KeyFactory.getInstance("RSA").generatePrivate(new PKCS8EncodedKeySpec(der));
    }

    /** JWT требует base64url без выравнивающих '=' — обычный base64 Google не примет. */
    private static String base64Url(byte[] data) {
        return Base64.getUrlEncoder().withoutPadding().encodeToString(data);
    }

    /**
     * Оба подставляемых значения — почта и URL, escaping им по существу не нужен. Он тут
     * потому, что подделанный ключевой файл не должен превращаться в сломанный JSON,
     * который Google отвергнет без объяснений.
     */
    private static String escape(String value) {
        return value.replace("\\", "\\\\").replace("\"", "\\\"");
    }

    @Override
    protected boolean allowNulls() {
        // ненастроенный сервер — обычное состояние, и ответить на него надо внятным
        // сообщением, а не молчаливым пропуском действия
        return true;
    }
}
