# storetask-logics

The task subsystem as a standalone lsFusion artifact: a fillable engine (template →
fields/columns → filling/rows), the task framework around it, a mobile field interface
and an HTTP JSON API for the mobile client.

It is consumed as a plain jar dependency and knows nothing about any particular host.
Two hosts exist today: a mycompany-based ERP, and the artifact itself running alone.

## Layout

```
StoreTaskStandalone.lsf  the artifact running alone — the only module outside storeTasks/
storeTasks/
├── StoreTaskLib.lsf     the host-independent half, whole — a bundle of four packages:
├── StoreTaskCoreLib.lsf    the task subsystem proper: model, engine, reports, core API
├── StoreTaskMobileLib.lsf  the phone's home screen, presets, branding, their handles
├── StoreTaskNotifyLib.lsf  notifications: events, device registry, push via FCM, e-mail
├── StoreTaskAiLib.lsf      task creation from text through the ai-service
├── StoreTask.lsf        aggregator for a mycompany-based host: StoreTaskLib + erp/
├── StoreTaskSettings.lsf
├── task/                the task itself, its statuses, types, priorities, tags, access
├── fillable/            the filling engine and the task kinds built on it
│                        (checklist, recount, pricing), printing
├── corrective/          photo-confirmation execution: corrective actions, issues
├── report/ schedule/    reports over fillings; task creation on a schedule
├── home/                the home screen and its blocks, the supervisor dashboard
├── mobile/ api/         the rest of the field interface and the JSON API
├── notification/        events, delivery channels (push via FCM, e-mail)
├── ai/                  task creation from text, through the ai-service
├── meta/                private copies of infrastructure metacode (see below)
├── erp/                 bridges that require a mycompany-based host
└── demo/                demo generators — a separate package, see below
```

Two modules are host options rather than part of `StoreTaskLib`, like `ExternalApp`:
`task/ObjectDimensionValue` (dimension values as a user-maintained catalogue) and
`fillable/SubjectStock` (stock per object for the `item` channel). A host with its own
source of that data implements the abstractions itself; a host without one adds the
`REQUIRE` line, as `StoreTaskStandalone` does.

The task itself is three modules in `task/`. `StoreTaskCore` is the model; `StoreTaskTakeover`
is taking a task over — who took it, who may take or release it, what counts as *mine*;
`StoreTaskForms` is the desktop card and list together with everything the `meta/` metacode
hangs on the card: history, files, comments, the status-change log. The attachment classes
`TaskFile` and `TaskComment` are born in `StoreTaskForms`, because the metacode that declares
them puts them on the form in the same breath — so a module that needs those classes, or
extends the card, requires `StoreTaskForms` explicitly rather than the core.

## Plugging it into a mycompany-based host

Two lines, and nothing in the host's own sources changes:

```xml
<dependency>
    <groupId>lsfusion.solutions</groupId>
    <artifactId>storetask-logics</artifactId>
    <version>7.0-SNAPSHOT</version>
</dependency>
```

```lsfusion
REQUIRE StoreTask;   // in the host's top module
```

`StoreTask` pulls in the `erp/` bridges, which map the subsystem's abstractions onto
what the ERP already has: `Assignee`/`Employee` become task performers, an inventory
`Location` becomes something inspectable, and the activity feed is wired onto the task
card.

The demo generators are a separate package, `demo/StoreTaskDemoLib`, that no production
aggregator pulls in — two of its actions delete every task in the database. A host that
is a demo stand adds it next to `StoreTask`; the standalone host takes the one generator
that needs no ERP, `ScorecardDemo`, on its own.

## Running it standalone

`StoreTaskStandalone` is the minimal host: it makes a logged-in `CustomUser` a task
performer, and that is all it does. Point the server at it and it works on an empty
database — no employees to set up, the admin account is a performer out of the box.

Create `conf/settings.properties` (git-ignored, it describes your machine, not the
project):

```properties
db.server=localhost
db.name=<your database>
db.user=postgres
db.password=<your password>

rmi.port=7662

logics.topModule = StoreTaskStandalone
```

**`logics.topModule` is required, not optional.** The artifact also ships the `erp/`
bridges, which REQUIRE `Activity`, `Assignee` and `Location` — none of which exist in a
standalone run. A top module makes the server drop everything unreachable from it
*before* dependencies are resolved (`ModuleList.filterWithTopModule`), so those bridges
are never loaded. Without the line the server dies with
`required module 'Activity' was not found`.

