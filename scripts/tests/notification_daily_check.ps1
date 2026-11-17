<#
.SYNOPSIS
    Суточный прогон уведомлений по частям, срок хранения журнала, пуш по умолчанию.

.DESCRIPTION
    Прогон зовётся настоящим заданием планировщика «ESB:Задачи — уведомления по срокам»
    (Scheduler.executeScheduledTask): текст отказа платформа пишет в журнал этого задания.
    Отказ одной части создаётся нарочно: событие deadlineNear на время прогона переименовано,
    и запись «срок завтра» без события не проходит NONULL. В уборке имя возвращается.

    Синтетика (учётка zzz-t24-<время>, задачи ZZZT24-<время>-D/-O на ZZZ-SITE) заводится и
    удаляется через /eval под admin.

    Что проверяется:
      D  отказ части «напоминания о сроке» не отменяет «просрочки»: запись «просрочена» есть,
         «срок завтра» нет; в журнале задания — текст отказа с пометкой ошибки; после
         возврата события повторный прогон дописывает «срок завтра» без ошибок в журнале, а
         «просрочена» не задваивается;
      R  очистка журнала уведомлений по сроку хранения: по умолчанию 30 дней — запись 40-дневной
         давности удалена вместе с доставками, 10-дневная на месте; срок 5 дней — удалена и она;
      P  пуш по умолчанию на новой базе: включён для сдачи на приёмку, возврата на доработку и
         трёх событий эскалации, выключен для принятия, закрытия, завершения проверки и
         оспаривания; на базе, где пуш уже настроен, повторное включение по умолчанию
         выключенного руками не возвращает.

    Только для своей базы 6.2 после suite_seed_62.lsf (нужны роль executor, объект ZZZ-SITE,
    данные по умолчанию): run-server-suite.ps1 зовёт сценарий сам. Отдельно:
      powershell -ExecutionPolicy Bypass -File scripts/tests/notification_daily_check.ps1 -Base http://localhost:7701

    Последняя строка вывода — JSON в формате проверок набора: ok, checks, failures.
#>
param(
    [string]$Base = 'http://localhost:7681',
    [string]$Admin = 'admin',
    [string]$AdminPass = ''
)

. (Join-Path $PSScriptRoot 'api_common.ps1')

$stamp = (Get-Date).ToString('MMddHHmmss')
$P = "ZZZT24-$stamp"
$login = "zzz-t24-$stamp"
$user = "(GROUP MAX CustomUser c IF login(c) = '$login')"
$job = "Scheduler.scheduledTask('ESB:Задачи — уведомления по срокам')"
$renamed = "zzz-t24-deadlineNear"

function Num($v) { if ($v -eq $null) { 0 } else { [int]$v } }
function TaskOf([string]$suffix) { "(GROUP MAX StoreTask.Task t IF StoreTask.id(t) = '$P-$suffix')" }
# записи журнала по задаче и событию; событие — по имени (id переименованного события другой)
function Count([string]$suffix, [string]$eventName) {
    Num (Eval "EXPORT JSON FROM n = (GROUP SUM 1 IF StoreTask.task(StoreTask.Notification x) = $(TaskOf $suffix) AND StoreTask.name(StoreTask.event(x)) = '$eventName');").n
}
function MustApply([string]$what, $r) { if ($r.c) { throw "${what}: $($r.m)" } }

# Задание — асинхронно: ждать строку «завершено» после своего запуска, затем сообщения
# (платформа сбрасывает их в журнал отдельно, пачками).
function RunJob {
    $q = "EXPORT JSON FROM l = (GROUP MAX LONG(Scheduler.ScheduledTaskLog l AS Scheduler.ScheduledTaskLog) IF Scheduler.scheduledTask(l) = $job), " +
         "n = (GROUP SUM 1 IF Scheduler.scheduledTask(Scheduler.ScheduledTaskLog l) = $job);"
    $before = Eval $q
    if (-not (Eval "EXPORT JSON FROM j = (TRUE IF $job);").j) { throw 'нет задания «ESB:Задачи — уведомления по срокам»' }
    $prev = Num $before.l; $prevN = Num $before.n
    $null = Eval "Scheduler.executeScheduledTask($job); EXPORT JSON FROM c = System.canceled();"
    $done = $false
    foreach ($i in 1..90) {
        Start-Sleep -Seconds 1
        $s = Eval $q
        if ((Num $s.n) -ge $prevN + 2) { $done = $true; break }
    }
    if (-not $done) { throw 'задание не завершилось за 90 с' }
    # сообщений может не быть вовсе (прогон без отказов) — ждать их ограниченно
    $mine = "Scheduler.scheduledTask(Scheduler.scheduledTaskLog(c)) = $job AND LONG(Scheduler.scheduledTaskLog(c) AS Scheduler.ScheduledTaskLog) > $prev"
    $m = $null
    foreach ($i in 1..10) {
        $m = Eval ("EXPORT JSON FROM msg = (GROUP CONCAT Scheduler.message(Scheduler.ScheduledClientTaskLog c), ' | ' ORDER c WHERE $mine), " +
                   "failed = (GROUP SUM 1 IF Scheduler.failed(Scheduler.ScheduledClientTaskLog c) AND $mine);")
        if ($m.msg) { break }
        Start-Sleep -Seconds 1
    }
    return $m
}

