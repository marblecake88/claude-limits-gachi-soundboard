#!/usr/bin/env python3
"""Собирает расход токенов Claude Code с удалённых машин по ssh.

Скрипт отправляет сам себя на сервер через stdin, поэтому ставить туда нечего.
На сервере он читает ~/.claude/projects/**/*.jsonl и печатает сводку по дням.

    python3 tools/remote-usage.py                  собрать с хостов по умолчанию
    python3 tools/remote-usage.py taras            только с одного
    python3 tools/remote-usage.py --self-test      проверка разбора

Результат: ~/.claude/remote-usage/<host>.json, лог рядом в collect.log.
"""
import argparse
import json
import os
import pathlib
import subprocess
import sys
import time

OUT_DIR = pathlib.Path.home() / ".claude" / "remote-usage"
# Список хостов, по одному в строке. Нет файла - сбора нет: так фича работает
# только у того, кто сам её завёл, и молчит у всех остальных.
HOSTS_FILE = OUT_DIR / "hosts"
LOG = OUT_DIR / "collect.log"
LOG_MAX = 1_000_000  # ponytail: обрезаем по размеру, logrotate тут лишний
DAYS = 45
# tgs держит RemoteCommand в ssh config, без этого команда не выполнится
SSH = ["ssh", "-o", "ConnectTimeout=10", "-o", "BatchMode=yes",
       "-o", "RemoteCommand=none", "-o", "RequestTTY=no"]


# ---------- то, что выполняется на сервере ----------

def probe(days, tz_name, today=None):
    """Читает транскрипты и печатает json со сводкой. Работает на удалённой машине."""
    root = pathlib.Path.home() / ".claude" / "projects"
    cutoff = time.time() - days * 86400
    seen, out, hours, files, lines = set(), {}, {}, 0, 0

    for f in root.rglob("*.jsonl"):
        try:
            if f.stat().st_mtime < cutoff:
                continue
        except OSError:
            continue
        files += 1
        try:
            with f.open(errors="replace") as fh:
                for line in fh:
                    lines += 1
                    rec = parse_line(line, seen, tz_name)
                    if rec:
                        add(out, *rec[:3])
                        # Часы нужны только за сегодня: на этом периоде график
                        # дома строится по часам, а не по дням.
                        if rec[0] == today:
                            add_hour(hours, rec[3], rec[1], rec[2])
        except OSError:
            continue

    return {
        "host": os.uname().nodename,
        "collected_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "tz": tz_name,
        "days_scanned": days,
        "files_read": files,
        "lines_read": lines,
        "days": out,
        "hours": hours,
    }


def parse_line(line, seen, tz_name):
    """Одна строка транскрипта -> (дата, модель, usage, час) либо None."""
    try:
        o = json.loads(line)
    except ValueError:
        return None
    msg = o.get("message") or {}
    usage = msg.get("usage")
    if not isinstance(usage, dict):
        return None
    # один ответ попадает в несколько jsonl при resume и форках сессии
    key = o.get("requestId") or msg.get("id")
    if key:
        if key in seen:
            return None
        seen.add(key)
    stamp = to_local(o.get("timestamp"), tz_name)
    if not stamp:
        return None
    return stamp.date().isoformat(), msg.get("model") or "unknown", usage, "%02d" % stamp.hour


def to_local(ts, tz_name):
    """ISO-время в UTC -> время в нужной зоне, чтобы сходилось с домашним экраном."""
    if not isinstance(ts, str):
        return None
    from datetime import datetime, timezone
    try:
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    try:
        from zoneinfo import ZoneInfo
        return dt.astimezone(ZoneInfo(tz_name))
    except Exception:
        return dt.astimezone(timezone.utc)  # ponytail: без tzdata считаем по UTC


def add(out, day, model, usage):
    d = out.setdefault(day, {"requests": 0, "models": {}})
    m = d["models"].setdefault(model, {"input": 0, "output": 0,
                                       "cache_creation": 0, "cache_read": 0, "requests": 0})
    m["input"] += usage.get("input_tokens") or 0
    m["output"] += usage.get("output_tokens") or 0
    m["cache_creation"] += usage.get("cache_creation_input_tokens") or 0
    m["cache_read"] += usage.get("cache_read_input_tokens") or 0
    m["requests"] += 1
    d["requests"] += 1


def add_hour(hours, hour, model, usage):
    """Час сегодняшнего дня: только input+output, как на графике дома."""
    tokens = (usage.get("input_tokens") or 0) + (usage.get("output_tokens") or 0)
    if tokens:
        hours.setdefault(hour, {})[model] = hours.setdefault(hour, {}).get(model, 0) + tokens


# ---------- то, что выполняется дома ----------