Run `lsfusion.server.logics.BusinessLogicsBootstrap` with this directory as the working
directory, then load default data once from *Application → Default data* — that creates
the task types, statuses, priorities, the task numerator, and switches push on for the
five events it exists for (#37345).

The scheduler jobs the subsystem lives by — schedule generation, deadline notifications,
delivery, hypotheses — register themselves on start (`meta/StoreTaskRegulation`, from
`onFinallyStarted`: `onStarted` runs before Reflection is synchronized, and on a fresh
database the action objects do not exist yet). Each package registers its own job next to
the action, so a core-only host gets one job, not four. A job is recognized by name: an
existing one is left alone, a stopped one stays stopped, a deleted one comes back on the
next start. A host with jobs of its own sets «Не заводить регламенты подсистемы при
старте» on the options form before the first start.

A server started from the IDE with the lsFusion plugin runs in development mode, and that
mode runs every request that comes without credentials as `admin`: `enableAPI` is forced
to `2` whatever the settings say. A stand where the phone client is tested must not run
like that — a request that leaves the phone without its token then works under somebody
else's account instead of failing, and the bug goes unnoticed. Add
`-Dlsfusion.server.devmode=false` to the VM options. The default `enableAPI=0` is all the
client needs: every `api*` action is `@@api`, and `apiBrand` is `@@noauth`.

## Writing another host

A host has to answer one question the subsystem deliberately refuses to answer: who can
author, be assigned and execute a task. Implement `TaskPerformer` — `id`, `name`,
`archived`, `in`, and `performer(User)` — for whatever your people are. Optionally
implement `CheckObject` so tasks have something to target; `CheckAsset` is a ready-made
generic one.

A host may also take less than `StoreTaskLib`. `StoreTaskCoreLib` alone is the task
subsystem with its desktop forms and the core of the JSON API; the other three packages
each require the core and never each other, so a host without push and e-mail leaves out
`StoreTaskNotifyLib`, one without the AI service leaves out `StoreTaskAiLib`, and one that
serves no phone at all leaves out `StoreTaskMobileLib` too. The core never requires any of
them — a host built on the core alone starts without FCM, SMTP or the ai-service.

## Reacting to a closed task

Closing a task runs an extension point, so a host attaches its effects without touching
the artifact — one line in the host's own module:

```lsfusion
onProceed (Task t) + { ... }
```

The point fires once per task, whichever way it was closed: the automatic close when all
executions succeed, a status changed by hand on the card, in the list or on the board, the
mobile `apiSetStatus`, the recheck of a corrective action, or the `Провести` button for a
task that became closed through the status catalogue. Cancelling is the same point — a
reaction that cares reads `canceledTask(t)`. A repeat is not possible: `proceeded(Task)`
is raised inside the point and checked on entry, so a task reopened and closed again does
not run the effects twice. Tasks closed before the point existed are marked `proceeded`
on the first start and never proceed.

**What a reaction may and may not do.** Reactions run inside the closing transaction
(the point is a global event) and are rolled back with it; the platform also retries that
transaction silently after a conflict or a timeout, so a reaction may run more than once.
They may therefore only touch data: statuses, flags, new tasks, write-back into a master
object. They must not send mail or push, call somebody else's HTTP or write files — a
rejected apply would leave the outside world believing in a task the database does not
have, and a retried one would send twice. Reaching the outside world is done by recording
the intention: `notify(TaskPerformer, NotificationEvent, Task)` writes a journal row,
delivery rows follow on a global event, and the scheduler sends them, each in its own
session (`notification/`). The artifact's own reactions are the examples:
`notification/StoreTaskNotification` (the assignee, the author and the watchers learn
that the task is closed or cancelled) and `corrective/Corrective` (follow-up tasks for
the non-conformities of a finished filling, unless the task was cancelled).

An object created inside a reaction is created inside a global event. Session (`LOCAL`)
events have already run by then, and the global events the platform ordered before the
point — the task numerator among them, because the point reads `id` — will not run for it
either. Set what they would have set; see how `createCorrective` writes the status, the
author and the number itself.

Reactions must also be independent of each other: the list runs in module initialization
order, which `REQUIRE` dependencies decide, and there is no priority.

## Captions and locale

The subsystem carries its own resource bundle — `src/main/resources/StoreTaskResourceBundle.properties`
and its `_en` and `_ru` siblings — and the `.lsf` code refers to it by keys. The artifact
does not rely on the host having them.

There are two kinds of keys. The keys without a prefix — `{Name}`, `{ID}`, `{Active}` and
the like — keep the names of the mycompany bundle, so a mycompany host keeps resolving them
from its own bundle. `{Code}` is the exception: the mycompany bundle has no such key, and it
resolves from ours on every host. Every other caption uses the `storeTask.` prefix —
`{storeTask.comments}`, `{storeTask.date}` — because host bundles are searched before ours
when a key is resolved (see below), and a plain `{Date}` of the host would silently override
our value.

The files split by kind of key as well as by language. The base file holds the unprefixed
keys with their English values, `_en` the English values of the `storeTask.*` keys, `_ru`
the Russian values of both. The `storeTask.*` keys stay out of the base file on purpose —
see the reverse translation below. A key that resolves nowhere is visible at a glance: the
form shows `storeTask.date`, not `Date`. The same happens under a locale the bundle has no
file for, say `pl`: the unprefixed keys fall back to the English base file, the
`storeTask.*` keys show as keys.

A key works the same way in a static caption (`name '{Name}' = ...`) and inside a computed
one — `badged('{storeTask.files}', countFiles(o))`, a `HEADER` expression: a string literal
is localized when the query is built, in the locale of the session.

Two things decide what a user actually sees.

**The locale is per user, with a server-wide fallback that comes from the JVM.** The platform
resolves it as `clientLanguage` (if the user opted into the client locale), then
`userLanguage`, then `defaultUserLanguage()`, then `serverLanguage()`. The last link is
written from the server JVM's default locale on every start (`DBManager.synchronizeDB`): a
server running on a Russian Windows says `ru`, one running in an English container says
`en`, and two stands of the same artifact can differ for that reason alone. Once the locale
is chosen, the value of a key has no fallback to the JVM locale: if the bundle has no file
for that locale, the base (English) file is used and the captions read `Name`, `Code`,
`Active`. So a host that looks untranslated is worth
checking here first, before suspecting the bundle.

**Whoever names the key first wins.** The platform collects every `*ResourceBundle.properties`
from `java.class.path` by file name only — from jars and from plain directories such as
`target/classes` alike — and takes the first bundle that has the key, in alphabetical order.
Only a bundle with a base file (no locale suffix) takes part. On this artifact alone the
order is `ApiResourceBundle` < `ServerResourceBundle` < `StoreTaskResourceBundle`; a
mycompany host adds `MyCompanyResourceBundle` before ours. Ours sorts last, so its values
show only where no other bundle defines the key — on a mycompany host the host's own
captions win for every unprefixed key its bundle defines.

**Reverse translation turns the order around.** A host started with
`logics.lsfStrLiteralsLanguage` set — the mycompany configurations use `default` — replaces a
plain literal of its own code, `'Comments'` rather than `'{Comments}'`, by the key whose value
it matches. The dictionary for that comes from the same bundles in the same order, but there
the last bundle with the value wins, and ours sorts last. With `default` only base files go
into it; with `en`, base files and `_en` ones; with `ru`, the `_ru` files. This is why the
English values of `storeTask.*` live in `_en`: in the base file they would capture the
host's own `'Comments'`, `'Created at'`, `'Add'` and put our words on the host's forms.
What is left: under `en` our `_en` takes part after all, and under `ru` our `_ru` does — a
host literal `'Дата'` becomes `{storeTask.date}`, the same word under `ru` and `Date` under
`en`. The unprefixed keys of the base file take part too; where the host bundle defines the
same key they change nothing, where it does not, a host literal such as `'d'` or `'In'`
resolves through ours.

Two consequences worth knowing: a bundle reached some other way than through
`java.class.path` is not scanned, and the localizer is built once at startup, so editing a
bundle on a running server changes nothing until it is restarted.

`scripts/check-bundle-keys.sh` takes the keys from the string literals of the `.lsf` code
and compares them with the base file and `_en` taken together, and those with `_ru`, in both
directions. It also reports a `storeTask.*` key in the base file and an unprefixed key in
`_en`. It prints every discrepancy and exits with 1 when there is one, and with 2 when there
is nothing to compare — no bundle file, or no keys found at all.

## Why meta/ exists

The task card needs change history, files, comments and a status-change log. In
mycompany those come from `ObjectUtils`, `FileUtils`, `Comments` and `Doc`, and all four
turned out to need nothing but platform features — so `meta/` carries private copies
instead of a dependency. Module *and* metacode names are new, because module names must
be unique across the whole classpath and an ERP host loads both.

This costs nothing in stored data: metacode expands in the *calling* module's namespace,
so the copies produce exactly the same canonical property names as the originals.

**They are forks, not copies.** Each one has since been trimmed to what the task card
needs and grown its own behaviour, so a fix in mycompany's original does not carry over
by itself — compare before porting anything. Divergence from `mycompany/utils/*` as of
2026-09-02 (file sizes raw; "differing" counts lines that still differ after stripping
the `StoreTask` prefix and collapsing whitespace):

| original → fork | lines orig./fork | differing |
|---|---|---|
| ObjectUtils → StoreTaskObjectUtils | 168 / 138 | 84 |
| FileUtils → StoreTaskFileUtils | 176 / 171 | 53 (adds `canDownload` + a 403 branch) |
| Comments → StoreTaskCommentUtils | 228 / 182 | 99 (carries the two DateUtils helpers itself) |
| Doc → StoreTaskDocUtils | 619 / 169 | 396 (about a quarter of the original was taken) |
| Color → StoreTaskColor | 52 / 60 | 56 (class renamed, `getWord` instead of `basicName`) |

The same goes for the web assets: `web/storeTasks/kanban.js` is a byte-for-byte copy of
`mycompany/web/utils/kanban.js` (with `dragula` vendored next to it) and
`taskComments.{js,css}` a renamed fork of `web/utils/comments.{js,css}`. They are kept as
forks on purpose — a shared web artifact is not worth it while this is the only second
consumer — so a fix on either side has to be ported by hand.

`Activity` is the one piece that did not come along — its class hangs off `Employee` and
`Partner` and it carries its own catalogue and CUSTOM component — so the feed stays an
optional bridge in `erp/`.
