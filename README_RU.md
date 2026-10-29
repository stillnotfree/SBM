# SBM

SBM — нативный VPN-клиент для строки меню macOS на Apple silicon, основанный на одной закреплённой версии sing-box.

[English](README.md) · [Русский](README_RU.md) · [简体中文](README_ZH-CN.md)

## Возможности

- Управляемый VPN через TUN с режимами маршрутизации Rule, Global и Direct.
- Управляемые VLESS через поддерживаемые варианты TCP, HTTP, gRPC, WebSocket, QUIC и HTTPUpgrade; Hysteria2 через TLS; Shadowsocks SIP002 без плагинов.
- Локальные профили и HTTPS-подписки; сервер можно выбрать вручную или использовать Auto.
- Проверка задержки серверов и правила маршрутизации для сайтов и приложений.
- Отдельные настройки прямого и прокси-DNS, включая произвольные URL DNS-over-HTTPS.

SBM не импортирует произвольный sing-box JSON и не предоставляет все функции sing-box.

## Требования

- Mac с Apple silicon и macOS 26 или новее.
- При запросе macOS нужно разрешить работу фонового helper SBM.
- Приложение подписано ad-hoc; у него нет нотариального заверения и подписи Developer ID.

Скачивайте приложение только из [SBM GitHub Releases](https://github.com/stillnotfree/SBM/releases). Релиз содержит подписанное доказательство издателя `.update.json`. macOS может предупредить об ad-hoc приложении. Продолжайте открытие только если доверяете источнику и конкретному скачанному релизу. Не отключайте Gatekeeper или System Integrity Protection.

## Установка и обновление

1. Скачайте `SBM-<version>-arm64.dmg` из GitHub Releases и откройте его в Finder.
2. Перетащите `SBM.app` в «Программы». При обновлении выберите **Заменить**.
3. Откройте SBM и разрешите фоновый helper в macOS, если появится запрос.
4. Подключитесь, проверьте трафик и один раз отключитесь, чтобы убедиться в работе обеих команд.

Обновление заменяет приложение через Finder; SBM не заменяет себя автоматически. Установка или обновление helper может ненадолго прервать VPN.

## Скриншоты

<p align="center">
  <img src="docs/menu.png" alt="Меню SBM" width="62%">
</p>

<details>
<summary>Другие скриншоты</summary>

<p align="center">
  <img src="docs/settings.png" alt="Настройки" width="48%">
  <img src="docs/settings-profiles.png" alt="Профили" width="48%">
</p>

<p align="center">
  <img src="docs/settings-routing.png" alt="Маршрутизация" width="48%">
  <img src="docs/settings-advanced.png" alt="Расширенные настройки" width="48%">
</p>

</details>

## Сборка из исходного кода

Для сборки нужен Mac с Apple silicon, macOS 26 или новее, инструменты командной строки Xcode, Swift toolchain, выбранный Xcode, и установленный Go с разрешением загружать toolchain. Рецепт core выбирает закреплённый компилятор Go 1.26.10 через GOTOOLCHAIN.

```sh
make build
```

Команда локально собирает приложение и закреплённый sing-box 1.14.4. Она не устанавливает приложение и не создаёт приватное доказательство подписи релиза. Процедура локальных измерений приведена в [описании замеров производительности](docs/PERFORMANCE.md).

## Лицензия и безопасность

SBM распространяется по [лицензии MIT](LICENSE). Сведения о сторонних компонентах приведены в [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). В состав входит [sing-box](https://github.com/SagerNet/sing-box).

При разработке использовался ИИ-помощник OpenAI Codex под руководством и после проверки человеком. Независимый профессиональный аудит безопасности не проводился. Уязвимость можно конфиденциально сообщить по инструкции в [SECURITY.md](SECURITY.md).
