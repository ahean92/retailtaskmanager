<#
.SYNOPSIS
    Цифры главной телефона против списка задач — под учётками исполнителя и супервайзера.

.DESCRIPTION
    Плитка главной — вопрос («три просрочено — какие?»), и нажатие открывает список под тем же
    фильтром. Цифра на плитке и длина списка обязаны совпадать. Сценарий заводит через /eval
    учётки (исполнители — роль executor, супервайзер — supervisor), расположение ZZZ-SITE с
    оборудованием внутри и задачи с разными сроками, затем сверяет ответы apiHome и apiTasks
    под их токенами. Фильтры списка — те же, что у телефона (models/task_view.dart, matches):
      open — mine; today — mine и dueToday; overdue — mine и overdue; acceptance — awaitingDecision.

      T1 исполнитель: у каждого показателя с переходом значение = число строк его списка;
      T2 «здесь»: единственная задача учётки — на оборудовании внутри места; разрез показателя
         по месту обязан её считать (место и его оборудование), а строка списка — нести ключ
         места placeId, по которому телефон сужает список, открытый с плитки;
      T3 «Сегодня сделано N из M»: сданная на приёмку — сделана, отменённая не считается вовсе;
      T4 супервайзер: роли по умолчанию выдано «Видеть все задачи»; его собственные плитки
         сходятся со списком, сетевые плитки на телефоне не нажимаются (без filter).
      T5 время присылки показателя (apiSetMetric): запись по объекту ставит время объекту и
         не трогает сетевое, сетевая — наоборот; оба доходят до телефона ключом time.
      T6 средний балл сети на большом месяце: 150 проверок по 90 % (сумма процентов за 10 000) —
         apiHome супервайзера отвечает 200, плитка netScore — среднее по проверкам месяца.
      T7 главная без координат: без параметров — все доступные места (клиент прежней версии),
         со scope=self — только места своих задач и выбранный objectId, и разрез — по ним же.

    Только для своей базы 6.2 после suite_seed_62.lsf (run-server-suite.ps1 зовёт сценарий сам):
      powershell -ExecutionPolicy Bypass -File scripts/tests/home_api_check.ps1 -Base http://localhost:7701
    Последняя строка вывода — JSON в формате проверок набора. Код возврата 0/1.
#>
param(
    [Parameter(Mandatory = $true)][string]$Base,
    [string]$Admin = 'admin',
    [string]$AdminPass = ''
)

. (Join-Path $PSScriptRoot 'api_common.ps1')

$run = Get-Date -Format 'HHmmss'
$L = @{ worker = "zzz17.$run.hworker"; other = "zzz17.$run.hother"; eq = "zzz17.$run.heq"; day = "zzz17.$run.hday"; sup = "zzz17.$run.hsup" }

function User([string]$key, [string]$role) {
    "NEW u = CustomUser { login(u) <- '$($L[$key])'; firstName(u) <- 'ZZZ17'; lastName(u) <- '$key'; setSHA256Password(u, '$($L[$key])'); mainRole[User](u) <- userRoleSID('$role'); }`n"
}
function P([string]$key) { "StoreTask.performer((GROUP MAX CustomUser c IF login(c) = '$($L[$key])'))" }
function Task([string]$id, [string]$assignee, [string]$author, [string]$deadline, [string]$obj = "StoreTask.checkAsset('ZZZ-SITE')", [string]$policy = 'notRequired') {
    "NEW t = StoreTask.Task { StoreTask.id(t) <- '$id'; StoreTask.name(t) <- 'ZZZ 17 $id'; StoreTask.type(t) <- StoreTask.issueTaskType(); " +
    "StoreTask.checkObject(t) <- $obj; StoreTask.author(t) <- $(P $author); StoreTask.assignedTo(t) <- $(P $assignee); " +
    "StoreTask.deadline(t) <- $deadline; StoreTask.acceptancePolicy(t) <- StoreTask.AcceptancePolicy.$policy; }`n"
}

