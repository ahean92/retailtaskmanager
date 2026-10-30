# Проверка #37349 на живом стенде через ручки телефона: бланк пишет его исполнитель,
# завершённый бланк не пишет никто, смена заполняющего — передачей, а не молча.
#   .\scripts\tests\check37349.ps1                     # демо-стенд: sosedi.tech1 + sosedi.tech2
#                                                       # (пара из одного подразделения: второму
#                                                       # должен проходить requireTouch общей задачи)
#   .\scripts\tests\check37349.ps1 -Base http://host:port -First u1 -FirstPass pw -Second u2 -SecondPass pw
# Пара учёток обязана иметь общий исполнительский узел (inAll обоих): задача назначается
# на него, и ручки обоих проходят requireTouch — иначе проверять нечего, второму отказал
# бы ещё canTouch, не дойдя до исполнителя. Каркас (шаблон с одним текстовым полем,
# задача-чек-лист) заводится и удаляется через /eval/action под admin; сама передача
# заполнения в проверке — прямой записью executor (то же, что делает кнопка «Передать
# заполнение» в АРМ; диалог выбора в eval не прогнать, история пишется кнопкой).
# Возвращает 0, если все ожидания сошлись, 1 — иначе.
# Ожидание после сборки с #37349 (пункты «Готово когда» тикета):
#   1 старт первым                                        → 200; executor выполнения — первый
#   2 apiExecutionInfo                                    → executorId = личный id первого
#   3 ответ второго в бланк первого                       → 409 filledBy, имя и время в теле
#   4 ответ первого                                       → 200
#   5 завершение вторым                                   → 409 filledBy
#   6 передача заполнения (executor ← второй)             → ответ второго 200, первого — 409
#   7 завершение новым исполнителем                       → 200
#   8 ответ после завершения                              → отказ «Execution already finished»
#   9 повторное завершение тем же исполнителем            → 200 (идемпотентный ретрай очереди)
param(
    [string]$Base = 'http://192.168.42.28:8888',
    [string]$First = 'sosedi.tech1',
    [string]$FirstPass = 'demo',
    [string]$Second = 'sosedi.tech2',
    [string]$SecondPass = 'demo',
    [string]$Admin = 'admin',
    [string]$AdminPass = ''
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::Expect100Continue = $false
$Prefix = 'ZZZ37349'
$TaskId = "$Prefix-1"
$FieldCode = 'zzz37349note'

function Basic([string]$u, [string]$p) {
    'Basic ' + [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("$u`:$p"))
}

# Запрос без исключений на 4xx/5xx: возвращает статус и тело (UTF-8) в любом случае.
function Call([string]$Method, [string]$Url, [hashtable]$Headers, [byte[]]$Body = $null, [string]$ContentType = $null) {
    try {
        $args = @{ Uri = $Url; Method = $Method; Headers = $Headers; UseBasicParsing = $true; TimeoutSec = 60 }
        if ($Body -ne $null) { $args.Body = $Body }
        if ($ContentType) { $args.ContentType = $ContentType }
        $r = Invoke-WebRequest @args
        $text = [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
        return @{ Status = [int]$r.StatusCode; Body = $text }
    } catch {
        $resp = $_.Exception.Response
        if ($resp -eq $null) { return @{ Status = 0; Body = $_.Exception.Message } }
        $text = $_.ErrorDetails.Message
        if (-not $text) {
            $st = $resp.GetResponseStream()
            if ($st.CanSeek) { $st.Position = 0 }
            $sr = New-Object System.IO.StreamReader($st, [System.Text.Encoding]::UTF8)
            $text = $sr.ReadToEnd()
        }
        return @{ Status = [int]$resp.StatusCode; Body = $text }
    }
}

function Token([string]$u, [string]$p) {
    $r = Call 'GET' "$Base/exec/Authentication.getAuthToken" @{ Authorization = (Basic $u $p); Accept = 'text/plain' }
    if ($r.Status -ne 200) { throw "Стенд не выдал токен $u`: $($r.Status) $($r.Body)" }
    return $r.Body.Trim()
}

function Post-Api([string]$Action, [string]$Token, [string]$Json) {
    Call 'POST' "$Base/exec/StoreTask.$Action" @{ Authorization = "Bearer $Token" } ([System.Text.Encoding]::UTF8.GetBytes($Json)) 'application/json; charset=utf-8'
}

function Get-Api([string]$Action, [string]$Token, [string]$Query) {
    Call 'GET' "$Base/exec/StoreTask.$Action`?$Query" @{ Authorization = "Bearer $Token"; Accept = 'application/json' } $null $null
}

function Eval([string]$Code) {
    $r = Call 'POST' "$Base/eval/action" @{ Authorization = (Basic $Admin $AdminPass) } ([System.Text.Encoding]::UTF8.GetBytes($Code)) 'text/plain; charset=utf-8'
    if ($r.Status -ne 200) { throw "eval не прошёл: $($r.Status) $($r.Body)" }
    return $r.Body
}

# момент действия «по часам устройства» — в том виде, в каком его шлёт телефон (FillController.wireAt)
function Now() { (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss') }

$rows = @()
function Check([string]$Step, [string]$Expected, [bool]$Ok, [string]$Got) {
    $script:rows += [pscustomobject]@{ Шаг = $Step; Ожидание = $Expected; Получено = $Got; Итог = $(if ($Ok) { 'OK' } else { 'FAIL' }) }
}
$short = { param($s) if ($s -eq $null) { '' } elseif ($s.Length -gt 100) { $s.Substring(0, 100) + '…' } else { $s } }

# --- каркас: общий узел пары, шаблон с одним текстовым полем, задача на этот узел
$setup = @"
LOCAL uA = CustomUser ();
LOCAL uB = CustomUser ();
LOCAL pA = StoreTask.TaskPerformer ();
LOCAL pB = StoreTask.TaskPerformer ();
LOCAL shared = StoreTask.TaskPerformer ();
LOCAL tpl = StoreTask.Template ();
LOCAL sec = StoreTask.Section ();
LOCAL fld = StoreTask.Field ();
uA() <- GROUP MAX CustomUser c IF login(c) = '$First';
uB() <- GROUP MAX CustomUser c IF login(c) = '$Second';
pA() <- StoreTask.performer(uA());
pB() <- StoreTask.performer(uB());
shared() <- GROUP MAX StoreTask.TaskPerformer p IF StoreTask.inAll(p, uA()) AND StoreTask.inAll(p, uB())
    AND NOT (p = pA()) AND NOT (p = pB());
NEW tp = StoreTask.Template {
    tpl() <- tp;
    StoreTask.code(tp) <- 'zzz37349';
    StoreTask.name(tp) <- 'ZZZ 37349 шаблон';
}
NEW s = StoreTask.Section {
    sec() <- s;
    StoreTask.template[StoreTask.Section](s) <- tpl();
    StoreTask.name(s) <- 'ZZZ 37349 раздел';
}
NEW f = StoreTask.Field {
    fld() <- f;
    StoreTask.section(f) <- sec();
    StoreTask.code(f) <- '$FieldCode';
    StoreTask.name(f) <- 'Заметка (ZZZ 37349)';
    StoreTask.type(f) <- StoreTask.FieldType.text;
}
NEW t = StoreTask.Task {
    StoreTask.id(t) <- '$TaskId';
    StoreTask.name(t) <- 'ZZZ 37349 бланк: исполнитель и завершение';
    StoreTask.type(t) <- StoreTask.taskType('checklist');
    StoreTask.author(t) <- pA();
    StoreTask.assignedTo(t) <- shared();
    StoreTask.template[StoreTask.Task](t) <- tpl();
}
APPLY NESTED LOCAL;
EXPORT JSON FROM canceled = System.canceled(), msg = System.applyMessage(),
    shared = StoreTask.name(shared()),
    pAId = StoreTask.id(pA()), pAName = StoreTask.name(pA()),
    pBId = StoreTask.id(pB()), pBName = StoreTask.name(pB());
"@

$transfer = @"
LOCAL pB = StoreTask.TaskPerformer ();
LOCAL fl = StoreTask.Filling ();
pB() <- StoreTask.performer(GROUP MAX CustomUser c IF login(c) = '$Second');
fl() <- StoreTask.fillingTask(StoreTask.task('$TaskId'));
StoreTask.executor(fl()) <- pB();
APPLY NESTED LOCAL;
EXPORT JSON FROM canceled = System.canceled(), msg = System.applyMessage();
"@

$cleanup = @"
DELETE StoreTask.Task t WHERE StoreTask.id(t) = '$TaskId';
DELETE StoreTask.Field f WHERE StoreTask.code(f) = '$FieldCode';
DELETE StoreTask.Section s WHERE StoreTask.name(s) LIKE 'ZZZ 37349%';
DELETE StoreTask.Template tp WHERE StoreTask.code(tp) = 'zzz37349';
APPLY NESTED LOCAL;
EXPORT JSON FROM canceled = System.canceled(), msg = System.applyMessage();
"@

try {
    # стенд мог помнить прошлый прогон — прибираем до и после
    Eval $cleanup | Out-Null

    $setupJson = (Eval $setup | ConvertFrom-Json)
    if (-not $setupJson.shared) {
        throw "У '$First' и '$Second' нет общего исполнительского узла — второму не пройти requireTouch. Передайте другую пару (-First/-Second)."
    }
    $pAId = $setupJson.pAId
    $pAName = $setupJson.pAName
    $pBName = $setupJson.pBName

    $tA = Token $First $FirstPass
    $tB = Token $Second $SecondPass

    # 1) старт первым: выполнение создаётся, его исполнитель — первый
    $r = Post-Api 'apiStartExecution' $tA "{`"id`":`"$TaskId`",`"at`":`"$(Now)`"}"
    Check '1 старт первым' '200' ($r.Status -eq 200) ("$($r.Status) $($short.Invoke($r.Body))")

    # 2) шапка: executorId первого — по нему телефон решает «не я»
    $r = Get-Api 'apiExecutionInfo' $tB "id=$TaskId"
    $info = $null
    try { $info = @($r.Body | ConvertFrom-Json)[0] } catch {}
    $ok = $r.Status -eq 200 -and $info -ne $null -and $info.executorId -eq $pAId
    Check '2 шапка: executorId' "executorId=$pAId" $ok ("$($r.Status) executorId=$($info.executorId)")

    # 3) ответ второго — 409 с именем и временем начала
    $r = Post-Api 'apiSetField' $tB "{`"id`":`"$TaskId`",`"field`":`"$FieldCode`",`"text`":`"ответ второго`"}"
    $refusal = $null
    try { $refusal = $r.Body | ConvertFrom-Json } catch {}
    $ok = $r.Status -eq 409 -and $refusal -ne $null -and $refusal.error -eq 'filledBy' `
        -and $refusal.filledBy -eq $pAName -and $refusal.filledAt -and $refusal.message -like '*Заполняет*'
    Check '3 ответ второго' '409 filledBy: имя+время+message' $ok ("$($r.Status) $($short.Invoke($r.Body))")

    # 4) ответ первого — как было, 200
    $r = Post-Api 'apiSetField' $tA "{`"id`":`"$TaskId`",`"field`":`"$FieldCode`",`"text`":`"ответ первого`"}"
    Check '4 ответ первого' '200' ($r.Status -eq 200) ("$($r.Status) $($short.Invoke($r.Body))")

    # 5) завершение вторым — тоже запись, тот же отказ
    $r = Post-Api 'apiFinishExecution' $tB "{`"id`":`"$TaskId`",`"at`":`"$(Now)`"}"
    $ok = $r.Status -eq 409 -and $r.Body -like '*filledBy*'
    Check '5 завершение вторым' '409 filledBy' $ok ("$($r.Status) $($short.Invoke($r.Body))")

    # 6) передача заполнения второму: теперь пишет он, первый — 409 уже с его именем
    $trJson = (Eval $transfer | ConvertFrom-Json)
    Check '6 передача: eval' 'применилось' (-not $trJson.canceled) ("canceled=$($trJson.canceled) $($short.Invoke($trJson.msg))")
    $r = Post-Api 'apiSetField' $tB "{`"id`":`"$TaskId`",`"field`":`"$FieldCode`",`"text`":`"ответ второго после передачи`"}"
    Check '6 ответ нового исполнителя' '200' ($r.Status -eq 200) ("$($r.Status) $($short.Invoke($r.Body))")
    $r = Post-Api 'apiSetField' $tA "{`"id`":`"$TaskId`",`"field`":`"$FieldCode`",`"text`":`"ответ прежнего`"}"
    $ok = $r.Status -eq 409 -and $r.Body -like "*$pBName*"
    Check '6 ответ прежнего' "409 с именем $pBName" $ok ("$($r.Status) $($short.Invoke($r.Body))")

    # 7) завершение новым исполнителем — 200 (обязательных полей и исхода у шаблона нет)
    $r = Post-Api 'apiFinishExecution' $tB "{`"id`":`"$TaskId`",`"at`":`"$(Now)`"}"
    Check '7 завершение новым' '200' ($r.Status -eq 200) ("$($r.Status) $($short.Invoke($r.Body))")

    # 8) запись в завершённый бланк — отказ тем же текстом, что у SimpleApi
    $r = Post-Api 'apiSetField' $tB "{`"id`":`"$TaskId`",`"field`":`"$FieldCode`",`"text`":`"после завершения`"}"
    $ok = $r.Status -ge 400 -and $r.Body -like '*Execution already finished*'
    Check '8 запись после завершения' 'отказ Execution already finished' $ok ("$($r.Status) $($short.Invoke($r.Body))")

    # 9) повторное завершение тем же исполнителем — ретрай очереди, 200-noop
    $r = Post-Api 'apiFinishExecution' $tB "{`"id`":`"$TaskId`",`"at`":`"$(Now)`"}"
    Check '9 повторное завершение' '200' ($r.Status -eq 200) ("$($r.Status) $($short.Invoke($r.Body))")
} finally {
    # уборка безусловно: стенд не должен помнить прогон даже после неудачи
    Eval $cleanup | Out-Null
}

$rows | Format-Table -AutoSize | Out-String -Width 220
$failed = @($rows | Where-Object { $_.Итог -eq 'FAIL' })
if ($failed.Count -gt 0) {
    Write-Output "FAILED: $($failed.Count)"
    exit 1
}
Write-Output 'OK'
exit 0
