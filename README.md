# esb.tasks

The task subsystem as a standalone lsFusion artifact: a fillable engine (template →
fields/columns → filling/rows), the task framework around it, a mobile field interface
and an HTTP JSON API for the mobile client.

It is consumed as a plain jar dependency and knows nothing about any particular host.
Two hosts exist today: a mycompany-based ERP, and the artifact itself running alone.

## Layout

```
StoreTaskStandalone.lsf  the artifact running alone — the only module outside storeTasks/
storeTasks/
├── StoreTaskLib.lsf     the host-independent half, whole — a bundle of six packages:
├── StoreTaskCoreLib.lsf    the task subsystem proper: model, engine, reports, core API
├── StoreTaskMobileLib.lsf  the phone's home screen, presets, branding, their handles
├── StoreTaskNotifyLib.lsf  notifications: events, device registry, push via FCM, e-mail
├── StoreTaskAiLib.lsf      task creation from text through the ai-service
├── StoreTaskIntakeLib.lsf  external task intake: the request, its rules, apiTaskRequest
├── StoreTaskHypothesisLib.lsf  hypotheses about host data, checked by LLM-written code
├── StoreTask.lsf        aggregator for a mycompany-based host: StoreTaskLib + mycompany/
├── StoreTaskSettings.lsf
├── task/                the task itself, its statuses, types, priorities, tags, access
├── fillable/            the filling engine and the task kinds built on it
│                        (checklist, recount, pricing), printing
├── corrective/          photo-confirmation execution: corrective actions, issues
├── report/ schedule/    reports over fillings; task creation on a schedule
├── home/                the home screen and its blocks, the supervisor dashboard
├── mobile/ api/         the rest of the field interface and the JSON API
├── intake/              external task intake: the request and its rules
├── notification/        events, delivery channels (push via FCM, e-mail)
├── ai/                  task creation from text, through the ai-service
├── hypothesis/          hypotheses about host data and their scheduled checks
├── meta/                private copies of infrastructure metacode (see below)
├── mycompany/           bridges that require a mycompany-based host
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
    <artifactId>esb.tasks</artifactId>
    <version>1.0-SNAPSHOT</version>
</dependency>
```

```lsfusion
REQUIRE StoreTask;   // in the host's top module
```

`StoreTask` pulls in the `mycompany/` bridges, which map the subsystem's abstractions onto
what the ERP already has: `Assignee`/`Employee` become task performers, an inventory
`Location` becomes something inspectable, and the activity feed is wired onto the task
card.

The demo generators are a separate package, `demo/StoreTaskDemoLib`, that no production
aggregator pulls in — two of its actions delete every task in the database. A host that
is a demo stand adds it next to `StoreTask`; the standalone host takes the three
generators that need no ERP — `ScorecardDemo`, `IntakeDemo` and `PrintDemo` — on its own.

## Running it standalone

`StoreTaskStandalone` is the minimal host: it makes a logged-in `CustomUser` a task
performer — and closes the object seam in the same file, with hand-entered geo data, an
object tree and the `staffOn` availability channel (steps 2–3 below). Point the server at
it and it works on an empty database — no employees to set up, the admin account is a
performer out of the box.

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

**`logics.topModule` is required, not optional.** The artifact also ships the `mycompany/`
bridges, which REQUIRE `Assignee`, `Employee`, `Team`, `Location`, `LocationGeo` and
`Activity` — none of which exist in a standalone run. A top module makes the server drop
everything unreachable from it *before* dependencies are resolved
(`ModuleList.filterWithTopModule`), so those bridges are never loaded. Without the line
every module on the classpath takes part in dependency resolution, and the server dies
there with a line like `[error]: StoreTaskActivityErp: required module 'Activity' was not
found` (`ModuleList.buildModuleGraph`; the fields are separated by tabs, and which missing
module it names first depends on iteration order).