$seed = @"
NEW u = CustomUser { login(u) <- '$login'; firstName(u) <- 'ZZZ'; lastName(u) <- 'T24'; mainRole[User](u) <- userRoleSID('executor'); }
APPLY;
NEW t = StoreTask.Task { StoreTask.id(t) <- '$P-D'; StoreTask.name(t) <- 'ZZZ T24 срок завтра'; StoreTask.type(t) <- StoreTask.taskType('issue'); StoreTask.checkObject(t) <- StoreTask.checkAsset('ZZZ-SITE'); StoreTask.assignedTo(t) <- $user; StoreTask.deadline(t) <- sum(currentDate(), 1); }
NEW t = StoreTask.Task { StoreTask.id(t) <- '$P-O'; StoreTask.name(t) <- 'ZZZ T24 просрочена'; StoreTask.type(t) <- StoreTask.taskType('issue'); StoreTask.checkObject(t) <- StoreTask.checkAsset('ZZZ-SITE'); StoreTask.assignedTo(t) <- $user; StoreTask.deadline(t) <- sum(currentDate(), -3); }
APPLY;
EXPORT JSON FROM c = System.canceled(), m = System.applyMessage();
"@

$cleanup = @"
StoreTask.id(StoreTask.NotificationEvent e) <- 'deadlineNear' WHERE StoreTask.id(e) = '$renamed';
StoreTask.notificationKeepDays() <- NULL;
DELETE StoreTask.Notification n WHERE StoreTask.id(StoreTask.task(n)) LIKE '$P-%' OR StoreTask.performer(n) = $user;
DELETE StoreTask.Task t WHERE StoreTask.id(t) LIKE '$P-%';
LOCAL bad = TEXT ();
APPLY NESTED LOCAL;
bad() <- System.applyMessage() IF System.canceled();
// исполнителя — отдельно, после задач: на назначенного на открытые задачи удаление запрещено
DELETE CustomUser c WHERE login(c) = '$login';
APPLY NESTED LOCAL;
bad() <- OVERRIDE bad(), (System.applyMessage() IF System.canceled());
EXPORT JSON FROM c = (TRUE IF bad()), m = bad(),
    ev = StoreTask.id(StoreTask.notificationEvent('deadlineNear')),
    leftTasks = (GROUP SUM 1 IF StoreTask.id(StoreTask.Task t) LIKE '$P-%'),
    leftUsers = (GROUP SUM 1 IF login(CustomUser c) = '$login');
"@

