# Teleport — репозиторий пакетов для Linux

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE) ![Architecture](https://img.shields.io/badge/architecture-x86__64-blue) ![Packages](https://img.shields.io/badge/packages-RPM%20%7C%20DEB-blue)

Независимый репозиторий оригинальных пакетов Teleport с поддержкой штатной установки и обновления через APT и DNF. Метаданные репозитория защищены GPG-подписью.

**[Релизы](https://github.com/fLex0id/teleport/releases)** · **[Текущая версия](https://flex0id.github.io/teleport/current-release.txt)** · **[Репозиторий пакетов](https://flex0id.github.io/teleport/)**

## Поддерживаемые платформы

| Дистрибутив | Архитектура | Пакетный менеджер |
|---|---|---|
| Rocky Linux | x86_64 | DNF |
| Ubuntu / Debian | amd64 | APT |

## 1. Подключение репозитория

Выполните один раз на каждом Linux-сервере. Требуются Bash, curl, GnuPG, Python 3 и права администратора.

Скачайте установщик и запустите его с указанным отпечатком публичного ключа.

~~~bash
curl -4fsSL https://raw.githubusercontent.com/fLex0id/teleport/main/install-repo.sh -o /tmp/install-teleport-repo.sh
sudo env TELEPORT_REPO_EXPECTED_FPR=95AB1A0D022288C96B135E395D6220FDB9C74356 bash /tmp/install-teleport-repo.sh
~~~

Если вы уже работаете под root, используйте вместо последней команды:

~~~bash
TELEPORT_REPO_EXPECTED_FPR=95AB1A0D022288C96B135E395D6220FDB9C74356 bash /tmp/install-teleport-repo.sh
~~~

Установщик определяет пакетный менеджер, проверяет отпечаток публичного ключа и подпись метаданных, подключает репозиторий, отключает обнаруженные стандартные официальные источники Teleport с сохранением резервных копий их изменённых конфигураций и обновляет метаданные. Установка или обновление пакета и перезапуск службы при этом не выполняются.

Подключая независимый репозиторий, вы доверяете его владельцу распространять пакеты и подписывать метаданные. Сверьте отпечаток ключа по доверенному источнику.

## 2. Установка Teleport

**Rocky Linux**

~~~bash
sudo dnf install -y teleport
~~~

**Ubuntu / Debian**

~~~bash
sudo apt update && sudo apt install -y teleport
~~~

## 3. Обновление Teleport

После однократного подключения репозитория используйте штатные команды пакетного менеджера. Повторный запуск установщика не требуется.

**Rocky Linux**

~~~bash
sudo dnf update -y
~~~

**Ubuntu / Debian**

~~~bash
sudo apt update && sudo apt dist-upgrade -y
~~~

Эти команды обновляют также остальные системные пакеты. Для обновления только Teleport:

~~~bash
sudo dnf upgrade -y teleport
~~~

~~~bash
sudo apt update && sudo apt install --only-upgrade -y teleport
~~~

Если команды выполняются под root, sudo не требуется.

Репозиторий содержит последнюю успешно опубликованную стабильную серверную версию из GitHub Releases. Teleport Connect и другие дополнительные дистрибутивы доступны в Releases, но не индексируются в APT/DNF.

> Перед обновлением основных версий ознакомьтесь с требованиями производителя, сделайте резервную копию и соблюдайте порядок обновления компонентов кластера. Установка пакета не гарантирует перезапуск уже работающей службы.

## 4. Проверка и диагностика

**Rocky Linux**

~~~bash
dnf list --showduplicates teleport
~~~

**Ubuntu / Debian**

~~~bash
apt-cache policy teleport
~~~

Убедитесь, что пакет предлагается из `https://flex0id.github.io/teleport/`. Если имеются дополнительные нестандартные источники пакета, отключите их, не затрагивая системные репозитории.

Проверка установленной версии:

~~~bash
teleport version
systemctl status teleport --no-pager
~~~

### Адреса репозитория

| Ресурс | Адрес |
|---|---|
| APT | https://flex0id.github.io/teleport/apt/ |
| RPM | https://flex0id.github.io/teleport/rpm/x86_64/ |
| Public GPG key | [teleport-repo.asc](https://flex0id.github.io/teleport/teleport-repo.asc) |
| Fingerprint | [signing-fingerprint.txt](https://flex0id.github.io/teleport/signing-fingerprint.txt) |

APT проверяет подписанные метаданные InRelease. DNF проверяет подпись метаданных через repo_gpgcheck=1; отдельные RPM не переподписываются (gpgcheck=0), их контрольные суммы защищены подписанными метаданными. При ошибке подписи не отключайте проверку GPG.

## 5. Лицензирование

Собственные скрипты, конфигурации CI/CD и документация распространяются по [MIT License](LICENSE). MIT не распространяется на оригинальные пакеты Teleport и сторонние компоненты.

[LICENSE-TELEPORT](LICENSE-TELEPORT) содержит текст Teleport Community Edition License для ознакомления. Для каждой версии и компонента действуют применимые лицензии и уведомления, поставляемые с оригинальными пакетами.

Репозиторий не является официальным ресурсом производителя и не аффилирован с Gravitational, Inc. Права на Teleport и его товарные знаки принадлежат соответствующим правообладателям. Перед использованием и распространением ознакомьтесь с применимыми лицензионными условиями.