Run `lsfusion.server.logics.BusinessLogicsBootstrap` with this directory as the working
directory. The catalogues the subsystem cannot invent — task statuses, priorities, types,
notification events and the `executor`/`supervisor` roles — are seeded on every start
(`seedRequiredData`, #36984) and need no button. Load default data once from
*Application → Default data* — that creates the task numerator, the home-screen blocks,
the administrator rights and the intake-import right, switches e-mail on for «Проверка
завершена» and push on for the six events it exists for (#37345; the sixth is
`familiarized`). A host that also requires the option module `ExternalApp`
(`mobile/ExternalApp.lsf`) gets the `tsd` external application registered by the same
action; the standalone host does not require it, so no `tsd` appears here.

The scheduler jobs the subsystem lives by — schedule generation, log retention, deadline
notifications, delivery, hypotheses — register themselves on start
(`meta/StoreTaskRegulation`, from `onFinallyStarted`: `onStarted` runs before Reflection
is synchronized, and on a fresh database the action objects do not exist yet). Each
package registers its own job next to the action, so a core-only host gets two jobs —
schedule generation and log retention — not five. A job is recognized by name: an
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

This is a procedure, written to be followed by somebody who has not seen the subsystem
before. Two working references sit in this repository: the bridge `storeTasks/mycompany/`
and the minimal host `StoreTaskStandalone.lsf`. Of the two, only `StoreTaskStandalone`
is built and started here — the `mycompany/` bridges load on a mycompany-based host only,
so read their lines as a layout sample; the code that runs on this stand is
`StoreTaskStandalone`'s.

### Step 1. Depend, and give the server a top module that reaches your code

The artifact is consumed as a plain jar dependency:

```xml
<dependency>
    <groupId>lsfusion.solutions</groupId>
    <artifactId>esb.tasks</artifactId>
    <version>1.0-SNAPSHOT</version>
</dependency>
```

It is built and started on platform 6.2 (the parent in `pom.xml`); other platform lines
have not been checked. Step 5 is one of the known traps of the 6.x line, not the only
one.

In the host's top module:

```lsfusion
REQUIRE StoreTaskLib;
```

`StoreTaskLib` is the host-independent half. `StoreTask` is the same plus the
`mycompany/` bridges, and those REQUIRE `Assignee`, `Employee`, `Team`, `Location`,
`LocationGeo` and `Activity` — modules that exist only in a mycompany-based application.
A host built on anything else requires `StoreTaskLib`; requiring `StoreTask` fails at
startup with `Error in module 'StoreTaskPerformerErp': required module 'Assignee' was
not found.`

Point the server at your own top module — `logics.topModule = <your top module>` in the
server's `conf/settings.properties` (the standalone section above shows the file). A top
module makes the server drop everything unreachable from it *before* dependencies are
resolved (`ModuleList.filterWithTopModule`), so the mycompany bridges never load on
your host.

**The top module must also REQUIRE the host modules you write in step 4, by name.** The
reachability walk does follow `REQUIRE` chains transitively — a module reached through
another one loads — so the platform would carry your code if anything in the chain
required it; nothing does, because `StoreTaskLib` does not know your modules. Naming
them in the top module is also this project's convention, «транзитивному REQUIRE не
доверять»: whatever a module reads, it requires directly, because delivery through
somebody else's `REQUIRE` works only until that module drops it. The pattern to copy is
the aggregator `StoreTask.lsf`, which requires every bridge by name.
`StoreTaskStandalone.lsf` shows the convention's other face — the option modules
(`ObjectDimensionValue`, `SubjectStock`) and the seam owners it reads are named directly,
next to `Authentication`, which every server loads anyway. Skip this and the failure is
silent: the server starts without one error (`TaskUnit` is already a concrete
`TaskPerformer`, so the abstract class is not empty), but `performer(User)` has no
implementation, `currentPerformer()` is NULL for everyone, and every API handle answers
with a refusal — the `IF NOT currentPerformer()` guard stands across `api/`, `ai/`,
`mobile/` and `task/`. The phone is dead, the log is clean.

A host may also take less than `StoreTaskLib`. `StoreTaskCoreLib` alone is the task
subsystem with its desktop forms and the core of the JSON API; the other five packages
each require the core. A host without push and e-mail leaves out `StoreTaskNotifyLib`,
one without the AI service leaves out `StoreTaskAiLib`, and one that serves no phone at
all leaves out `StoreTaskMobileLib` too. The layers are not perfectly clean, and three
module-level links cross them — know them before you cut:

- `StoreTaskHypothesisLib` requires `StoreTaskIntakeLib` whole, so a host that leaves out
  the intake API leaves the hypothesis package out with it;
- the hypothesis module `hypothesis/HypothesisAi.lsf` requires `AiSettings`, a module of
  `StoreTaskAiLib`: a host that takes hypotheses but leaves out the AI package still gets
  the AI-service settings, and hypothesis code generation calls the ai-service itself
  (`/v1/hypothesis-code`, `HypothesisAi.lsf`) — without the service it is refused;
- the core itself requires `home/PulseRail.lsf`, which requires `SupervisorMetrics`, which
  requires `HomeScreen` — both modules of `StoreTaskMobileLib`: a core-only host carries
  the home-screen model and the supervisor metrics, though not the phone's handles.

None of these links reaches FCM, SMTP or the `AiServiceClient` module, so a host built on the
core alone still starts without them. The mass
task-creation mechanism (a batch of tasks by criterion, with its own form under
«Операции») lives in the core too: a host without the AI package still creates batches by
hand, and the package only parses the phrase and opens that same form.

### Step 2. Close the performer seam — the load-bearing one

The subsystem refuses to answer one question for itself: who can author a task, be
assigned one and execute it. Anchor `TaskPerformer` onto whatever your people are — the
reference anchors on `Assignee`, so that a task can also be given to a team
(`EXTEND CLASS Assignee : TaskPerformer;`), the minimal host on `CustomUser` — and close
the seams. Two of them are load-bearing; the rest degrade gracefully:

| seam | type | without it |
|---|---|---|
| `performer (User)` | `TaskPerformer` | **the subsystem is silently dead**: nothing in the core implements this seam — `currentPerformer()` is NULL and every API handle refuses, while the server starts clean |
| `id` | `ISTRING` | the phone and external writers cannot address a performer: devices cache it as `performerId`, API writes resolve it back through `taskPerformer()` |
| `name` | `ISTRING` | empty names in every list, card and picker |
| `in (TaskPerformer, User)` | `BOOLEAN` | **as deadly as a missing `performer (User)`**: membership feeds `hasIn` → `inAll` → the materialized `assignedTo (Task, User)`, so a task reaches nobody — not even the performer it is assigned to; every "mine" list, the phone and the notifications are silently empty while the server starts clean. A host with no teams closes it with the identity — `in (CustomUser p, User u) += p AS CustomUser = u AS CustomUser;` is `StoreTaskStandalone`'s whole implementation |
| `archived` | `BOOLEAN` | every performer reads as active |
| `email` | `STRING[400]` | e-mail notifications go nowhere; the single reader handles the empty value, and the reference bridge does not implement this seam at all |
| `parent` | `TaskPerformer` | no hierarchy — and none is needed: `level` degenerates to the object itself, `hasIn` equals plain `in`, everything works flat |

`in` is a membership relation rather than equality because a performer may be a unit,
not only a person: a task assigned to a department reaches everyone in it. `parent` is
the plain fact "which unit this unit belongs to"; the core computes the closure
(`level`, `hasIn`) and constrains self-parenting and cycles — do not duplicate that on
the host side.

Two warnings before the first `+=`:

- **Types.** A `+=` whose right side is wider than the abstract's type fails at startup.
  Cast inside the expression, the way the reference does:
  `id(Location l) += ISTRING[30](Inventory.id(l));` — `mycompany/CheckObjectLocation.lsf`
  narrows the numerator's `STRING[50]` to the seam's `ISTRING[30]` on the way in.
- **Materializations.** `level` and `hasIn` (for objects: `level` and `site`) are
  MATERIALIZED, and the platform recalculates only *new* materialized columns at startup.
  If your `parent()`/`in()` implementations land on top of data that is already filled —
  a hierarchy that exists, not an empty table — recalculate once by hand after the first
  start. The simplest way is *Обслуживание → Пересчитать материализации*, everything at
  once. The narrow way is *Администрирование → Система → Метаданные → Таблицы*, the
  action «Пересчитать материализации **(+зависимые)**» on the `level` column — the
  performer `level` and, for objects, the object `level`. Start from `level` and nowhere
  else: the action walks from the column *down* to what is computed from it, never up,
  so run on `hasIn` it would recount `hasIn` over a stale `level`; and the plain
  action without «(+зависимые)» recalculates the column alone and leaves the dependents
  stale. Do not confuse it with «Пересчитать материализации **(+зависимости)**» next to
  it in the same column: that one walks *up*, and pressed on `level` it leaves `hasIn`
  and `assignedTo` stale. The dependents are the point: `assignedTo
  (Task, User)` (`task/StoreTaskCore.lsf`), `reviewer` (`task/StoreTaskAcceptance.lsf`)
  and `watchedBy` (`task/TaskWatcher.lsf`) all sit on `hasIn`; on the object side
  `latitude`/`longitude`/`address` (`task/CheckObject.lsf`) sit on `site`, which reads
  `parent()` *and* the `own` coordinates — implementations of the `own` seams landing on
  filled data need the same recalc. Skip it and task lists and notifications are quietly
  empty. The warning also lives next to the abstract, `meta/TaskPerformer.lsf`.

The core ships one concrete performer of its own: `TaskUnit` («Подразделение»), with a
catalogue and a navigator item. It is not a substitute for this step — it does not
implement `performer(User)` — and on a host with its own org structure it simply stays
empty.

The working examples, at their honest size: `mycompany/StoreTaskPerformerErp.lsf` is one
module — `EXTEND CLASS Assignee`, six seam `+=`s (`id`, `name`, `archived`, `in` on
`Assignee`, `performer` on `Employee`, `parent` on `Team`), the `performerSelf` wrapper
behind `performer` (step 5), the `DATA` property behind `parent`, a name wrapper and two
`EXTEND FORM`s to enter it. The one-class case is `StoreTaskStandalone.lsf`, and even
there the host is more than its six performer `+=`s and their `performerSelf` wrapper:
an object tree, three `DATA` properties for geo, `staffOn`/`available`, a form extension.

### Step 3. Close the object seam — if tasks target anything

`CheckObject` is what a task is about: a store, a warehouse, a machine. Anchor it the
same way (`EXTEND CLASS Location : CheckObject;`) and close the seams:

| seam | type | without it |
|---|---|---|
| `id` | `ISTRING[30]` | the device cannot cache the object — "tasks of the place I am standing in" and every external addresser break |
| `name` | `ISTRING[150]` | empty names in lists, cards, reports |
| `ownAddress` | `ISTRING[250]` | a task shows in the phone with an empty address |
| `ownLatitude`, `ownLongitude` | `DOUBLE` | the object is invisible to every geo query: "where I stand" selects by `id(o) AND isSite(o)`, and `isSite` needs coordinates |
| `parent` | `CheckObject` | no tree — each object is its own branch, and `site` is the object itself whenever it has coordinates |
| `archived` | `BOOLEAN` | closed objects never retire: batch task creation does not skip them — its filter reads `archived` (`task/TaskBatch.lsf`) — so a host with closed stores keeps getting batch tasks for them |

The `own` prefix is the point. An object *stores* an address and coordinates only if it
is the place itself — a store, a warehouse. Everything standing inside it — a till, a
scanner, a fridge — stores nothing: it answers `parent`, and the core computes what it
*shows* (`address`, `latitude`, `longitude`) by walking up to the nearest ancestor with
coordinates (`CheckObject.site`). Do not implement `address`/`latitude`/`longitude`:
they are computed over the tree, not seams.

`CheckAsset` is the ready-made generic object — a device — and it closes `id` and `name`
by itself. It does **not** close the rest: address, coordinates and a place in the tree
remain the host's, because only the host knows where the device sits
(`fillable/CheckAsset.lsf` says so in the file). A host that skips this step gets
objects that are invisible to the phone — empty `site`, `latitude`, `longitude`,
`address`, `isSite` — and a phone with nowhere to stand. The minimal host does not skip
it: `StoreTaskStandalone.lsf` has three `DATA` properties for geo, the `own` seams over
them, and a manual column for the tree.

Where a `CheckAsset` sits in the tree is itself a seam: `assetLocation` (an abstract
`CheckObject` of a `CheckAsset`). The artifact already owns `parent` on `CheckAsset` —
it resolves `OVERRIDE assetLocation(a), parentObject(a)`, the manual column and the
external-task intake — so a host with its own notion of placement implements
`assetLocation`, not `parent`. That is what `mycompany/CheckAssetLocation.lsf` does:
`location = DATA Location (CheckAsset)` plus one `+=`.

Beyond the two anchors there are smaller host seams — each optional, each with a moment
when it starts to matter:

| seam | declared in | when you need it |
|---|---|---|
| `ObjectCategory` (`id`, `name`), `category (CheckObject)` | `task/ObjectCategory.lsf` | as soon as a schedule runs: the plan selects objects by category, and without the seam it creates no tasks at all. The core ships a thin catalogue for it, `CheckCategory` (`fillable/CheckCategory.lsf`, required by `StoreTaskCoreLib`), and closes `category` for `CheckAsset` in the same module — the standalone host uses both as is; a host with its own classifier bridges its own class onto `ObjectCategory` and leaves `CheckCategory` unused |
| `dimensionValue (CheckObject, ObjectDimension)` | `task/ObjectDimension.lsf` | read by report slices, by the batch filter (`inDimension`, `task/TaskBatch.lsf`) and by AI draft decisions (`ai/AiDraftDecision.lsf`); without it every slice is empty and a batch given by a dimension selects no objects. A host without its own source adds the option module `task/ObjectDimensionValue` (a user-maintained catalogue); a host with a source (region, city, format) implements the seam itself |
| `available (RefValue, CheckObject)` | `fillable/RefValue.lsf` | filters the subject channels of a form; without it a channel shows the whole catalogue. The option module `fillable/SubjectStock` implements it from stock for the `item` channel; `StoreTaskStandalone` implements it from roles (`staffOn`) |
| `responsible (CheckObject, ObjectRole)` | `task/ObjectRole.lsf` | when the host already knows who answers for an object (an ERP knows the store's manager). Whatever the host does not cover is entered by hand (`responsibleData`); the host is checked first on purpose |
| `overAssigned (TaskPerformer, CheckObject)` | `task/CheckObjectAccess.lsf` | when the host has its own "who answers for what" relation and it should feed the object-access table |
| `participant (Task, User)` | `task/StoreTaskCore.lsf` | the involvement seam, in OR: assignment and authorship (the core), the acceptor (`StoreTaskAcceptance`), the watcher (`TaskWatcher`) each add an implementation of this CASE abstract, and everything downstream reads the sum — `visibleTask`, the phone's `apiTasks`, correspondence access, the home screen. A host with its own notion of involvement adds one the same way. Do **not** add a second `visibleTask (Task)` implementation: `visibleTask` is a bare `ABSTRACT`, which is exclusive — its implementations must not overlap by classes — so a second one on `(Task)` or on any subclass of it stops the server at startup with `signature intersection of property … for abstract property StoreTask.visibleTask[StoreTask.Task]` instead of OR-ing with the core's |

### Step 4. Split the bridge: a module per entity, extensions apart

Two different things end up in a host's code, and they age differently:

- **an entity override** says "this host class IS a subsystem entity": `EXTEND CLASS
  ... :` plus the `+=` implementations of that entity's seams — and, in the same module,
  the data and forms those seams need. `mycompany/StoreTaskPerformerErp.lsf` is one: the
  `Assignee` override with its seams, and `parentTeam = DATA Team (Team)` with two
  `EXTEND FORM`s, because that `DATA` is what the `parent` seam reads — splitting them
  would leave a seam reading a property nobody enters.
- **a host extension** adds a function the subsystem does not have at all, and carries
  no `EXTEND CLASS`: `mycompany/CheckAssetLocation.lsf` only says which store a device
  belongs to, and closes the `assetLocation` seam of step 3 with it. The sample stops
  one step short on purpose: `location` has no input form anywhere in the artifact —
  only the demo generators write it — the host enters it through its own forms. A host
  copying the sample adds the form on its side, or the seam reads a property nobody
  enters.

When the artifact is updated, an override may have to follow a changed abstraction,
while an extension is your own data and should not move; one module holding both makes
every upgrade a merge. Implementing a seam does not by itself make a module an override —
`CheckAssetLocation` implements one and is still an extension. The question is whether
you are adding an entity or a function.

### Step 5. Never leave a bare parameter on the right side of `+=`

This is wrong on platform 6.x:

```lsfusion
performer (CustomUser u) += u;
```

A `+=` whose right side is a single bare parameter — in brackets or not — crashes module
parsing on platform 6.x (the 6.0–6.3 line, the artifact's own 6.2 included) with a
`NullPointerException` in `checkAndSetExplicitClasses`, and the log carries no module
name or line. Platform 7.0 parses the line, which is exactly why the bug survives a 7.0
stand: it is caught only by reading the code or building under the host's platform. Not
every `+=` is at risk: a right side that is an expression or a constant (`+= name(e)`,
`+= 'object'`) is safe, a signature of two or more parameters is safe
(`f (A a, B b) += a;`), and `+= WHEN … THEN x` never reaches the check — but the WHEN
form is allowed only for a CASE abstract, so for `performer` it is no option.

The cure is to give the right side a property. Both hosts in this repository do it with a
one-line wrapper, declared next to the implementation (`StoreTaskStandalone.lsf`, and
`mycompany/StoreTaskPerformerErp.lsf` with `Employee e`):

```lsfusion
performerSelf (CustomUser u) = u;
performer (CustomUser u) += performerSelf(u);
```

The declaration `= u` is not the problem — only the bare parameter after `+=` is. ERP
code cures the same case with a cast instead, `sku(Sku material) += material AS Sku`,
which gives the same value when the class is the one of the signature; this repository
keeps the wrapper because that is the form built and started here on 6.2. Whichever you
pick, no `+=` may end in a bare parameter. Search for one before you build:

```
grep -rnE '\+=\s*\(?\s*[A-Za-z_][A-Za-z_0-9]*\s*\)?\s*;' --include=*.lsf <your sources>
```

The command reads line by line, so an empty answer is not a proof: it misses a `+=`
whose bare parameter sits on the next line or in double brackets (`+= ((a));`). It also
lists safe lines — constants (`+= TRUE;`) and signatures of two parameters — and those
in its answer are not defects. The other `+=`s of the reference bridges need
nothing (`name(l) += Inventory.name(l)`).

### Step 6. What no bridge will do for you

In the order you meet them:

1. **Start the server.** Statuses, priorities, task types, notification events and the
   `executor`/`supervisor` roles are seeded on every start (`seedRequiredData`, #36984) —
   nothing to create by hand, and the seed is idempotent on a live base.
2. **Load default data once** (*Application → Default data*); what it creates is listed
   under "Running it standalone" above. The numerator is
   picked on the subsystem's options form; its series and counter live in the
   platform's numerator catalogue, not on the options form.
3. **The scheduler jobs** register themselves on start (`meta/StoreTaskRegulation`); which
   ones, and how a host with jobs of its own switches them off before the first start,
   is under "Running it standalone" above.
4. **Your own task types**, if the built-in ones are not enough: the pattern is
   `fillable/FormTask.lsf` and its siblings (`ChecklistTask`, `Recount`, `PriceCheck`);
   statuses and priorities are seeded in `task/StoreTaskInitial.lsf`.
5. **Rights.** Roles and their permissions live in `task/StoreTaskAccess.lsf`; which of
   your people get them is your data, and no bridge can decide it. Task visibility is
   restricted there too: the task list shows a task (`taskVisible`) to the system
   administrator, to anyone whose role has the right «Видеть все задачи»
   (`seeAllTasks`; default data grants it to the system administrator role), and
   otherwise only to the task's
   participants. So "who sees everything" is a role setting, given in rights, while
   widening "who sees this task" is a `participant` implementation (step 3). The right
   «Видеть все задачи» works on the desktop only: the phone's task list (`apiTasks`,
   `api/StoreTaskApi.lsf`) selects by `participant` alone, so on the phone a supervisor
   with that right sees only the tasks they take part in.

### Where hosts differ, and why it bites

Address and coordinates are the seam where two hosts look least alike, in names and in
types. On a mycompany host a store is a `Location`: its coordinates are
`Inventory.latitude`/`Inventory.longitude`, its address is `Inventory.addressCsv`. On an
lsfusion-erp host a store is a `Store`, which is a `POI` of the platform's `Geo` module.
`Geo` declares the point-of-interest seams abstract on `POI` — `mainAddress`
(`ISTRING[150]`) and `latitude`, `longitude` (`DOUBLE`); `Store` implements them from
its own columns: `mainAddress` from `Store.address` (`ISTRING[150]`),
`latitude`/`longitude` from `Store.latitude`/`Store.longitude` (`NUMERIC[11,6]`). So
there is one source with two faces: the `Geo` trio at the `POI` level and `Store`'s
columns at the `Store` level. Read the `Geo` trio — `mainAddress` for `ownAddress`,
`latitude`/`longitude` for the coordinates: the coordinates are already `DOUBLE`, the
type of the `own` coordinate seams, so no type changes on the way. `Geo` also has `address (POI)`, which takes
`additionalAddress` before `mainAddress`; it is not the store's address to read: base
lsfusion-erp does not implement `additionalAddress`, and where a customer's logic does,
it can be an address for geocoding. Reading
`Store.latitude` would compile as well — a `NUMERIC[11,6]` value is widened to `DOUBLE`
implicitly — and give the same coordinates; the choice is about the level you read at,
not about a second source. Check where the value comes from on your host, not only what
the property is called. No lsfusion-erp bridge lines are shown
here on purpose: that host is not built in this repository, and an unverified snippet in
an instruction is worse than none.

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
optional bridge in `mycompany/`.
