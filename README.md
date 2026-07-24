# claude limits gachi soundboard

[![release](https://img.shields.io/badge/release-v1.2.1-ff598c)](https://github.com/marblecake88/claude-limits-gachi-soundboard/releases)
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
  работаешь с 8, ставишь 9
- трата в долларах по тарифам API, считается локально из транскриптов
- статистика: жмёшь STATS в панели лимитов, окно разъезжается вправо. токены по дням,
  активность, модели, стрики. периоды сегодня/неделя/месяц/всё
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
  and an hour before it closes. you start at 8, set it to 9
- spend in dollars at API rates, computed locally from transcripts
- statistics: hit STATS on the limits panel and the window expands to the right — tokens per day,
  activity, models, streaks. today / week / month / all time
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

### build

    ./make-app.sh release install

only xcode command line tools, no dependencies.

### license

code is MIT, sounds belong to their authors.