$today = 'Time.currentDate()'
$seed = (User 'worker' 'executor') + (User 'other' 'executor') + (User 'eq' 'executor') + (User 'day' 'executor') + (User 'sup' 'supervisor') +
    "APPLY;`n" +
    "NEW a = StoreTask.CheckAsset { StoreTask.assetId(a) <- 'ZZZ17-EQ'; StoreTask.assetName(a) <- 'ZZZ17 весы'; StoreTask.parentObject(a) <- StoreTask.checkAsset('ZZZ-SITE'); }`n" +
    "APPLY;`n" +
    (Task 'ZZZ17-H1' 'worker' 'other' 'Time.sum(Time.currentDate(), -1)') +
    (Task 'ZZZ17-H2' 'worker' 'other' $today) +
    (Task 'ZZZ17-H3' 'worker' 'other' 'Time.sum(Time.currentDate(), 5)') +
    (Task 'ZZZ17-H5' 'other' 'worker' 'Time.sum(Time.currentDate(), 5)' "StoreTask.checkAsset('ZZZ-SITE')" 'required') +
    (Task 'ZZZ17-HE' 'eq' 'other' 'Time.sum(Time.currentDate(), 5)' "StoreTask.checkAsset('ZZZ17-EQ')") +
    (Task 'ZZZ17-DA' 'day' 'other' $today) +
    (Task 'ZZZ17-DB' 'day' 'other' $today "StoreTask.checkAsset('ZZZ-SITE')" 'required') +
    (Task 'ZZZ17-DC' 'day' 'other' $today) +
    (Task 'ZZZ17-DD' 'day' 'other' $today) +
    "APPLY;`n" +
    "StoreTask.submit(StoreTask.task('ZZZ17-H5'), $(P 'other'));`n" +
    "StoreTask.submit(StoreTask.task('ZZZ17-DB'), $(P 'day'));`n" +
    "StoreTask.status(StoreTask.task('ZZZ17-DC')) <- StoreTask.taskStatus('canceled');`n" +
    "StoreTask.status(StoreTask.task('ZZZ17-DD')) <- StoreTask.taskStatus('canceled');`n" +
    "APPLY;`n" +
    "EXPORT JSON FROM canceled = System.canceled(), msg = System.applyMessage(), h5 = StoreTask.id(StoreTask.status(StoreTask.task('ZZZ17-H5'))), db = StoreTask.id(StoreTask.status(StoreTask.task('ZZZ17-DB')));"

$cleanup = @'
LOCAL bad = TEXT ();
FOR StoreTask.id(StoreTask.Task t) LIKE 'ZZZ17-H%' OR StoreTask.id(t) LIKE 'ZZZ17-D%' DO {
    DELETE StoreTask.Notification n WHERE StoreTask.task(n) = t;
    DELETE StoreTask.TaskHistory h WHERE StoreTask.task(h) = t;
    DELETE StoreTask.TaskStatusChange sc WHERE StoreTask.task(sc) = t;
    DELETE t;
    APPLY NESTED LOCAL;
    bad() <- OVERRIDE bad(), (System.applyMessage() IF System.canceled());
}
DELETE StoreTask.HomeBlock b WHERE StoreTask.code(b) = 'zzz17t5';
DELETE StoreTask.Template x WHERE StoreTask.code(x) = 'zzz17hs';
DELETE StoreTask.CheckAsset a WHERE StoreTask.assetId(a) = 'ZZZ17-EQ' OR StoreTask.assetId(a) = 'ZZZ17-P2';
DELETE StoreTask.Notification n WHERE StoreTask.id(StoreTask.performer(n)) LIKE 'zzz17.%';
DELETE CustomUser c WHERE login(c) LIKE 'zzz17.%';
APPLY NESTED LOCAL;
bad() <- OVERRIDE bad(), (System.applyMessage() IF System.canceled());
EXPORT JSON FROM bad = bad(),
    leftTasks = (GROUP SUM 1 IF StoreTask.id(StoreTask.Task t) LIKE 'ZZZ17-H%' OR StoreTask.id(t) LIKE 'ZZZ17-D%'),
    leftUsers = (GROUP SUM 1 IF login(CustomUser c) LIKE 'zzz17.%');
'@

