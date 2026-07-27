# claude limits gachi soundboard

[![release](https://img.shields.io/badge/release-v1.7.1-ff598c)](https://github.com/marblecake88/claude-limits-gachi-soundboard/releases)
[![downloads](https://img.shields.io/github/downloads/marblecake88/claude-limits-gachi-soundboard/total)](https://github.com/marblecake88/claude-limits-gachi-soundboard/releases)
[![license](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
![macos](https://img.shields.io/badge/macos-14%2B-black)
![swift](https://img.shields.io/badge/swift-6-f05138)

[English below](#english)

Гачи-саундборд в строке меню макоса. Заодно показывает лимиты Claude Code и умеет
будить Claude ночью, чтобы к твоему пробуждению у тебя было 99% 5часового лимита и час до закрытия окна.

## что умеет

- саундборд: жмёшь кошку, играет случайный гачи звук. или тыкаешь конкретный на сетке
- лимиты Claude прямо в строке меню: 5-часовое окно, недельный, сколько до сброса
- keep-alive: в нужное время стартует клаудекоде окно, чтобы к нужному часу у тебя было 99% лимита и час до закрытия окна.
  работаешь с 8, ставишь 9. если мак спит ночью, приложение показывает команду для pmset,
  которую надо один раз вставить в терминал: прав приложение не просит
- трата в долларах по тарифам API, считается локально из транскриптов
- статистика: жмёшь STATS в панели лимитов, окно разъезжается вправо. токены по дням,
  активность, модели, стрики. периоды сегодня/неделя/месяц/всё
- уведомления об окончании: когда claude в другом окне закончил и ждёт вас, строка меню
  прокручивает имя проекта. включается кнопкой в панели, ставит хук в настройки claude.
  если вы смотрите в то же окно, приложение молчит (для этого нужен доступ к Accessibility)
- интерфейс на английском, если система не русская. переключатель RU/EN в панели

Строка меню всегда показывает лимиты. По клику открывается борд, лимиты вторым
экраном. Зайдёшь в лимиты хоть раз, дальше открывается сразу на них.

## скрины

<img src="docs/board.png" width="300"> <img src="docs/limits.png" width="300">

## поставить

через brew:

    brew trust marblecake88/tap
    brew install --cask marblecake88/tap/claude-limits-gachi-soundboard

trust нужен один раз, свежий homebrew иначе не грузит каски из сторонних тапов.

или руками: взять LimitNotifier.zip из [релизов](https://github.com/marblecake88/claude-limits-gachi-soundboard/releases), распаковать, перетащить в /Applications.

нужен macos 14 и установленный залогиненный Claude Code, цифры берутся из него.
когда выходит новая версия, приложение само пишет об этом в углу панели.

## поставить с нуля на чистом маке

если нет ни brew, ни claude code, всё ставится одной пачкой:

    # homebrew
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    # claude code, без него цифр не будет
    brew install --cask claude-code

    # войти в аккаунт: откроется браузер
    claude

    # само приложение
    brew trust marblecake88/tap
    brew install --cask marblecake88/tap/claude-limits-gachi-soundboard
    open /Applications/LimitNotifier.app

homebrew в конце установки печатает пару команд про PATH, их надо выполнить,
иначе brew не найдётся в новой вкладке терминала.

## обновить без brew

если brew не стоит, обновление одной пачкой в терминале:

    pkill -f LimitNotifier.app
    cd ~/Downloads
    curl -L -o LimitNotifier.zip https://github.com/marblecake88/claude-limits-gachi-soundboard/releases/latest/download/LimitNotifier.zip
    unzip -oq LimitNotifier.zip
    rm -rf /Applications/LimitNotifier.app
    mv LimitNotifier.app /Applications/
    open /Applications/LimitNotifier.app

настройки лежат отдельно и переустановку переживают. ссылка всегда ведёт на свежий релиз.

## собрать самому

    ./make-app.sh release install

нужен только xcode command line tools, зависимостей нет.

## лицензия

код под MIT, звуки принадлежат их авторам.

---

## English

Gachi soundboard for the macOS menu bar. It also shows your Claude Code limits and wakes
Claude overnight so by the time you wake up you have 99% of the 5-hour limit and an hour before the window closes.

### what it does

- soundboard: click the cat for a random gachi, or tap a specific one on the grid
- Claude limits right in the menu bar: 5-hour window, weekly, time to reset
- keep-alive: starts a claude-code window at the set time, so by your hour you have 99% of the limit
  and an hour before it closes. you start at 8, set it to 9. if your mac sleeps at night, the app
  shows a pmset command to paste in a terminal once: the app never asks for privileges
- spend in dollars at API rates, computed locally from transcripts
- statistics: hit STATS on the limits panel and the window expands to the right — tokens per day,
  activity, models, streaks. today / week / month / all time. per-day numbers exclude cache
  (same as claude), the full volume with cache is shown on its own line
- ready alerts: when claude finishes in another window and waits for you, the menu bar scrolls
  the project name past. turn it on in the panel, it installs a hook into claude's settings.
  if you're looking at that same window, the app stays quiet (needs Accessibility access for that)
- the UI is English unless your system is Russian, with an RU/EN switch in the panel

The menu bar always shows limits. Click opens the board, limits are the second screen.
Once you open limits, next time it opens straight to them.

### install

via brew:

    brew trust marblecake88/tap
    brew install --cask marblecake88/tap/claude-limits-gachi-soundboard

trust is a one-time thing, recent homebrew won't load casks from third-party taps otherwise.

or by hand: grab LimitNotifier.zip from [releases](https://github.com/marblecake88/claude-limits-gachi-soundboard/releases), unzip, drag to /Applications.

needs macos 14 and Claude Code installed and logged in, the numbers come from it.
when a new version ships, the app says so in the corner of the panel.

### install from scratch on a clean mac

no brew, no claude code, one paste:

    # homebrew
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    # claude code, the numbers come from it
    brew install --cask claude-code

    # sign in, opens a browser
    claude

    # the app itself
    brew trust marblecake88/tap
    brew install --cask marblecake88/tap/claude-limits-gachi-soundboard
    open /Applications/LimitNotifier.app

homebrew prints a couple of PATH commands at the end, run them, otherwise brew
won't be found in a new terminal tab.

### update without brew

no brew, no problem, one paste in the terminal:

    pkill -f LimitNotifier.app
    cd ~/Downloads
    curl -L -o LimitNotifier.zip https://github.com/marblecake88/claude-limits-gachi-soundboard/releases/latest/download/LimitNotifier.zip
    unzip -oq LimitNotifier.zip
    rm -rf /Applications/LimitNotifier.app
    mv LimitNotifier.app /Applications/
    open /Applications/LimitNotifier.app

settings live elsewhere and survive the reinstall. the link always points at the newest release.

### build

    ./make-app.sh release install

only xcode command line tools, no dependencies.

### license

code is MIT, sounds belong to their authors.