$crashed = $null
try {
    MustApply 'посев' (Eval $seed)

    Write-Host 'D отказ одной части прогона'
    MustApply 'переименование события' (Eval "StoreTask.id(StoreTask.notificationEvent('deadlineNear')) <- '$renamed'; APPLY; EXPORT JSON FROM c = System.canceled(), m = System.applyMessage();")
    $log = RunJob
    $o = Count 'O' 'Задача просрочена'; $d = Count 'D' 'Срок наступает завтра'
    Check 'D.«просрочена» записана, хотя «срок завтра» отказал' ($o -eq 1 -and $d -eq 0) "просрочена $o, срок завтра $d"
    Check 'D.в журнале задания — причина отказа с пометкой ошибки' ((Num $log.failed) -ge 1 -and $log.msg -like '*StoreTask.event*') "ошибок $($log.failed), сообщения: $(Short $log.msg)"
    MustApply 'возврат события' (Eval "StoreTask.id(StoreTask.NotificationEvent e) <- 'deadlineNear' WHERE StoreTask.id(e) = '$renamed'; APPLY; EXPORT JSON FROM c = System.canceled(), m = System.applyMessage();")
    $log2 = RunJob
    $o = Count 'O' 'Задача просрочена'; $d = Count 'D' 'Срок наступает завтра'
    Check 'D.повторный прогон дописал «срок завтра», «просрочена» не задвоилась' ($o -eq 1 -and $d -eq 1) "просрочена $o, срок завтра $d"
    Check 'D.без отказов журнал задания ошибок не пишет' (-not $log2.failed) "ошибок $($log2.failed), сообщения: $(Short $log2.msg)"

    Write-Host 'R срок хранения журнала'
    $old = @"
NEW n = StoreTask.Notification { StoreTask.performer(n) <- $user; StoreTask.event(n) <- StoreTask.notificationEvent('overdue'); StoreTask.task(n) <- $(TaskOf 'O'); StoreTask.dateTime(n) <- subtractDay(currentDateTime(), 40); StoreTask.title(n) <- '$P old40'; StoreTask.revision(n) <- 1; }
NEW n = StoreTask.Notification { StoreTask.performer(n) <- $user; StoreTask.event(n) <- StoreTask.notificationEvent('overdue'); StoreTask.task(n) <- $(TaskOf 'O'); StoreTask.dateTime(n) <- subtractDay(currentDateTime(), 10); StoreTask.title(n) <- '$P old10'; StoreTask.revision(n) <- 1; }
APPLY;
EXPORT JSON FROM c = System.canceled(), m = System.applyMessage();
"@
    MustApply 'старые записи' (Eval $old)
    $q = "EXPORT JSON FROM n40 = (GROUP SUM 1 IF StoreTask.title(StoreTask.Notification n) = '$P old40'), n10 = (GROUP SUM 1 IF StoreTask.title(StoreTask.Notification n) = '$P old10'), " +
         "d40 = (GROUP SUM 1 IF StoreTask.title(StoreTask.notification(StoreTask.Delivery d)) = '$P old40'), today = (GROUP SUM 1 IF StoreTask.task(StoreTask.Notification n) = $(TaskOf 'O') AND StoreTask.date(n) = currentDate());"
    $s0 = Eval $q
    Check 'R.у старой записи есть доставка — каскад есть что проверять' ((Num $s0.d40) -ge 1) "доставок $($s0.d40)"
    $null = Eval "StoreTask.cleanNotification(); EXPORT JSON FROM c = System.canceled();"
    $s1 = Eval $q
    Check 'R.30 дней: 40-дневная удалена, 10-дневная и сегодняшняя на месте' ((Num $s1.n40) -eq 0 -and (Num $s1.n10) -eq 1 -and (Num $s1.today) -ge 1) "40 дн. $($s1.n40), 10 дн. $($s1.n10), сегодня $($s1.today)"
    MustApply 'срок 5 дней' (Eval "StoreTask.notificationKeepDays() <- 5; APPLY; EXPORT JSON FROM c = System.canceled(), m = System.applyMessage();")
    $null = Eval "StoreTask.cleanNotification(); EXPORT JSON FROM c = System.canceled();"
    $s2 = Eval $q
    Check 'R.срок 5 дней: удалена и 10-дневная' ((Num $s2.n10) -eq 0 -and (Num $s2.today) -ge 1) "10 дн. $($s2.n10), сегодня $($s2.today)"
    MustApply 'срок по умолчанию' (Eval "StoreTask.notificationKeepDays() <- NULL; APPLY; EXPORT JSON FROM c = System.canceled(), m = System.applyMessage();")

    Write-Host 'P пуш по умолчанию'
    $push = { param($id) "$id = (TRUE IF StoreTask.on(StoreTask.notificationEvent('$id'), StoreTask.notificationChannel('push')))" }
    $on = @('acceptancePending', 'taskReturned', 'escalated', 'acceptanceEscalated', 'recheckEscalated')
    $off = @('taskAccepted', 'taskClosed', 'fillingFinished', 'resultDisputed')
    $m = Eval ("EXPORT JSON FROM " + ((@($on) + @($off) | ForEach-Object { & $push $_ }) -join ', ') + ";")
    $bad = @($on | Where-Object { -not $m.$_ }) + @($off | Where-Object { $m.$_ })
    Check 'P.пуш включён для сдачи, возврата и эскалации и выключен для принятия, закрытия, проверки, оспаривания' ($bad.Count -eq 0) ("не так: " + ($bad -join ', '))
    $r = Eval ("StoreTask.on(StoreTask.notificationEvent('acceptancePending'), StoreTask.notificationChannel('push')) <- NULL; APPLY;`n" +
               "StoreTask.enableDefaultPushEvents(); APPLY;`n" +
               "EXPORT JSON FROM c = System.canceled(), m = System.applyMessage(), " + (& $push 'acceptancePending') + ";")
    Check 'P.на настроенной базе выключенный руками пуш не возвращается' (-not $r.c -and -not $r.acceptancePending) "отмена $($r.c), пуш у сдачи $($r.acceptancePending)"
    MustApply 'возврат пуша' (Eval "StoreTask.on(StoreTask.notificationEvent('acceptancePending'), StoreTask.notificationChannel('push')) <- TRUE; APPLY; EXPORT JSON FROM c = System.canceled(), m = System.applyMessage();")
} catch {
    $crashed = $_.Exception.Message
    Write-Host "сценарий прерван: $crashed"
} finally {
    try {
        $c = Eval $cleanup
        if ($c.c -or $c.ev -ne 'deadlineNear' -or $c.leftTasks -or $c.leftUsers) {
            $fails.Add("уборка: $($c.m) событие $($c.ev), задач $($c.leftTasks), учёток $($c.leftUsers)")
        }
    } catch { $fails.Add("уборка: $($_.Exception.Message)") }
}
if ($crashed) { $fails.Add("сценарий прерван: $crashed") }

Exit-WithResult