# строки списка под фильтром — как у телефона (task_view.dart, TaskFilter.matches)
function Count-List($rows, [string]$filter) {
    @($rows | Where-Object {
        $r = $_   # внутри switch $_ — уже значение фильтра, а не строка списка
        switch ($filter) {
            'open'       { $r.mine -eq $true }
            'today'      { $r.mine -eq $true -and $r.dueToday -eq 1 }
            'overdue'    { $r.mine -eq $true -and $r.overdue -eq 1 }
            'acceptance' { $r.awaitingDecision -eq $true }
            default      { $false }
        }
    }).Count
}
function Metrics($h) { @($h.blocks | ForEach-Object { $_.metrics } | Where-Object { $_ }) }

$crashed = $null
try {
    $s = Eval $seed
    if ($s.canceled) { throw "посев отменён: $($s.msg)" }
    Check 'посев: задачи сданы на приёмку' ($s.h5 -eq 'acceptance' -and $s.db -eq 'acceptance') "H5 $($s.h5), DB $($s.db)"

    Write-Host 'T1 исполнитель: плитка = список'
    $tw = Token $L.worker
    $hm = (Get-Api 'apiHome' $tw).Body | ConvertFrom-Json
    $rows = (Get-Api 'apiTasks' $tw).Body | ConvertFrom-Json
    $withFilter = @(Metrics $hm | Where-Object { $_.filter })
    $bad = @($withFilter | Where-Object { [double]$_.value -ne (Count-List $rows $_.filter) } |
        ForEach-Object { "$($_.code) ($($_.filter)): плитка $($_.value), список $(Count-List $rows $_.filter)" })
    Check "T1.у исполнителя плитки с переходом сходятся со списком ($($withFilter.Count) плиток)" ($withFilter.Count -ge 3 -and $bad.Count -eq 0) `
        ($(if ($withFilter.Count -lt 3) { "плиток с переходом $($withFilter.Count)" } else { $bad -join '; ' }))
    Check 'T1.список исполнителя: просрочена одна, на сегодня одна, ждёт его решения одна' `
        ((Count-List $rows 'overdue') -eq 1 -and (Count-List $rows 'today') -eq 1 -and (Count-List $rows 'acceptance') -eq 1) `
        "просрочено $(Count-List $rows 'overdue'), сегодня $(Count-List $rows 'today'), решение $(Count-List $rows 'acceptance')"

    Write-Host 'T2 «здесь» — место и его оборудование'
    $te = Token $L.eq
    $homeEq = (Get-Api 'apiHome' $te '?objectId=ZZZ-SITE').Body | ConvertFrom-Json
    $open = @(Metrics $homeEq | Where-Object { $_.filter -eq 'open' -and $_.values })
    if (-not $open) {
        Check 'T2.у исполнителя есть плитка открытых задач с разрезом по месту' $false 'нет такой плитки — разрез не проверить'
    } else {
        $here = [double](($open[0].values | Where-Object { $_.object -eq 'ZZZ-SITE' } | Select-Object -First 1).value)
        Check 'T2.место выбрано из-за задачи на его оборудовании' (@($homeEq.objects | Where-Object { $_.id -eq 'ZZZ-SITE' }).Count -eq 1) 'места нет в objects'
        Check 'T2.«здесь» считает задачу на оборудовании места: 1 здесь, 1 всего' ($here -eq 1 -and [double]$open[0].value -eq 1) "здесь $here, всего $($open[0].value)"
        # без @(...): в Windows PowerShell ConvertFrom-Json отдаёт массив одним объектом, и обёртка
        # дала бы массив из одного массива — фильтры ниже сравнивали бы целые столбцы
        $rowsEq = (Get-Api 'apiTasks' $te).Body | ConvertFrom-Json
        $row = $rowsEq | Where-Object { $_.id -eq 'ZZZ17-HE' } | Select-Object -First 1
        Check 'T2.строка списка: объект — весы, место — магазин' ($row.objectId -eq 'ZZZ17-EQ' -and $row.placeId -eq 'ZZZ-SITE') "objectId $($row.objectId), placeId $($row.placeId)"
        $inPlace = @($rowsEq | Where-Object { $_.placeId -eq 'ZZZ-SITE' })
        Check 'T2.список, суженный по месту, совпадает с плиткой «здесь»' ((Count-List $inPlace 'open') -eq $here) "список $(Count-List $inPlace 'open'), плитка $here"
    }

    Write-Host 'T3 «Сегодня сделано N из M»'
    $td = Token $L.day
    $homeDay = (Get-Api 'apiHome' $td).Body | ConvertFrom-Json
    $n = [int]$homeDay.todayDone; $m = [int]$homeDay.todayTotal
    Check 'T3.сданная — сделана, отменённые не считаются: 1 из 2' ($n -eq 1 -and $m -eq 2) "$n из $m"

    Write-Host 'T4 супервайзер'
    $seeAll = (Eval "EXPORT JSON FROM v = (IF StoreTask.seeAllTasks(userRoleSID('supervisor')) THEN 1 ELSE 0);").v
    Check 'T4.роли «Супервайзер» по умолчанию выдано «Видеть все задачи»' ($seeAll -eq 1) "seeAllTasks $seeAll"
    $ts = Token $L.sup
    $homeSup = (Get-Api 'apiHome' $ts).Body | ConvertFrom-Json
    $rowsSup = (Get-Api 'apiTasks' $ts).Body | ConvertFrom-Json
    $supTiles = @(Metrics $homeSup | Where-Object { $_.filter })
    $own = @($supTiles | Where-Object { $_.code -notlike 'net*' })
    $badOwn = @($own | Where-Object { [double]$_.value -ne (Count-List $rowsSup $_.filter) } | ForEach-Object { "$($_.code): плитка $($_.value), список $(Count-List $rowsSup $_.filter)" })
    Check "T4.собственные плитки супервайзера сходятся со списком ($($own.Count))" ($badOwn.Count -eq 0) ($badOwn -join '; ')
    $net = @($supTiles | Where-Object { $_.code -like 'net*' })
    $netAll = @(Metrics $homeSup | Where-Object { $_.code -like 'net*' })
    Check "T4.сетевые плитки супервайзера на телефоне не нажимаются ($($netAll.Count) плиток, без filter)" ($netAll.Count -ge 1 -and $net.Count -eq 0) `
        ("плиток сети $($netAll.Count), с переходом: " + (($net | ForEach-Object { "$($_.code)=$($_.filter)" }) -join ', '))
    $overdueNet = [double](($netAll | Where-Object { $_.code -eq 'netOverdue' } | Select-Object -First 1).value)
    Check 'T4.сводка супервайзера видит сеть: «Просрочено» не ноль' ($overdueNet -ge 1) "netOverdue $overdueNet"

    Write-Host 'T5 время присылки показателя'
    # право импорта — роли администратора на время шага (eval идёт под admin), прежнее
    # значение возвращается в finally
    $script:hadImport = (Eval "EXPORT JSON FROM v = (IF StoreTask.allowMetricImport(StoreTask.systemAdminRole()) THEN 1 ELSE 0);").v
    $null = Eval @'
StoreTask.allowMetricImport(StoreTask.systemAdminRole()) <- TRUE;
NEW b = StoreTask.HomeBlock {
    StoreTask.code(b) <- 'zzz17t5'; StoreTask.type(b) <- StoreTask.HomeBlockType.metrics; StoreTask.title(b) <- 'ZZZ17 T5';
    StoreTask.byObject(b) <- TRUE; StoreTask.active(b) <- TRUE;
    NEW m = StoreTask.HomeMetric { StoreTask.block(m) <- b; StoreTask.code(m) <- 'zzz17t5m'; StoreTask.name(m) <- 'ZZZ17 T5'; StoreTask.active(m) <- TRUE; }
}
APPLY;
EXPORT JSON FROM c = System.canceled();
'@
    $times = @'
EXPORT JSON FROM net = STRING(StoreTask.dataTime(StoreTask.homeMetric('zzz17t5m'))),
    obj = STRING(StoreTask.dataTime(StoreTask.homeMetric('zzz17t5m'), StoreTask.checkObject('ZZZ-SITE')));
'@
    # r'' — сырой литерал: в обычном фигурные скобки JSON читаются как ключ локализации
    $send = "Utils.stringToFile(r'{0}', 'UTF-8', 'json'); StoreTask.apiSetMetric(Utils.resultFile());`n" + $times
    $t1 = Eval ($send -f '{"code":"zzz17t5m","object":"ZZZ-SITE","value":3}')
    Check 'T5.запись по объекту: время у объекта, сетевое не тронуто' ($t1.obj -and -not $t1.net) "сеть $($t1.net), объект $($t1.obj)"
    $t2 = Eval ($send -f '{"code":"zzz17t5m","value":7}')
    Check 'T5.сетевая запись: время у сети, объектное прежнее' ($t2.net -and $t2.obj -eq $t1.obj) "сеть $($t2.net), объект $($t2.obj) (было $($t1.obj))"
    $homeT5 = (Get-Api 'apiHome' $tw).Body | ConvertFrom-Json
    $m5 = Metrics $homeT5 | Where-Object { $_.code -eq 'zzz17t5m' } | Select-Object -First 1
    $v5 = @($m5.values | Where-Object { $_.object -eq 'ZZZ-SITE' }) | Select-Object -First 1
    Check 'T5.apiHome отдаёт время показателя и его разреза' ($m5.time -and $v5.time) "показатель $($m5.time), ZZZ-SITE $($v5.time)"

    Write-Host 'T6 средний балл сети на большом месяце'
    # 150 завершённых проверок по 90 % — 9 баллов из 10; итог записывает само завершение
    $s6 = Eval @'
NEW tp = StoreTask.Template { StoreTask.code(tp) <- 'zzz17hs'; StoreTask.name(tp) <- 'ZZZ 17 средний балл'; }
NEW s = StoreTask.Section { StoreTask.template[StoreTask.Section](s) <- StoreTask.template('zzz17hs'); StoreTask.name(s) <- 'ZZZ 17 раздел'; }
NEW f = StoreTask.Field { StoreTask.section(f) <- (GROUP MAX StoreTask.Section x IF StoreTask.template[StoreTask.Section](x) = StoreTask.template('zzz17hs')); StoreTask.code(f) <- 'b'; StoreTask.name(f) <- 'ZZZ 17 балл из 10'; StoreTask.type(f) <- StoreTask.FieldType.score; StoreTask.weight(f) <- 10; StoreTask.scoreable(f) <- TRUE; }
NEW t = StoreTask.Task { StoreTask.id(t) <- 'ZZZ17-HS'; StoreTask.name(t) <- 'ZZZ 17 средний балл'; StoreTask.type(t) <- StoreTask.taskType('checklist'); StoreTask.checkObject(t) <- StoreTask.checkAsset('ZZZ-SITE'); StoreTask.template[StoreTask.Task](t) <- StoreTask.template('zzz17hs'); }
APPLY;
LOCAL fb = StoreTask.Field ();
fb() <- GROUP MAX StoreTask.Field x IF StoreTask.code(x) = 'b' AND StoreTask.template[StoreTask.Field](x) = StoreTask.template('zzz17hs');
FOR iterate(INTEGER i, 1, 150) NEW e = StoreTask.Filling DO {
    StoreTask.task(e) <- StoreTask.task('ZZZ17-HS');
    StoreTask.template[StoreTask.Filling](e) <- StoreTask.template('zzz17hs');
    StoreTask.numberValue(e, fb()) <- 9;
    StoreTask.state(e) <- StoreTask.ExecutionState.finished;
}
APPLY;
EXPORT JSON FROM c = System.canceled(), msg = System.applyMessage(),
    n = (GROUP SUM 1 IF StoreTask.task(StoreTask.Filling e) = StoreTask.task('ZZZ17-HS') AND StoreTask.percent(e) = 90);
'@
    Check 'T6.посев: 150 завершённых проверок по 90 %' (-not $s6.c -and $s6.n -eq 150) "отменено $($s6.c) $($s6.msg), по 90 %: $($s6.n)"
    # ожидание считается здесь, по самим проверкам месяца: на общей базе набора их может быть
    # больше, чем посеяно
    $pp = @((Eval 'EXPORT JSON FROM p = StoreTask.percent(StoreTask.Filling e), s = StoreTask.hasScored(e) WHERE StoreTask.finishedThisMonth(e);') | Where-Object { $_ })
    $sum = 0.0; $cnt = 0
    foreach ($x in $pp) { if ($x.p) { $sum += [double]$x.p }; if ($x.s) { $cnt++ } }
    $want = if ($cnt) { [math]::Round($sum / $cnt, 2) } else { $null }
    $r6 = Get-Api 'apiHome' $ts
    $score = $null
    if ($r6.Status -eq 200) {
        $score = (Metrics ($r6.Body | ConvertFrom-Json) | Where-Object { $_.code -eq 'netScore' } | Select-Object -First 1).value
    }
    Check "T6.apiHome супервайзера — 200, средний балл сети верный (сумма $sum, проверок $cnt)" `
        ($r6.Status -eq 200 -and $sum -ge 10000 -and $null -ne $score -and [math]::Abs([double]$score - $want) -lt 0.01) `
        "$($r6.Status), netScore $score, ожидалось $want $(if ($r6.Status -ne 200) { Short $r6.Body })"

    Write-Host 'T7 главная без координат: scope=self'
    # второе место сети, где у исполнителя задач нет
    $null = Eval "NEW a = StoreTask.CheckAsset { StoreTask.assetId(a) <- 'ZZZ17-P2'; StoreTask.assetName(a) <- 'ZZZ17 второе место'; } APPLY; EXPORT JSON FROM c = System.canceled();"
    function Ids($h) { @($h.objects | ForEach-Object { $_.id }) }
    # набор строкой — сортировка порядковая: культурная пропускает дефис, и одинаковые наборы
    # из разных источников расходились порядком
    function SetKey($list) { $a = [string[]]@($list); [Array]::Sort($a, [StringComparer]::Ordinal); $a -join ',' }
    $whole = (Get-Api 'apiHome' $tw).Body | ConvertFrom-Json
    $selfOnly = (Get-Api 'apiHome' $tw '?scope=self').Body | ConvertFrom-Json
    $selfPick = (Get-Api 'apiHome' $tw '?scope=self&objectId=ZZZ17-P2').Body | ConvertFrom-Json
    Check 'T7.без параметров — все места, как раньше' ((Ids $whole) -contains 'ZZZ17-P2' -and (Ids $whole) -contains 'ZZZ-SITE') "objects: $((Ids $whole) -join ', ')"
    Check 'T7.scope=self — только место своих задач' (((Ids $selfOnly) -join ',') -eq 'ZZZ-SITE') "objects: $((Ids $selfOnly) -join ', ')"
    # разрез каждого показателя — набор мест, отсортированный строкой
    $sliced = @(Metrics $selfPick | Where-Object { $_.values } |
        ForEach-Object { SetKey @($_.values | ForEach-Object { $_.object }) } | Select-Object -Unique)
    $picked = SetKey (Ids $selfPick)
    Check 'T7.scope=self с objectId — плюс выбранное место, разрез по тем же местам' `
        ($picked -eq (SetKey @('ZZZ-SITE', 'ZZZ17-P2')) -and $sliced.Count -ge 1 -and @($sliced | Where-Object { $_ -ne $picked }).Count -eq 0) `
        "objects: $((Ids $selfPick) -join ', '); разрезы: $($sliced -join ' | ')"
} catch {
    $crashed = $_.Exception.Message
    Write-Host "сценарий прерван: $crashed"
} finally {
    try {
        if ($null -ne $script:hadImport -and $script:hadImport -ne 1) {
            $null = Eval 'StoreTask.allowMetricImport(StoreTask.systemAdminRole()) <- NULL; APPLY; EXPORT JSON FROM c = System.canceled();'
        }
        $c = Eval $cleanup
        if ($c.bad -or $c.leftTasks -or $c.leftUsers) { $fails.Add("уборка: $($c.bad) задач осталось $($c.leftTasks), учёток $($c.leftUsers)") }
    } catch { $fails.Add("уборка: $($_.Exception.Message)") }
}
if ($crashed) { $fails.Add("сценарий прерван: $crashed") }
Exit-WithResult
