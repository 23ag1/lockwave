# LockWave

Музыка на экране блокировки Mac: обложка, название, волна трека от края до края экрана и кнопки «назад / пауза / вперёд» — прямо под часами, пока Mac заблокирован.

*Music on the Mac lock screen: the cover, the song, its wave across the display and playback buttons under the clock while the Mac is locked.*

Работает с Apple Music, Spotify, браузерами (YouTube, SoundCloud, Яндекс Музыка в Arc, Chrome, Safari) — со всем, что macOS показывает в «Сейчас играет».

## Установка

1. Скачай `LockWave.zip` из [Releases](https://github.com/23ag1/lockwave/releases/latest) и распакуй.
2. Перетащи `LockWave.app` в «Программы».
3. Приложение не подписано сертификатом Apple, поэтому при первом запуске macOS его заблокирует. Открой **Системные настройки → Конфиденциальность и безопасность**, пролистай вниз и нажми **«Всё равно открыть»** напротив LockWave.
   Или одной командой в Терминале: `xattr -dr com.apple.quarantine /Applications/LockWave.app`
4. В строке меню появится значок волны. Заблокируй Mac (⌃⌘Q) — плеер будет под часами.

Никаких разрешений не нужно. В меню значка: включить/выключить, запуск при входе, «Показать сейчас» — посмотреть плеер без блокировки.

## Требования

macOS 14 или новее, Mac на Apple Silicon. Кнопки «стекла» (Liquid Glass) — на macOS 26 и новее.

## Откуда это

LockWave — это плеер экрана блокировки из [Vorssaint](https://github.com/vorssaint/vorssaint-utils), вынесенный в отдельное маленькое приложение без всего остального. Код плеера, волны и чтения «Сейчас играет» — Vorssaint; здесь — обвязка, чтобы он работал сам по себе.

Лицензия — GPL-3.0-or-later, как у Vorssaint. См. [LICENSE](LICENSE).

## Сборка

Нужен Xcode 26 (или Command Line Tools со Swift 6.2):

```sh
./build.sh
open build/LockWave.app
```
