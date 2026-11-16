<#
.SYNOPSIS
    Код сервера, который ходит во внешние сервисы, — против локальной заглушки.

.DESCRIPTION
    ai-service (генерация кода гипотезы, черновик задачи по тексту) и выдача OAuth-токена
    Google для пушей заменены заглушкой stub_ai_service.py на 127.0.0.1:<StubPort>: ответы
    фиксированы, сеть и модель не нужны, итог детерминирован. Сценарий сам поднимает заглушку
    и гасит её по PID.

      G  генерация кода гипотезы (generate): код и пересказ записаны в версию; ключ, который
         сервис отверг, — «unauthorized»; сервис не отвечает — «unavailable»;
      W  постановка задачи текстом из веб-формы (AiTaskWeb: webStep → черновик → webCreateOne):
         черновик «ok», задача создана по разговору, на объекте из ответа сервиса;
      F  токен для пушей (refreshFcmToken): без ключа — понятная ошибка; ключ (свежий RSA,
         генерируется openssl на время прогона) — токен получен и сохранён со сроком; Google
         отказал (400 invalid_grant) — ошибка с ответом Google; Google недоступен — «Нет связи».

    Генерация и токен идут в сессии eval без APPLY и в базе не остаются. Веб-форма открывает
    свою сессию и читает настройки из базы: адрес и ключ AI-сервиса на время шага W
    применяются и затем возвращаются прежними; журнал AI-запросов и созданная задача
    удаляются.

    Только для своей базы 6.2 (run-server-suite.ps1 зовёт сценарий сам). Нужны python и openssl
    (Git for Windows). Отдельно:
      powershell -ExecutionPolicy Bypass -File scripts/tests/external_check.ps1 -Base http://localhost:7701
    Последняя строка вывода — JSON в формате проверок набора. Код возврата 0/1.
#>
param(
    [Parameter(Mandatory = $true)][string]$Base,
    [string]$Admin = 'admin',
    [string]$AdminPass = '',
    [int]$StubPort = 7711
)

. (Join-Path $PSScriptRoot 'api_common.ps1')

$stubUrl = "http://127.0.0.1:$StubPort"
$deadUrl = 'http://127.0.0.1:7799'   # заведомо закрытый порт: «сервис не отвечает»
$run = Get-Date -Format 'HHmmss'
$tmp = Join-Path ([IO.Path]::GetTempPath()) "external17_$run"
New-Item -ItemType Directory -Force $tmp | Out-Null
$stub = $null
$saved = $null
$crashed = $null

