<p align="center">
  <img src="Resources/AppIcon.icon/Assets/sing-box.png" width="144" alt="Иконка SBM">
</p>

<h1 align="center">SBM</h1>

<p align="center">
  Минималистичный нативный клиент sing-box для macOS и Apple Silicon.
</p>

<p align="center">
  <a href="https://github.com/stillnotfree/SBM/releases/latest"><img src="https://img.shields.io/github/v/release/stillnotfree/SBM?sort=semver" alt="Последняя версия"></a>
  <a href="https://github.com/stillnotfree/SBM/releases"><img src="https://img.shields.io/github/downloads/stillnotfree/SBM/total" alt="Загрузки"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-black?logo=apple" alt="macOS 26 или новее">
  <img src="https://img.shields.io/badge/Apple%20Silicon-native-black" alt="Нативная поддержка Apple Silicon">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/stillnotfree/SBM" alt="Лицензия MIT"></a>
</p>

<p align="center">
  <a href="README.md">English</a> · Русский
</p>

> **О разработке:** проект преимущественно создан ИИ-агентом OpenAI Codex под
> руководством человека, с последующим тестированием и проверкой. Независимый
> профессиональный аудит безопасности не проводился.

## Возможности

- Нативное приложение на Swift в строке меню, TUN-режим без Electron.
- Режимы Rule, Global и Direct, автоматический или ручной выбор сервера.
- Несколько HTTPS-подписок и ссылок VLESS/Hysteria2 в одном профиле.
- Отдельные User-Agent, X-Device-OS и X-HWID для каждой подписки.
- JSON-конфиги sing-box для остальных поддерживаемых ядром протоколов.
- Без system proxy, веб-панели, статистики трафика, телеметрии и access-логов.

## Установка

1. Скачайте последнюю DMG для Apple Silicon в
   [GitHub Releases](https://github.com/stillnotfree/SBM/releases/latest).
2. Откройте DMG и перенесите **SBM.app** в Applications.
3. Если Gatekeeper заблокирует запуск, выберите **System Settings > Privacy &
   Security > Open Anyway**.
4. Откройте **Profiles…** и добавьте подписку, ссылку подключения или JSON-профиль
   sing-box.

SBM запускается при входе в macOS и автоматически подключает выбранный
сохранённый профиль.

## Источники профилей

В одном управляемом профиле можно объединить:

- несколько компактных HTTPS-подписок;
- несколько ссылок `vless://`, `hysteria2://` и `hy2://`.

Для каждой HTTPS-подписки отдельно настраиваются `User-Agent`, `X-Device-OS` и
`X-HWID`. Значения по умолчанию подходят провайдерам, которые отдают конфиг
только клиентам, похожим на Shadowrocket. При переходе на другой origin
секретные заголовки удаляются. Точные дубликаты подключений объединяются,
максимум — 63 подключения в профиле.

Отдельными профилями поддерживаются:

- локальный JSON-профиль sing-box;
- JSON-профиль sing-box по HTTPS.

Полный JSON-профиль намеренно не смешивается с компактными источниками.

К управляемым подпискам и ссылкам можно добавить собственный JSON с
маршрутизацией. Пример
[`Examples/routing-ru-direct.json`](Examples/routing-ru-direct.json) направляет
российские домены и IP-диапазоны напрямую, оставляя остальной трафик через VPN.
Списки загружаются из официального репозитория SagerNet и обновляются ядром.

Нативные JSON-профили сохраняют собственные outbounds, DNS, правила
маршрутизации и удалённые rule-set. Если в профиле нет selector или URLTest,
приложение создаёт локальные группы выбора сервера и Auto.

Перед активацией итоговый конфиг обязательно проходит `sing-box check`.
Неудачное применение откатывается к предыдущей рабочей конфигурации.

## Требования

- Mac с Apple Silicon;
- macOS 26 или новее;
- права администратора для установки фонового helper.

## Разрешение фонового helper

Приложению нужен привилегированный helper для управления TUN-интерфейсом.
Ad-hoc подпись может потребовать открыть **System Settings > General > Login
Items & Extensions** и разрешить `SBMHelper`.

Обычный выход, включая **Disconnect & Quit** и Command-Q, сначала отключает VPN
и останавливает ядро. Недоступный helper не блокирует закрытие приложения.

## Профили и приватность

Профили и учётные данные хранятся в
`~/Library/Application Support/SBM/profiles.json` с правами `0600`. Это устраняет
запросы Keychain, но не защищает данные от другого вредоносного ПО, уже
работающего от имени того же пользователя macOS.

Локальный SOCKS5, если включён, слушает только `127.0.0.1`. Управляющий API также
доступен только через loopback. Приложение не ведёт access-логи и ограничивает
размер warning-лога.

## Обновления

SBM проверяет GitHub Releases не чаще одного раза в сутки или вручную. Загрузка
принимается только по HTTPS, только для точного Apple Silicon DMG и только при
совпадении SHA-256 digest, опубликованного GitHub. Установка остаётся ручной:
проверенная DMG открывается, после чего пользователь заменяет приложение.

## Сборка

```sh
make dmg
```

Готовая DMG появляется в `dist/`.

## Статус

Версия 1.1.0 не является независимо аудированным продуктом безопасности.
Мульти-подписки, пользовательские заголовки, VLESS + REALITY + Vision и
Hysteria2 + TLS покрыты тестами, однако это не означает проверку каждого
протокола sing-box с каждым провайдером.

О предполагаемых уязвимостях сообщайте через
[закрытый канал GitHub](SECURITY.md), а не в публичном issue.
