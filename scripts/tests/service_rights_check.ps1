<#
.SYNOPSIS
    Служебные действия и ручки под ролями без права: интеграции, корректирующие, ручной запуск
    графика, отладочные ручки подбора для AI, размер снимка в ручках телефона.

.DESCRIPTION
    Учётки (логины zzz-t21-<время>-none/batch/int/gone, пароль равен логину):
      none  — роль «Исполнитель», прав нет;
      batch — своя роль с правом «Массовое создание задач»;
      int   — своя роль с правом «Администрировать интеграции»;
      gone  — «Исполнитель», которого блокируют посреди проверки.
    Каркас (объект, шаблон с оценкой и фото-полем, завершённая проверка с несоответствием,
    задачи, правило графика, две заявки, устройство) заводится и удаляется через /eval под admin.
    Действия бэк-офиса зовутся через /eval под самой учёткой: формы через /eval не открыть
    (createFormInstance is not supported), поэтому скрытие пунктов меню и отказ формы на
    открытии здесь не проверяются — только в веб-клиенте.

    Что проверяется:
      I  «Создать задачу» по заявке: без права — разбор не перезапущен; с правом — перезапущен.
         «Сопоставить площадку»: без права — сопоставления нет; администратор — есть;
      C  «Создать корректирующие задачи» на заполнении: без права — задач нет; с правом
         «Массовое создание задач» — созданы;
      G  «Сгенерировать сейчас»: без права «Править шаблоны и справочники» (обе узкие роли) —
         задач нет; администратор — созданы;
      A  ручки подбора для AI: без права — 403 forbidden, с правом и у администратора — 200,
         заблокированная — 401;
      K  apiTasks: ключей objectLatitude, objectLongitude, acceptance нет, objectId и distance есть;
      P  снимок больше 3 МБ в задачу, комментарий, новую задачу, поле бланка, фотоотчёт, чат —
         отказ со словами «Снимок больше 3 МБ», ничего не записано; обычный снимок — 200;
         снимок ровно на пределе — 200.
    Последняя строка вывода — JSON в формате проверок набора (run-server-suite.ps1).
#>
param(
    [string]$Base = 'http://localhost:7681',
    [string]$Admin = 'admin',
    [string]$AdminPass = ''
)

. (Join-Path $PSScriptRoot 'api_common.ps1')

$stamp = (Get-Date).ToString('MMddHHmmss')
$P = "ZZZT21-$stamp"                 # id задач и объектов
$Code = "zzzt21$stamp"               # коды шаблона, ролей, источник заявок
$L = @{ none = "zzz-t21-$stamp-none"; batch = "zzz-t21-$stamp-batch"; int = "zzz-t21-$stamp-int"; gone = "zzz-t21-$stamp-gone" }
$Src = 'zzzt21'