def log(msg):
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    if LOG.exists() and LOG.stat().st_size > LOG_MAX:
        LOG.write_text(LOG.read_text(errors="replace")[-LOG_MAX // 2:])
    with LOG.open("a") as fh:
        fh.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")
    print(msg)


def collect(host, days, tz_name, timeout):
    src = pathlib.Path(__file__).read_text()
    # today считаем дома: сутки должны совпадать с теми, что видит человек
    cmd = SSH + [host, "python3", "-", "--probe", "--days", str(days), "--tz", tz_name,
                 "--today", time.strftime("%Y-%m-%d")]
    started = time.time()
    try:
        r = subprocess.run(cmd, input=src, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        log(f"{host}: таймаут {timeout}с")
        return None
    if r.returncode != 0:
        log(f"{host}: ssh код {r.returncode}: {r.stderr.strip()[:300]}")
        return None
    try:
        data = json.loads(r.stdout)
    except ValueError:
        log(f"{host}: не разобрал ответ: {r.stdout[:300]}")
        return None

    data["ssh_host"] = host
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    tmp = OUT_DIR / f"{host}.json.tmp"
    tmp.write_text(json.dumps(data, indent=2))
    os.replace(tmp, OUT_DIR / f"{host}.json")

    today = data["days"].get(time.strftime("%Y-%m-%d"), {})
    models = today.get("models", {}).values()
    # как на вкладке Stats у claude: в дневную цифру идут только input+output
    shown = sum(v["input"] + v["output"] for v in models)
    with_cache = shown + sum(v["cache_creation"] + v["cache_read"] for v in models)
    log(f"{host}: {data['files_read']} файлов, {data['lines_read']} строк, "
        f"за сегодня {shown} токенов ({with_cache} с кэшем) / "
        f"{today.get('requests', 0)} запросов, {time.time() - started:.1f}с")
    return data


def read_hosts():
    """Хосты из конфига. Пусто, если файла нет или там одни комментарии."""
    if not HOSTS_FILE.exists():
        return []
    out = []
    for line in HOSTS_FILE.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            out.append(line)
    return out


def local_tz():
    try:
        return pathlib.Path("/etc/localtime").resolve().as_posix().split("zoneinfo/")[1]
    except (OSError, IndexError):
        return "UTC"


def self_test():
    seen = {}
    line = json.dumps({"timestamp": "2026-08-01T09:00:00.000Z", "requestId": "r1",
                       "message": {"model": "claude-opus-5",
                                   "usage": {"input_tokens": 10, "output_tokens": 5,
                                             "cache_creation_input_tokens": 2,
                                             "cache_read_input_tokens": 3}}})
    s = set()
    assert parse_line(line, s, "UTC")[0] == "2026-08-01"
    assert parse_line(line, s, "UTC") is None, "дубль по requestId должен отсеяться"
    assert parse_line("не json", s, "UTC") is None
    assert parse_line(json.dumps({"message": {}}), s, "UTC") is None, "без usage пропускаем"
    # запись в 23:30 UTC уезжает на следующий день в Риге (+3)
    late = json.dumps({"timestamp": "2026-07-31T23:30:00.000Z", "requestId": "r2",
                       "message": {"model": "m", "usage": {"output_tokens": 1}}})
    day = parse_line(late, set(), "Europe/Riga")[0]
    assert day in ("2026-08-01", "2026-07-31"), day  # без tzdata останется UTC
    out = {}
    add(out, "2026-08-01", "m", {"input_tokens": 10, "output_tokens": 5})
    add(out, "2026-08-01", "m", {"output_tokens": 5})
    assert out["2026-08-01"]["models"]["m"] == {"input": 10, "output": 10, "cache_creation": 0,
                                               "cache_read": 0, "requests": 2}
    assert out["2026-08-01"]["requests"] == 2
    hours = {}
    add_hour(hours, "09", "m", {"input_tokens": 10, "output_tokens": 5})
    add_hour(hours, "09", "m", {"input_tokens": 1, "output_tokens": 0})
    add_hour(hours, "10", "m", {"cache_read_input_tokens": 999})
    assert hours == {"09": {"m": 16}}, hours  # кэш в часы не идёт, пустой час не заводим
    import tempfile
    global HOSTS_FILE
    saved = HOSTS_FILE
    try:
        HOSTS_FILE = pathlib.Path(tempfile.mkdtemp()) / "hosts"
        assert read_hosts() == [], "нет файла - нет хостов"
        HOSTS_FILE.write_text("# коммент\ntaras\n\n  tgs  # тоже коммент\n")
        assert read_hosts() == ["taras", "tgs"], read_hosts()
    finally:
        HOSTS_FILE = saved
    print("ok")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("hosts", nargs="*", default=None)
    # отбирает файлы по mtime, а не записи: в свежем файле может лежать и старая
    # история, поэтому дней на выходе бывает больше запрошенного
    ap.add_argument("--days", type=int, default=DAYS)
    ap.add_argument("--tz", default=None)
    ap.add_argument("--timeout", type=int, default=180)
    ap.add_argument("--today", default=None, help="дата дома, для почасовой разбивки")
    ap.add_argument("--probe", action="store_true", help="служебный режим, запускается на сервере")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()

    if a.self_test:
        return self_test()
    if a.probe:
        json.dump(probe(a.days, a.tz or "UTC", a.today), sys.stdout)
        return
    hosts = a.hosts or read_hosts()
    if not hosts:
        return  # молча: у тех, кто не заводил конфиг, собирать нечего
    tz = a.tz or local_tz()
    for host in hosts:
        collect(host, a.days, tz, a.timeout)


if __name__ == "__main__":
    main()
