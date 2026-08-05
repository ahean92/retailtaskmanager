# Сборка через зеркало repo.lsfusion.ru

Если при `mvn` сборке не открывается `https://repo.lsfusion.org` (таймауты,
`Connection reset`, `Could not transfer artifact ... from/to lsfusion`), все зависимости
можно тянуть через зеркало **https://repo.lsfusion.ru**.

Зеркало отдаёт и артефакты lsFusion (релизы и `-SNAPSHOT`), и проксирует Maven Central,
поэтому его можно объявить зеркалом *всех* репозиториев сразу.

**`pom.xml` проекта менять не нужно** — настройка живёт в пользовательском
`settings.xml` и действует на все проекты на машине.

## Настройка

Создайте (или дополните) файл:

* Windows — `%USERPROFILE%\.m2\settings.xml`
* Linux / macOS — `~/.m2/settings.xml`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0
                              https://maven.apache.org/xsd/settings-1.0.0.xsd">

    <mirrors>
        <mirror>
            <id>lsfusion-ru</id>
            <name>lsFusion mirror (RU)</name>
            <url>https://repo.lsfusion.ru</url>
            <mirrorOf>*</mirrorOf>
        </mirror>
    </mirrors>

    <profiles>
        <profile>
            <id>lsfusion</id>
            <repositories>
                <repository>
                    <id>lsfusion</id>
                    <url>https://repo.lsfusion.org</url>
                    <releases><enabled>true</enabled></releases>
                    <snapshots><enabled>true</enabled></snapshots>
                </repository>
            </repositories>
            <pluginRepositories>
                <pluginRepository>
                    <id>lsfusion</id>
                    <url>https://repo.lsfusion.org</url>
                    <releases><enabled>true</enabled></releases>
                    <snapshots><enabled>true</enabled></snapshots>
                </pluginRepository>
            </pluginRepositories>
        </profile>
    </profiles>

    <activeProfiles>
        <activeProfile>lsfusion</activeProfile>
    </activeProfiles>
</settings>
```

Как это работает:

* `<mirrorOf>*</mirrorOf>` перехватывает **любой** репозиторий — и `central`, и
  `lsfusion` из `pom.xml`, и репозитории плагинов — и подменяет URL на
  `repo.lsfusion.ru`. Сам `repo.lsfusion.org` при сборке уже не запрашивается.
* Профиль `lsfusion` нужен только чтобы репозиторий с таким id существовал и в тех
  проектах, где он не объявлен в `pom.xml` (например при сборке самой платформы), и
  чтобы для него были явно разрешены снапшоты. URL в профиле остаётся `.org` — его всё
  равно перехватит зеркало.

## Проверка

```bash
mvn -U clean install
```

В логе `Downloading from lsfusion-ru: https://repo.lsfusion.ru/...` — значит настройка
подхватилась. Если всё ещё видно `Downloading from lsfusion: https://repo.lsfusion.org/`,
Maven читает другой `settings.xml` — проверьте вывод:

```bash
mvn -X help:effective-settings
```

Доступность зеркала отдельно от Maven:

```bash
curl -I https://repo.lsfusion.ru/lsfusion/platform/server/maven-metadata.xml
```

## Если раньше сборка уже падала

Maven запоминает неудачные попытки скачивания и сутки их не повторяет. После настройки
зеркала соберите с `-U` (форсировать обновление) либо удалите маркеры неудач:

* Windows PowerShell:

```powershell
Get-ChildItem "$env:USERPROFILE\.m2\repository" -Recurse -Filter *.lastUpdated | Remove-Item
```

* Linux / macOS:

```bash
find ~/.m2/repository -name '*.lastUpdated' -delete
```

Битые/пустые jar-ы (частично скачанные до обрыва) лечатся удалением соответствующей
папки в `~/.m2/repository`, в крайнем случае — всей `~/.m2/repository`.

## Варианты применения

**Только для одной сборки, без правки глобального файла** — положите такой же файл рядом
с проектом и укажите его явно:

```bash
mvn -s ./settings-ru.xml clean install
```

**Точечное зеркалирование** (если нужно, чтобы остальные репозитории ходили напрямую, а
через зеркало шли только lsFusion и Central):

```xml
<mirrorOf>lsfusion,central</mirrorOf>
```

**Оставить возможность обхода зеркала для отдельного репозитория** — префикс `!`:

```xml
<mirrorOf>*,!internal-corp-repo</mirrorOf>
```

## IDE

* **IntelliJ IDEA** — использует тот же `~/.m2/settings.xml`. После правки:
  *Settings → Build, Execution, Deployment → Build Tools → Maven* — убедиться, что в
  *User settings file* указан нужный файл, затем в панели Maven нажать
  *Reload All Maven Projects*.
* **Eclipse** — *Preferences → Maven → User Settings*, кнопка *Update Settings*.

## Откат

Убрать блок `<mirrors>` из `settings.xml` (или закомментировать) — сборка снова пойдёт
напрямую в `repo.lsfusion.org`.
