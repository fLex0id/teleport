# Teleport — репозиторий пакетов для Linux

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE) ![Architecture](https://img.shields.io/badge/architecture-x86__64-blue) ![Packages](https://img.shields.io/badge/packages-RPM%20%7C%20DEB-blue)

Независимый репозиторий оригинальных пакетов Teleport Server (`teleport`) и Teleport Connect (`teleport-connect`) с поддержкой штатной установки и обновления через APT и DNF. Метаданные репозитория защищены GPG-подписью.

**[Релизы](https://github.com/fLex0id/teleport/releases)** · **[Текущая версия](https://flex0id.github.io/teleport/current-release.txt)** · **[Репозиторий пакетов](https://flex0id.github.io/teleport/)**

> **Интерактивный установщик Teleport (Server / SSH Agent)**
>
> [**https://flex0id.github.io/teleport/tp.sh**](https://flex0id.github.io/teleport/tp.sh)

## Поддерживаемые платформы

| Дистрибутив | Архитектура | Пакетный менеджер |
|---|---|---|
| Rocky Linux | x86_64 | DNF |
| Ubuntu / Debian | amd64 | APT |

## Интерактивное развёртывание сервера или SSH-агента

На чистом Linux x86_64 с systemd запустите от root:

~~~bash
curl -4fLO https://flex0id.github.io/teleport/tp.sh &&
bash tp.sh
~~~

Установщик предлагает два режима: основной кластер (Auth/Proxy/SSH) и SSH-агент. Он подключает подписанный репозиторий, устанавливает зависимости и настраивает службу. Для основного кластера необходимы DNS-имя и доступный TCP 443; агенту требуется исходящее подключение к кластеру и регистрационный токен. Скрипт не открывает TCP 22. Перед использованием проверьте работу на тестовом VPS; автоматизированные проверки не заменяют проверку реального развёртывания.

### Отключение прямого OpenSSH

После успешного развёртывания и проверки нового SSH-сеанса через Teleport можно открыть пункт 8 (OpenSSH management). Установщик предлагает отключение служб и socket activation OpenSSH, блокировку обнаруженных SSH-портов через активный UFW/firewalld и восстановление исходных настроек. Teleport не отключается. Не подтверждайте отключение, пока не проверены реальный вход через Teleport и доступ к VNC.

Для восстановления запустите сохранённый tp.sh через VNC и выберите 8 → 2. Резервные сведения находятся в `/var/lib/teleport-deploy/openssh-backup`. При отсутствии активного UFW/firewalld скрипт отключает слушатели OpenSSH, но не изменяет произвольные nftables/iptables или облачный firewall. Существующие пользовательские политики могут требовать отдельной проверки.

### Резервный доступ при отказе DNS

Обычная загрузка через системный DNS всегда имеет приоритет. Только если имя репозитория не разрешается (код curl 6), установщик пробует резервные DNS-запросы и документированные IPv4 GitHub Pages: `185.199.108.153`, `185.199.109.153`, `185.199.110.153`, `185.199.111.153`. Проверка TLS и GPG не отключается. Для APT/DNF резервное сопоставление имени действует только в приватном пространстве монтирования дочернего процесса; системные DNS и /etc/hosts не изменяются. Меню выбора UDP/DoH и проверки DNS работают независимо.

Если DNS не работает ещё до скачивания самого скрипта, сначала попробуйте штатную команду выше. Только при ошибке разрешения имени используйте:

~~~bash
curl -4fLO --resolve flex0id.github.io:443:185.199.108.153 https://flex0id.github.io/teleport/tp.sh &&
bash tp.sh
~~~

При недоступности первого IP можно попробовать остальные три. Резервный механизм не заменяет работающий DNS для системных зеркал, ACME и домена кластера. Если приватное пространство монтирования недоступно, восстановите DNS перед установкой пакета.

## 1. Подключение репозитория

Выполните один раз на каждом Linux-сервере или рабочей станции. Для первоначального скачивания требуются Bash, curl и права администратора. Установщик автоматически устанавливает недостающие GnuPG, Python 3, AWK и CA-сертификаты через системный пакетный менеджер, не заменяя имеющийся curl-minimal. Для установки зависимостей необходим доступ к системным репозиториям.

Скачайте установщик и запустите его с указанным отпечатком публичного ключа.

~~~bash
f=$(mktemp) &&
curl -4fsSL https://raw.githubusercontent.com/fLex0id/teleport/main/install-repo.sh -o "$f" &&
sudo env TELEPORT_REPO_EXPECTED_FPR=95AB1A0D022288C96B135E395D6220FDB9C74356 bash "$f"
~~~

Если вы уже работаете под root, используйте вместо этих команд:

~~~bash
f=$(mktemp) &&
curl -4fsSL https://raw.githubusercontent.com/fLex0id/teleport/main/install-repo.sh -o "$f" &&
TELEPORT_REPO_EXPECTED_FPR=95AB1A0D022288C96B135E395D6220FDB9C74356 bash "$f"
~~~

Установщик определяет пакетный менеджер, проверяет отпечаток публичного ключа и подпись метаданных, подключает репозиторий, отключает обнаруженные стандартные официальные источники Teleport с сохранением резервных копий их изменённых конфигураций и обновляет метаданные. Установка или обновление пакета и перезапуск службы при этом не выполняются.

Подключая независимый репозиторий, вы доверяете его владельцу распространять пакеты и подписывать метаданные. Сверьте отпечаток ключа по доверенному источнику.

## 2. Установка Teleport

**Rocky Linux**

~~~bash
sudo dnf install -y teleport
# Teleport Connect (desktop client)
sudo dnf install -y teleport-connect
~~~

**Ubuntu / Debian**

~~~bash
sudo apt update && sudo apt install -y teleport
# Teleport Connect (desktop client)
sudo apt install -y teleport-connect
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

Эти команды обновляют также остальные системные пакеты. Для отдельного обновления Teleport Server или Teleport Connect (выберите установленный пакет):

~~~bash
sudo dnf upgrade -y teleport
sudo dnf upgrade -y teleport-connect
~~~

~~~bash
sudo apt update && sudo apt install --only-upgrade -y teleport
sudo apt install --only-upgrade -y teleport-connect
~~~

Если команды выполняются под root, sudo не требуется.

Репозиторий содержит последнюю успешно опубликованную стабильную версию Teleport Server и Teleport Connect из GitHub Releases. Windows Installer доступен в Releases, но не индексируется в APT/DNF. Пакетные менеджеры обновляют только уже установленные пакеты: подключение репозитория не устанавливает сервер или клиент автоматически.

> Перед обновлением основных версий ознакомьтесь с требованиями производителя, сделайте резервную копию и соблюдайте порядок обновления компонентов кластера. Установка пакета не гарантирует перезапуск уже работающей службы.

### Закрепление версии на узлах кластера

Репозиторий содержит только последнюю версию, поэтому общее обновление системы может перескочить через мажорную версию Teleport или обновить агент раньше Proxy. Чтобы этого не случилось, закрепите пакет:

~~~bash
# Ubuntu / Debian
sudo apt-mark hold teleport
# Rocky Linux
sudo dnf install -y 'dnf-command(versionlock)'
sudo dnf versionlock add teleport
~~~

Перед плановым обновлением снимите закрепление (`apt-mark unhold teleport` или `dnf versionlock delete teleport`), проверьте, что опубликованная версия подходит по [правилам обновления](https://goteleport.com/docs/upgrading/overview/), и после обновления закрепите пакет снова.

## 4. Проверка и диагностика

**Rocky Linux**

~~~bash
dnf list --showduplicates teleport teleport-connect
~~~

**Ubuntu / Debian**

~~~bash
apt-cache policy teleport teleport-connect
~~~

Убедитесь, что пакет предлагается из `https://flex0id.github.io/teleport/`. Если имеются дополнительные нестандартные источники пакета, отключите их, не затрагивая системные репозитории.

Проверка установленной версии сервера:

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

### Продление ключа подписи

Ключ создаётся на 2 года. Дату окончания показывает `gpg --homedir ~/.gnupg-teleport-repo -K`. Продлите ключ заранее:

1. `gpg --homedir ~/.gnupg-teleport-repo --quick-set-expire <отпечаток> 2y`
2. Снова запустите `setup-publisher.sh`.
3. Запустите workflow публикации репозитория.
4. Повторите подключение репозитория (раздел 1) на каждом клиенте. Если DNF всё ещё сообщает об истёкшем ключе, выполните `sudo dnf clean all`.

Отпечаток ключа при продлении не меняется.

## 5. Лицензирование

Собственные скрипты, конфигурации CI/CD и документация распространяются по [MIT License](LICENSE). MIT не распространяется на оригинальные пакеты Teleport и сторонние компоненты.

[LICENSE-TELEPORT](LICENSE-TELEPORT) содержит текст Teleport Community Edition License для ознакомления. Для каждой версии и компонента действуют применимые лицензии и уведомления, поставляемые с оригинальными пакетами.

Репозиторий не является официальным ресурсом производителя и не аффилирован с Gravitational, Inc. Права на Teleport и его товарные знаки принадлежат соответствующим правообладателям. Перед использованием и распространением ознакомьтесь с применимыми лицензионными условиями.