# Действие под самой учёткой: /eval под ней — как кнопка бэк-офиса, которую она нажала
function EvalAs([string]$login, [string]$script) {
    $r = Call 'POST' "$Base/eval/action" @{ Authorization = (Basic $login $login) } $script 'text/plain; charset=utf-8'
    if ($r.Status -ne 200) { throw "eval под ${login}: $($r.Status) $(Short $r.Body)" }
}
function Num($v) { if ($v -eq $null) { 0 } else { [int]$v } }
function Guid { [guid]::NewGuid().ToString() }
function Now { (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss') }

$userOf = { param($login) "(GROUP MAX CustomUser c IF login(c) = '$login')" }
$taskOf = { param($id) "(GROUP MAX StoreTask.Task t IF StoreTask.id(t) = '$id')" }
$userLine = {
    param($login, $last, $role)
    "NEW u = CustomUser { login(u) <- '$login'; firstName(u) <- 'ZZZ'; lastName(u) <- 'T21 $last'; setSHA256Password(u, '$login'); mainRole[User](u) <- $role; }"
}
$taskLine = {
    param($id, $type, $extra)
    "NEW t = StoreTask.Task { StoreTask.id(t) <- '$id'; StoreTask.name(t) <- 'ZZZ T21 $id'; StoreTask.type(t) <- StoreTask.taskType('$type'); StoreTask.author(t) <- $(& $userOf $Admin); StoreTask.assignedTo(t) <- $(& $userOf $L.none); StoreTask.checkObject(t) <- obj();$extra }"
}

$setup = @"
LOCAL NESTED os = StoreTask.OptionSet ();
LOCAL NESTED good = StoreTask.Option ();
LOCAL NESTED bad = StoreTask.Option ();
LOCAL NESTED tpl = StoreTask.Template ();
LOCAL NESTED fs = StoreTask.Field ();
LOCAL NESTED obj = StoreTask.CheckAsset ();
NEW r = UserRole { sid(r) <- '$Code-int'; name(r) <- 'ZZZ T21 интеграции'; StoreTask.adminIntegrations(r) <- TRUE; }
NEW r = UserRole { sid(r) <- '$Code-batch'; name(r) <- 'ZZZ T21 пачка'; StoreTask.createTaskBatch(r) <- TRUE; }
NEW k = StoreTask.CheckCategory { StoreTask.catId(k) <- '$P-cat'; StoreTask.catName(k) <- 'ZZZ T21 категория'; }
APPLY NESTED LOCAL;
$(& $userLine $L.none 'без прав' "userRoleSID('executor')")
$(& $userLine $L.batch 'пачка' "userRoleSID('$Code-batch')")
$(& $userLine $L.int 'интеграции' "userRoleSID('$Code-int')")
$(& $userLine $L.gone 'уволенный' "userRoleSID('executor')")
NEW a = StoreTask.CheckAsset { obj() <- a; StoreTask.assetId(a) <- '$P-A'; StoreTask.assetName(a) <- 'ZZZ T21 магазин'; StoreTask.assetAddress(a) <- 'ZZZ, ул. Тестовая, 21';
    StoreTask.assetLatitude(a) <- 53.9; StoreTask.assetLongitude(a) <- 27.56; StoreTask.checkCategory(a) <- StoreTask.checkCategory('$P-cat'); }
NEW s = StoreTask.OptionSet { os() <- s; StoreTask.name(s) <- 'ZZZ T21 хорошо/плохо';
    NEW o = StoreTask.Option { good() <- o; StoreTask.optionSet(o) <- s; StoreTask.code(o) <- 'good'; StoreTask.name(o) <- 'Хорошо'; StoreTask.score(o) <- 2; }
    NEW o = StoreTask.Option { bad() <- o; StoreTask.optionSet(o) <- s; StoreTask.code(o) <- 'bad'; StoreTask.name(o) <- 'Плохо'; StoreTask.score(o) <- 0; StoreTask.nonconformity(o) <- TRUE; }
}
NEW x = StoreTask.Template { tpl() <- x; StoreTask.code(x) <- '$Code'; StoreTask.name(x) <- 'ZZZ T21 бланк'; StoreTask.family(x) <- x; StoreTask.deadlineDays(x) <- 3;
    NEW sc = StoreTask.Section { StoreTask.template(sc) <- x; StoreTask.name(sc) <- 'ZZZ T21 раздел';
        NEW f = StoreTask.Field { fs() <- f; StoreTask.section(f) <- sc; StoreTask.code(f) <- 's1'; StoreTask.name(f) <- 'ZZZ T21 состояние';
            StoreTask.type(f) <- StoreTask.FieldType.scale; StoreTask.optionSet(f) <- os(); StoreTask.scoreable(f) <- TRUE; }
        NEW f = StoreTask.Field { StoreTask.section(f) <- sc; StoreTask.code(f) <- 'p1'; StoreTask.name(f) <- 'ZZZ T21 фото'; StoreTask.type(f) <- StoreTask.FieldType.photo; }
    }
}
APPLY NESTED LOCAL;
$(& $taskLine "$P-F1" 'checklist' ' StoreTask.template(t) <- tpl(); NEW e = StoreTask.Filling { StoreTask.task(e) <- t; StoreTask.template(e) <- tpl(); StoreTask.optionValue(e, fs()) <- bad(); StoreTask.state(e) <- StoreTask.ExecutionState.finished; }')
$(& $taskLine "$P-FP" 'checklist' ' StoreTask.template(t) <- tpl();')
$(& $taskLine "$P-SP" 'issue' '')
$(& $taskLine "$P-TF" 'issue' '')
NEW p = StoreTask.SchedulePlan { StoreTask.name(p) <- 'ZZZ T21 $stamp'; StoreTask.template(p) <- tpl(); StoreTask.type(p) <- StoreTask.taskType('checklist');
    StoreTask.categoryId(p) <- '$P-cat'; StoreTask.startDate(p) <- currentDate(); StoreTask.periodDays(p) <- 7; StoreTask.leadDays(p) <- 7;
    StoreTask.deadlineDays(p) <- 1; StoreTask.assignedTo(p) <- $(& $userOf $L.none); }
NEW q = StoreTask.TaskRequest { StoreTask.source[StoreTask.TaskRequest](q) <- '$Src'; StoreTask.sourceId(q) <- '$stamp-1'; StoreTask.received(q) <- currentDateTime();
    StoreTask.reason[StoreTask.TaskRequest](q) <- 'zzzStale'; }
NEW q = StoreTask.TaskRequest { StoreTask.source[StoreTask.TaskRequest](q) <- '$Src'; StoreTask.sourceId(q) <- '$stamp-2'; StoreTask.received(q) <- currentDateTime();
    StoreTask.siteCode(q) <- '$P-site'; StoreTask.reason[StoreTask.TaskRequest](q) <- 'siteNotMapped'; }
NEW d = StoreTask.PushDevice { StoreTask.token(d) <- '$Code'; StoreTask.performer[StoreTask.PushDevice](d) <- $(& $userOf $L.none); }
APPLY NESTED LOCAL;
EXPORT JSON FROM canceled = System.canceled(), msg = System.applyMessage(),
    tasks = (GROUP SUM 1 IF StoreTask.id(StoreTask.Task t) LIKE '$P-%');
"@

$cleanup = @"
LOCAL own = BOOLEAN (StoreTask.Task);
own(StoreTask.Task t) <- TRUE WHERE StoreTask.id(t) LIKE '$P-%' OR StoreTask.name(t) LIKE 'ZZZ T21%'
    OR StoreTask.assetId(StoreTask.checkObject(t)) LIKE '$P-%' OR StoreTask.code(StoreTask.template(t)) = '$Code';
DELETE StoreTask.Notification n WHERE own(StoreTask.task(n));
DELETE StoreTask.TaskHistory h WHERE own(StoreTask.task(h));
DELETE StoreTask.TaskStatusChange sc WHERE own(StoreTask.task(sc));
DELETE StoreTask.TaskComment c WHERE own(StoreTask.task(c));
DELETE StoreTask.TaskFile f WHERE own(StoreTask.task(f));
DELETE StoreTask.Execution z WHERE own(StoreTask.task(z));
DELETE StoreTask.ScheduleLog l WHERE StoreTask.name(StoreTask.rule(l)) = 'ZZZ T21 $stamp';
DELETE StoreTask.TaskRequest q WHERE StoreTask.source[StoreTask.TaskRequest](q) = '$Src';
DELETE StoreTask.SiteMapping m WHERE StoreTask.source[StoreTask.SiteMapping](m) = '$Src';
DELETE StoreTask.Task x WHERE own(x);
DELETE StoreTask.SchedulePlan p WHERE StoreTask.name(p) = 'ZZZ T21 $stamp';
DELETE StoreTask.PushDevice d WHERE StoreTask.token(d) = '$Code';
DELETE StoreTask.Field f WHERE StoreTask.code(StoreTask.template(StoreTask.section(f))) = '$Code';
DELETE StoreTask.Section s WHERE StoreTask.code(StoreTask.template(s)) = '$Code';
DELETE StoreTask.Template x WHERE StoreTask.code(x) = '$Code';
DELETE StoreTask.Option o WHERE StoreTask.name(StoreTask.optionSet(o)) = 'ZZZ T21 хорошо/плохо';
DELETE StoreTask.OptionSet s WHERE StoreTask.name(s) = 'ZZZ T21 хорошо/плохо';
DELETE StoreTask.CheckAsset a WHERE StoreTask.assetId(a) LIKE '$P-%';
DELETE StoreTask.CheckCategory k WHERE StoreTask.catId(k) = '$P-cat';
APPLY;
// учётки — отдельным применением: исполнителя с открытыми задачами удалить нельзя, а
// уведомления и переписка держат их строки
DELETE StoreTask.Notification n WHERE StoreTask.id(StoreTask.performer(n)) LIKE 'zzz-t21-$stamp-%';
DELETE Chat.Message m WHERE (GROUP SUM 1 IF Chat.in(Chat.chat(m), CustomUser u) AND login(u) LIKE 'zzz-t21-$stamp-%');
DELETE Chat.Chat ch WHERE (GROUP SUM 1 IF Chat.in(ch, CustomUser u) AND login(u) LIKE 'zzz-t21-$stamp-%');
DELETE CustomUser c WHERE login(c) LIKE 'zzz-t21-$stamp-%';
APPLY;
// роли — после учёток: роль, назначенную пользователю, удалить нельзя
DELETE UserRole r WHERE sid(r) LIKE '$Code-%';
APPLY;
EXPORT JSON FROM canceled = System.canceled(), msg = System.applyMessage(),
    left = (GROUP SUM 1 IF StoreTask.id(StoreTask.Task t) LIKE '$P-%') (+) (GROUP SUM 1 IF login(CustomUser c) LIKE 'zzz-t21-$stamp-%');
"@

$jpeg = '/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkICQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/yQALCAABAAEBAREA/8wABgAQEAX/2gAIAQEAAD8A0s8g/9k='
$edge = 'A' * 4194304          # ровно 3 МБ байтов в base64 — на пределе, проходит
$big = 'A' * 4194308           # на 3 байта больше — отказ
$tooBig = 'Снимок больше 3 МБ'
$chatTouched = $false

try {
    $j = Eval $setup
    if ($j.canceled -or (Num $j.tasks) -ne 4) { throw "каркас не завёлся: $($j.msg) (задач $($j.tasks))" }
    $tok = @{}
    foreach ($k in $L.Keys) { $tok[$k] = Token $L[$k] }
    $adminAuth = @{ Authorization = (Basic $Admin $AdminPass); Accept = 'application/json' }

    Write-Host '-- I. заявки и карантин'
    $reasonOf = { param($n) (Eval "EXPORT JSON FROM r = StoreTask.reason[StoreTask.TaskRequest](StoreTask.taskRequest('$Src', '$stamp-$n'));").r }
    EvalAs $L.none "StoreTask.retryRequest(StoreTask.taskRequest('$Src', '$stamp-1'));"
    $r = & $reasonOf 1
    Check 'I.без права «Создать задачу» по заявке не перезапускает разбор' ($r -eq 'zzzStale') "причина: $r"
    EvalAs $L.int "StoreTask.retryRequest(StoreTask.taskRequest('$Src', '$stamp-1'));"
    $r = & $reasonOf 1
    Check 'I.с правом «Администрировать интеграции» разбор перезапущен' ($r -eq 'noSiteCode') "причина: $r"
    $mapping = { (Eval "EXPORT JSON FROM m = StoreTask.assetId(StoreTask.checkObject(StoreTask.siteMapping('$Src', '$P-site')));").m }
    $site = "(GROUP MAX StoreTask.CheckAsset a IF StoreTask.assetId(a) = '$P-A')"
    EvalAs $L.none "StoreTask.resolveSite(StoreTask.taskRequest('$Src', '$stamp-2'), $site);"
    $m = & $mapping
    Check 'I.без права «Сопоставить площадку» ничего не пишет' (-not $m) "сопоставление: $m"
    $null = Eval "StoreTask.resolveSite(StoreTask.taskRequest('$Src', '$stamp-2'), $site); EXPORT JSON FROM c = System.canceled();"
    $m = & $mapping
    Check 'I.администратор сопоставляет площадку' ($m -eq "$P-A") "сопоставление: $m"

    Write-Host '-- C. корректирующие по заполнению'
    $fill = "(GROUP MAX StoreTask.Filling e IF StoreTask.id(StoreTask.task(e)) = '$P-F1')"
    $corr = { Num (Eval "EXPORT JSON FROM n = (GROUP SUM 1 IF StoreTask.sourceFilling(StoreTask.Task c) = $fill AND StoreTask.isCorrective(c));").n }
    EvalAs $L.none "StoreTask.generateCorrective($fill);"
    $n = & $corr
    Check 'C.без права корректирующие не создаются' ($n -eq 0) "создано: $n"
    EvalAs $L.batch "StoreTask.generateCorrective($fill);"
    $n = & $corr
    Check 'C.с правом «Массовое создание задач» созданы' ($n -ge 1) "создано: $n"

    Write-Host '-- G. «Сгенерировать сейчас»'
    $plan = "(GROUP MAX StoreTask.SchedulePlan p IF StoreTask.name(p) = 'ZZZ T21 $stamp')"
    $byRule = { Num (Eval "EXPORT JSON FROM n = (GROUP SUM 1 IF StoreTask.rule(StoreTask.Task t) = $plan);").n }
    EvalAs $L.none "StoreTask.generateForRule($plan);"
    EvalAs $L.batch "StoreTask.generateForRule($plan);"
    $n = & $byRule
    Check 'G.без права на справочники правило вручную не запускается' ($n -eq 0) "задач по правилу: $n"
    $null = Eval "StoreTask.generateForRule($plan); EXPORT JSON FROM c = System.canceled();"
    $n = & $byRule
    Check 'G.администратор запускает правило' ($n -ge 1) "задач по правилу: $n"

    Write-Host '-- A. ручки подбора для AI'
    $ai = @(@('apiAiSearchObjects', '?query=ZZZ'), @('apiAiSearchTaskTypes', ''), @('apiAiSearchTemplates', '?query=ZZZ'),
            @('apiAiSearchPerformers', '?query=ZZZ'), @('apiAiAvailablePerformers', "?objectId=$P-A"))
    foreach ($h in $ai) {
        $r = Get-Api $h[0] $tok.none $h[1]
        Check "A.$($h[0]) без права — 403 forbidden" ($r.Status -eq 403 -and $r.Body -match '"forbidden"') "$($r.Status) $(Short $r.Body)"
        $r = Get-Api $h[0] $tok.int $h[1]
        Check "A.$($h[0]) с правом — 200" ($r.Status -eq 200) "$($r.Status) $(Short $r.Body)"
        $r = Call 'GET' "$Base/exec/StoreTask.$($h[0])$($h[1])" $adminAuth
        Check "A.$($h[0]) администратор — 200" ($r.Status -eq 200) "$($r.Status) $(Short $r.Body)"
    }
    $r = Get-Api 'apiAiSearchObjects' $tok.int '?query=ZZZ'
    Check 'A.с правом объекты подбора приходят' ($r.Body -match [regex]::Escape("$P-A")) (Short $r.Body)

    Write-Host '-- K. ключи apiTasks'
    $r = Get-Api 'apiTasks' $tok.none '?lat=53.9&lon=27.56'
    $row = $null
    $rows = $r.Body | ConvertFrom-Json
    foreach ($x in $rows) { if ($x.id -eq "$P-TF") { $row = $x } }
    $names = if ($row) { @($row.PSObject.Properties.Name) } else { @() }
    Check 'K.apiTasks без objectLatitude, objectLongitude, acceptance' ($row -ne $null -and -not ($names -contains 'objectLatitude' -or $names -contains 'objectLongitude' -or $names -contains 'acceptance')) "ключи: $($names -join ',')"
    Check 'K.apiTasks: objectId и distance на месте' ($row -ne $null -and $row.objectId -eq "$P-A" -and ($names -contains 'distance')) "objectId=$($row.objectId) ключи: $($names -join ',')"

    Write-Host '-- P. размер снимка'
    $count = {
        param($what)
        $q = switch ($what) {
            'file'    { "(GROUP SUM 1 IF StoreTask.task(StoreTask.TaskFile f) = $(& $taskOf "$P-TF"))" }
            'comment' { "(GROUP SUM 1 IF StoreTask.task(StoreTask.TaskComment c) = $(& $taskOf "$P-TF"))" }
            'created' { "(GROUP SUM 1 IF StoreTask.name(StoreTask.Task t) = 'ZZZ T21 новая')" }
            'field'   { "(GROUP SUM 1 IF StoreTask.photo(StoreTask.Filling e, StoreTask.Field f, INTEGER i) AND StoreTask.id(StoreTask.task(e)) = '$P-FP')" }
            'simple'  { "(GROUP SUM 1 IF StoreTask.photo(StoreTask.SimpleExecution e, INTEGER i) AND StoreTask.id(StoreTask.task(e)) = '$P-SP')" }
            'chat'    { "(GROUP SUM 1 IF Chat.in(Chat.chat(Chat.Message m), $(& $userOf $L.none)))" }
        }
        Num (Eval "EXPORT JSON FROM n = $q;").n
    }
    $r = Post-Api 'apiStartExecution' $tok.none "{`"id`":`"$P-FP`",`"at`":`"$(Now)`"}"
    $r2 = Post-Api 'apiStartSimple' $tok.none "{`"id`":`"$P-SP`",`"at`":`"$(Now)`"}"
    Check 'P.старт бланка и фотоотчёта' ($r.Status -eq 200 -and $r2.Status -eq 200) "$($r.Status) $(Short $r.Body) / $($r2.Status) $(Short $r2.Body)"
    $intId = (Eval "EXPORT JSON FROM id = LONG($(& $userOf $L.int) AS CustomUser);").id
    # выключенный чат ручка отвергает раньше размера снимка — на время шага чат включается
    $chatWas = (Eval "EXPORT JSON FROM v = StoreTask.chatEnabled();").v
    $chatTouched = $true
    $null = Eval "StoreTask.chatEnabled() <- TRUE; APPLY; EXPORT JSON FROM c = System.canceled();"
    $cases = @(
        @('file',    'снимок к задаче',   'apiAddTaskFile',    { param($ph) "{`"id`":`"$P-TF`",`"clientId`":`"$(Guid)`",`"photo`":`"$ph`"}" }),
        @('comment', 'снимок в комментарии', 'apiAddTaskComment', { param($ph) "{`"id`":`"$P-TF`",`"clientId`":`"$(Guid)`",`"text`":`"`",`"photo`":`"$ph`"}" }),
        @('created', 'новая задача со снимком', 'apiCreateTask', { param($ph) "{`"clientId`":`"$(Guid)`",`"typeId`":`"issue`",`"objectId`":`"$P-A`",`"name`":`"ZZZ T21 новая`",`"photo`":`"$ph`"}" }),
        @('field',   'снимок к полю бланка', 'apiSetFieldPhoto', { param($ph) "{`"id`":`"$P-FP`",`"field`":`"p1`",`"clientId`":`"$(Guid)`",`"photo`":`"$ph`"}" }),
        @('simple',  'снимок фотоотчёта', 'apiSetSimplePhoto', { param($ph) "{`"id`":`"$P-SP`",`"clientId`":`"$(Guid)`",`"photo`":`"$ph`"}" }),
        @('chat',    'снимок в чат',      'apiAddChatMessage', { param($ph) "{`"clientId`":`"$(Guid)`",`"userId`":$intId,`"photo`":`"$ph`"}" })
    )
    foreach ($c in $cases) {
        $before = & $count $c[0]
        $r = Post-Api $c[2] $tok.none (& $c[3] $big)
        $after = & $count $c[0]
        Check "P.$($c[1]) больше 3 МБ — отказ «$tooBig»" ($r.Status -ge 400 -and $r.Body -match $tooBig -and $after -eq $before) "$($r.Status) $(Short $r.Body); записей $before → $after"
        $r = Post-Api $c[2] $tok.none (& $c[3] $jpeg)
        $after2 = & $count $c[0]
        Check "P.$($c[1]) обычный — 200" ($r.Status -eq 200 -and $after2 -eq $after + 1) "$($r.Status) $(Short $r.Body); записей $after → $after2"
    }
    $before = & $count 'file'
    $r = Post-Api 'apiAddTaskFile' $tok.none "{`"id`":`"$P-TF`",`"clientId`":`"$(Guid)`",`"photo`":`"$edge`"}"
    $after = & $count 'file'
    Check 'P.снимок ровно 3 МБ — 200' ($r.Status -eq 200 -and $after -eq $before + 1) "$($r.Status) $(Short $r.Body); записей $before → $after"

    Write-Host '-- A. заблокированная учётка'
    $null = Eval "Authentication.isLocked(CustomUser u) <- TRUE WHERE login(u) = '$($L.gone)'; APPLY; EXPORT JSON FROM c = System.canceled();"
    $r = Get-Api 'apiAiSearchObjects' $tok.gone '?query=ZZZ'
    Check 'A.заблокированной ручка подбора — 401' ($r.Status -eq 401) "$($r.Status) $(Short $r.Body)"
}
catch {
    $fails.Add("сценарий прерван: $($_.Exception.Message)")
    Write-Host "  FAIL сценарий прерван — $($_.Exception.Message)"
}
finally {
    if ($chatTouched) { try {
        $v = if ($chatWas) { 'TRUE' } else { 'NULL' }
        $null = Eval "StoreTask.chatEnabled() <- $v; APPLY; EXPORT JSON FROM c = System.canceled();"
    } catch { $fails.Add("возврат флага чата: $($_.Exception.Message)") } }
    try {
        $j = Eval $cleanup
        if ($j.canceled -or (Num $j.left) -ne 0) { $fails.Add("уборка: $($j.msg) (осталось $($j.left))"); Write-Host "  FAIL уборка — $($j.msg)" }
    } catch { $fails.Add("уборка: $($_.Exception.Message)"); Write-Host "  FAIL уборка — $($_.Exception.Message)" }
}

Exit-WithResult
