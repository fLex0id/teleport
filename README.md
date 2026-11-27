# Teleport — репозиторий обновлений для Linux

![Architecture](https://img.shields.io/badge/architecture-x86__64-blue) ![Packages](https://img.shields.io/badge/packages-RPM%20%7C%20DEB-blue)

Независимый репозиторий официальных пакетов Teleport с управляемой публикацией версий и GPG-подписью метаданных. Предназначен для Rocky Linux, Ubuntu и Debian (x86_64 / amd64). Не является официальным репозиторием производителя.

**Релизы:** [GitHub Releases](https://github.com/fLex0id/teleport/releases) · **Публикация:** [GitHub Actions](https://github.com/fLex0id/teleport/actions) · **Пакеты:** [GitHub Pages](https://flex0id.github.io/teleport/)

## 1. Подключение Linux-сервера

Выполняется один раз на каждом сервере, в том числе при переходе со старого репозитория reverse-proxy. Требуются Bash, curl, GnuPG, Python 3, права root и уже опубликованные подписанные метаданные.

Подключайтесь через независимый SSH-канал. Сначала скачайте и проверьте скрипт, затем укажите ранее проверенный 40-символьный fingerprint ключа подписи (вывод setup-publisher.sh или сохранённый доверенный ключ).

~~~bash
curl -4fsSL https://raw.githubusercontent.com/fLex0id/teleport/main/install-repo.sh -o /tmp/install-teleport-repo.sh
less /tmp/install-teleport-repo.sh
sudo env TELEPORT_REPO_EXPECTED_FPR='YOUR_VERIFIED_40_HEX_FINGERPRINT' bash /tmp/install-teleport-repo.sh
~~~

Если вы уже root, sudo не требуется.

Установщик определяет пакетный менеджер, проверяет fingerprint и GPG-подпись метаданных, настраивает постоянный источник пакетов, отключает обнаруженные официальные источники Teleport и обновляет метаданные. Службы Teleport не перезапускаются, пакеты не обновляются.

### Приоритет источников

| Linux | Конфигурация | Политика |
|---|---|---|
| Rocky Linux | /etc/yum.repos.d/flex0id-teleport.repo | priority=1; includepkgs=teleport; repo_gpgcheck=1 |
| Ubuntu / Debian | /etc/apt/sources.list.d/flex0id-teleport.list | signed-by; APT pin priority=700 для flex0id.github.io |

Официальные источники отключаются с сохранением резервных копий изменённых файлов (.before-flex0id-teleport.bak). Старый стандартный файл flex0id-teleport заменяется новым. Нестандартные зеркала и дополнительные источники необходимо проверить вручную. APT pinning по имени хоста не различает разные пути одного GitHub Pages домена, поэтому дублирующие источники должны быть отключены.

Проверка Rocky Linux:

~~~bash
dnf repolist --enabled
dnf --refresh repoquery --available teleport
~~~

Проверка Ubuntu / Debian:

~~~bash
apt-cache policy teleport
~~~

В выводе источником пакета teleport должен быть только flex0id.github.io/teleport. Если обнаружен дополнительный источник, отключите соответствующую секцию .repo или строку/stanza .list/.sources, не затрагивая системные репозитории.

## 2. Штатное обновление Teleport

После однократной настройки обновления выполняются стандартными командами от root, без повторного запуска install-repo.sh.

**Rocky Linux**

~~~bash
dnf update -y
~~~

**Ubuntu / Debian**

~~~bash
apt update && apt dist-upgrade -y
~~~

Эти команды обновляют также остальные системные пакеты. Для обновления только Teleport можно использовать dnf upgrade -y teleport или apt install --only-upgrade -y teleport после apt update.

Проверка:

~~~bash
teleport version
systemctl status teleport --no-pager
~~~

Репозиторий предлагает максимальную опубликованную стабильную версию из GitHub Releases после успешной сборки и развёртывания Pages. Например, 19.0.1. Новые версии производителя не загружаются автоматически: их утверждает владелец репозитория.

> Важно: при переходе между основными версиями (например, 18 → 19) проверьте совместимость, требования к обновлению и резервному копированию в документации Teleport. Обновляйте Auth/Proxy до SSH agents. Проверяйте версию реально запущенного процесса: установка пакета не гарантирует перезапуск службы. Teleport должен быть установлен как RPM или DEB; ручная установка бинарника требует отдельной миграции.

## 3. Публикация новой версии

1. Получите оригинальные пакеты производителя и независимо проверьте их происхождение и контрольные суммы.
2. Создайте draft release в [GitHub Releases](https://github.com/fLex0id/teleport/releases/new).
3. Укажите тег, например 19.0.1 (также поддерживаются v19.0.1 и teleport-v19.0.1; не дублируйте одну версию разными тегами).
4. Загрузите обязательные серверные пакеты:
   - `teleport-19.0.1-1.x86_64.rpm`
   - `teleport_19.0.1_amd64.deb`
5. Нажмите **Publish release**. Дополнительные пакеты Teleport Connect и Windows installers могут храниться в Releases, но не включаются в APT/RPM индексы.
6. Проверьте успешное завершение workflow **Publish approved Teleport package repositories** и развёртывание Pages.

GitHub Actions выбирает максимальную стабильную версию по числовым компонентам, проверяет SHA256 вложений и метаданные RPM/DEB, формирует индексы, подписывает их и публикует на GitHub Pages. При ошибке сборки новый сайт не развёртывается. Если релиз опубликован до загрузки всех пакетов, запустите workflow вручную.

Текущая опубликованная версия Pages: [current-release.txt](https://flex0id.github.io/teleport/current-release.txt).

## 4. Первичная настройка публикации (только владелец)

На доверенной Linux-машине с установленными gh и gpg под обычным пользователем:

~~~bash
gh auth login
curl -4fsSL https://raw.githubusercontent.com/fLex0id/teleport/main/setup-publisher.sh -o /tmp/setup-publisher.sh
less /tmp/setup-publisher.sh
bash /tmp/setup-publisher.sh
~~~

Скрипт использует существующий ключ из ~/.gnupg-teleport-repo/ либо создаёт новый, если ключ отсутствует. При миграции предпочтительно сохранить прежний ключ. Не создавайте новый ключ случайно на другой машине. Сохраните fingerprint и защищённую офлайн-копию ключа.

Настраиваются Actions Secrets:

- TELEPORT_REPO_GPG_PRIVATE_KEY
- TELEPORT_REPO_GPG_PASSPHRASE

Если автоматическое включение Pages не удалось: Settings → Pages → Build and deployment → Source → GitHub Actions.

После настройки secrets и публикации релиза запустите [workflow](https://github.com/fLex0id/teleport/actions/workflows/teleport-packages.yml) вручную через Run workflow (main).

## 5. Адреса и диагностика

| Ресурс | URL |
|---|---|
| APT | https://flex0id.github.io/teleport/apt/ |
| RPM | https://flex0id.github.io/teleport/rpm/x86_64/ |
| APT InRelease | https://flex0id.github.io/teleport/apt/dists/stable/InRelease |
| RPM repomd.xml | https://flex0id.github.io/teleport/rpm/x86_64/repodata/repomd.xml |
| Public key | https://flex0id.github.io/teleport/teleport-repo.asc |

При недоступности Pages или ошибке подписи не отключайте проверку GPG. Проверьте Actions, доступность Pages и доверенный fingerprint. Старые релизы сохраняются для ручного отката; Pages индексирует только последнюю утверждённую версию.

RPM: подписаны метаданные репозитория (repo_gpgcheck=1), отдельные RPM не переподписываются (gpgcheck=0); контрольные суммы пакетов защищены подписанными метаданными. APT: подписан InRelease. SHA256 вложений GitHub подтверждает целостность загрузки, но не заменяет проверку происхождения пакета производителя. Не публикуйте секретный ключ. Учитывайте срок действия ключа и ограничения GitHub Pages.

## 6. Структура проекта

| Файл | Назначение |
|---|---|
| [install-repo.sh](install-repo.sh) | Однократное подключение Linux-сервера |
| [setup-publisher.sh](setup-publisher.sh) | Настройка ключа и публикации |
| [build-repo.sh](build-repo.sh) | Проверка пакетов, сборка и подпись индексов |
| [teleport-packages.yml](.github/workflows/teleport-packages.yml) | CI/CD и развёртывание GitHub Pages |
