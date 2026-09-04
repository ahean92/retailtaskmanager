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
the task types, statuses, priorities and the task numerator.

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