function Lsf([string]$s) { $s.Replace('\', '\\').Replace("'", "\'").Replace("`r", '').Replace("`n", '\n') }

try {
    # ---------- заглушка ----------
    $python = (Get-Command python -ErrorAction SilentlyContinue).Source
    if (-not $python) { throw 'нет python — заглушку внешних сервисов не поднять' }
    $stub = Start-Process -FilePath $python -ArgumentList @('-I', "`"$(Join-Path $PSScriptRoot 'stub_ai_service.py')`"", $StubPort) `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput "$tmp\stub.out" -RedirectStandardError "$tmp\stub.err"
    $up = $false
    foreach ($i in 1..30) {
        Start-Sleep -Milliseconds 500
        if ((Call 'GET' "$stubUrl/health" @{}).Status -eq 200) { $up = $true; break }
    }
    if (-not $up) { throw "заглушка не поднялась на $stubUrl" }

    # ---------- G. генерация кода гипотезы ----------
    Write-Host 'G генерация кода гипотезы'
    # потолок ожидания генератора — секунды, а не 15 минут по умолчанию: на закрытый порт
    # сервер не получает мгновенного отказа и ждёт потолок целиком
    function Generate([string]$url, [string]$key) {
        Eval ("StoreTask.aiUrl() <- '$url'; StoreTask.aiApiKey() <- '$key'; StoreTask.codegenTimeout() <- 5000;`n" +
              "NEW x = StoreTask.Hypothesis { StoreTask.code(x) <- 'zzz17g'; StoreTask.name(x) <- 'ZZZ17G генерация'; StoreTask.text(x) <- 'ZZZ17G весы без поверки'; }`n" +
              "NEW v = StoreTask.HypothesisVersion { StoreTask.hypothesis(v) <- StoreTask.hypothesisByCode('zzz17g'); StoreTask.number(v) <- 1; }`n" +
              "FOR StoreTask.HypothesisVersion v = (GROUP MAX StoreTask.HypothesisVersion w IF StoreTask.code(StoreTask.hypothesis(w)) = 'zzz17g') DO {`n" +
              "    StoreTask.newJob(v); StoreTask.generate(v, StoreTask.job()); }`n" +
              "EXPORT JSON FROM script = StoreTask.script((GROUP MAX StoreTask.HypothesisVersion w IF StoreTask.code(StoreTask.hypothesis(w)) = 'zzz17g')),`n" +
              "    summary = StoreTask.summary((GROUP MAX StoreTask.HypothesisVersion w IF StoreTask.code(StoreTask.hypothesis(w)) = 'zzz17g')),`n" +
              "    code = StoreTask.errorCode(StoreTask.job()), err = StoreTask.error(StoreTask.job());")
    }
    $g = Generate $stubUrl 'zzz17-key'
    Check 'G.код и пересказ записаны в версию' ($g.script -match 'ZZZ17 из генератора' -and $g.summary -eq 'ZZZ17 пересказ кода' -and -not $g.code) "код $($g.code): $($g.err)"
    $g = Generate $stubUrl 'zzz-bad'
    Check 'G.сервис отверг ключ — unauthorized' ($g.code -eq 'unauthorized' -and -not $g.script) "код $($g.code): $($g.err)"
    $g = Generate $deadUrl 'zzz17-key'
    Check 'G.сервис не отвечает (потолок ожидания) — unavailable' ($g.code -eq 'unavailable' -and -not $g.script) "код $($g.code): $($g.err)"

    # ---------- W. веб-форма постановки задачи текстом ----------
    Write-Host 'W веб-форма AiTaskWeb'
    $saved = Eval "EXPORT JSON FROM url = StoreTask.aiUrl(), key = StoreTask.aiApiKey(), en = (IF StoreTask.aiEnabled() THEN 1 ELSE 0);"
    $null = Eval "StoreTask.aiUrl() <- '$stubUrl'; StoreTask.aiApiKey() <- 'zzz17-key'; StoreTask.aiEnabled() <- TRUE; APPLY; EXPORT JSON FROM c = System.canceled();"
    $dialog = "zzz17web-$run"
    $w = Eval ("LOCAL NESTED d = STRING[36] ();`nd() <- '$dialog';`n" +
               "StoreTask.webStep(d(), 'ZZZ17 проверь витрину в магазине набора', NULL);`n" +
               "StoreTask.webDialog() <- d();`nStoreTask.webFill();`nStoreTask.webCreateOne(d());`n" +
               "EXPORT JSON FROM outcome = StoreTask.outcome(StoreTask.lastDraft(d())), draft = StoreTask.name(StoreTask.lastDraft(d())),`n" +
               "    task = StoreTask.id(StoreTask.taskByClientId(d())), taskName = StoreTask.name(StoreTask.taskByClientId(d())),`n" +
               "    obj = StoreTask.id(StoreTask.checkObject(StoreTask.taskByClientId(d())));")
    Check 'W.черновик по тексту — ok' ($w.outcome -eq 'ok' -and $w.draft -eq 'ZZZ17 проверить витрину') "исход $($w.outcome), черновик «$($w.draft)»"
    Check 'W.задача создана по разговору на объекте из ответа' ($w.task -and $w.taskName -eq 'ZZZ17 проверить витрину' -and $w.obj -eq 'ZZZ-SITE') "задача $($w.task) «$($w.taskName)» на $($w.obj)"

    # ---------- F. токен для пушей ----------
    Write-Host 'F токен FCM'
    $has = Eval "EXPORT JSON FROM k = (IF StoreTask.fcmServiceAccount() THEN 1 ELSE 0);"
    if ($has.k -eq 1) {
        Check 'F.на базе уже загружен ключ FCM — шаги F не трогают чужой ключ' $false 'пропущено'
    } else {
        $openssl = (Get-Command openssl -ErrorAction SilentlyContinue).Source
        if (-not $openssl) { $openssl = 'C:\Program Files\Git\usr\bin\openssl.exe' }
        # openssl пишет прогресс в stderr; при Stop PowerShell 5.1 счёл бы это ошибкой
        $ErrorActionPreference = 'Continue'
        & $openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$tmp\key.pem" 2>$null
        $ErrorActionPreference = 'Stop'
        if (-not (Test-Path "$tmp\key.pem")) { throw 'openssl не выдал ключ' }
        $pem = Lsf ([IO.File]::ReadAllText("$tmp\key.pem"))
        function Refresh([string]$key, [string]$uri) {
            $setKey = if ($key) {
                "EXPORT JSON FROM type = 'service_account', project_id = 'zzz17-project', client_email = 'zzz17@zzz17-project.iam.gserviceaccount.com', " +
                "private_key = '$key', token_uri = '$uri' TO StoreTask.fcmServiceAccount;`n"
            } else { "StoreTask.fcmServiceAccount() <- NULL;`n" }
            Eval ($setKey + "StoreTask.fcmAccessToken() <- NULL; StoreTask.fcmTokenExpires() <- NULL;`nStoreTask.refreshFcmToken();`n" +
                  "EXPORT JSON FROM token = StoreTask.fcmAccessToken(), err = StoreTask.fcmLastError(), project = StoreTask.fcmProjectId(),`n" +
                  "    minutes = (IF StoreTask.fcmTokenExpires() THEN INTEGER(subtractSeconds(currentDateTime(), StoreTask.fcmTokenExpires()) / 60) ELSE NULL);")
        }
        $f = Refresh $null $null
        Check 'F.без ключа — «не загружен ключ»' (-not $f.token -and $f.err -match 'Не загружен ключ') "$($f.err)"
        $f = Refresh $pem "$stubUrl/token"
        Check 'F.ключ и ответ Google — токен на час без минуты' ($f.token -eq 'zzz17-token' -and $f.project -eq 'zzz17-project' -and $f.minutes -ge 58 -and $f.minutes -le 59 -and -not $f.err) "токен $($f.token), минут $($f.minutes), ошибка $($f.err)"
        $f = Refresh $pem "$stubUrl/token-bad"
        Check 'F.Google отказал — ошибка с его ответом' (-not $f.token -and $f.err -match 'HTTP 400' -and $f.err -match 'invalid_grant') "$($f.err)"
        $f = Refresh $pem "$deadUrl/token"
        Check 'F.Google недоступен — «нет связи»' (-not $f.token -and $f.err -match 'Нет связи') "$($f.err)"
        $f = Refresh 'zzz17-not-a-key' "$stubUrl/token"
        Check 'F.испорченный ключ — ошибка ключа, токена нет' (-not $f.token -and $f.err) "$($f.err)"
    }
} catch {
    $crashed = $_.Exception.Message
    Write-Host "сценарий прерван: $crashed"
} finally {
    try {
        $restore = ''
        if ($saved) {
            $u = if ($saved.url) { "'$($saved.url)'" } else { 'NULL' }
            $k = if ($saved.key) { "'$($saved.key)'" } else { 'NULL' }
            $e = if ($saved.en -eq 1) { 'TRUE' } else { 'NULL' }
            $restore = "StoreTask.aiUrl() <- $u; StoreTask.aiApiKey() <- $k; StoreTask.aiEnabled() <- $e;`n"
        }
        $c = Eval ($restore +
            "FOR StoreTask.Task t = StoreTask.taskByClientId('zzz17web-$run') DO {`n" +
            "    DELETE StoreTask.Notification x WHERE StoreTask.task(x) = t; DELETE StoreTask.TaskHistory x WHERE StoreTask.task(x) = t;`n" +
            "    DELETE StoreTask.TaskStatusChange x WHERE StoreTask.task(x) = t; DELETE t; }`n" +
            "DELETE StoreTask.AiRequest r WHERE StoreTask.dialogId(r) = 'zzz17web-$run';`n" +
            "APPLY;`n" +
            "EXPORT JSON FROM c = System.canceled(), m = System.applyMessage(),`n" +
            "    left = (OVERRIDE (GROUP SUM 1 IF StoreTask.dialogId(StoreTask.AiRequest r) = 'zzz17web-$run'), 0) + (OVERRIDE (GROUP SUM 1 IF StoreTask.code(StoreTask.Hypothesis h) = 'zzz17g'), 0);")
        if ($c.c -or $c.left) { $fails.Add("уборка: $($c.m) осталось $($c.left)") }
    } catch { $fails.Add("уборка: $($_.Exception.Message)") }
    if ($stub -and -not $stub.HasExited) { Stop-Process -Id $stub.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
if ($crashed) { $fails.Add("сценарий прерван: $crashed") }
Exit-WithResult
