"""Статистика использования Antigravity по локальной истории разговоров.

Читает базы ~/.gemini/antigravity/conversations/*.db (только чтение) и печатает JSON
с агрегатами по дням и моделям. Тексты разговоров не читаются — только метаданные генераций.

    python -I stats.py <папка .gemini/antigravity>
"""
import glob
import json
import os
import shutil
import sqlite3
import sys
import tempfile
from collections import defaultdict
from datetime import datetime

ACTIVE_GAP = 10 * 60  # паузы длиннее 10 минут не считаются активностью


def varint(b, i):
    r = s = 0
    while True:
        c = b[i]
        i += 1
        r |= (c & 0x7F) << s
        s += 7
        if c < 0x80:
            return r, i


def fields(b):
    """Разбор protobuf без схемы: список (номер поля, тип, значение)."""
    i, out = 0, []
    n = len(b or b"")
    while i < n:
        key, i = varint(b, i)
        f, t = key >> 3, key & 7
        if t == 0:
            v, i = varint(b, i)
        elif t == 1:
            v, i = b[i:i + 8], i + 8
        elif t == 5:
            v, i = b[i:i + 4], i + 4
        elif t == 2:
            ln, i = varint(b, i)
            v, i = b[i:i + ln], i + ln
        else:
            raise ValueError("wire type %d" % t)
        out.append((f, t, v))
    return out


def first(fs, num, default=None):
    for f, _, v in fs:
        if f == num:
            return v
    return default


def duration(b):
    if not b:
        return 0.0
    fs = fields(b)
    return first(fs, 1, 0) + first(fs, 2, 0) / 1e9


def packed(fs, num):
    vals = []
    for f, t, v in fs:
        if f != num:
            continue
        if t == 0:
            vals.append(v)
        elif t == 2:
            i = 0
            while i < len(v):
                x, i = varint(v, i)
                vals.append(x)
    return vals


def open_db(path):
    try:
        con = sqlite3.connect("file:" + path + "?mode=ro", uri=True, timeout=2)
        con.execute("select count(*) from sqlite_master").fetchone()
        return con, None
    except sqlite3.Error:
        # база занята запущенным Antigravity — читаем копию
        tmp = tempfile.mkdtemp(prefix="agy-stats-")
        for suffix in ("", "-wal", "-shm"):
            if os.path.exists(path + suffix):
                shutil.copy2(path + suffix, os.path.join(tmp, "c.db" + suffix))
        return sqlite3.connect(os.path.join(tmp, "c.db")), tmp


def main():
    base = sys.argv[1]
    rows = defaultdict(lambda: {"n": 0, "in": 0, "out": 0, "think": 0, "cache": 0, "cw": 0,
                                "gen": 0.0, "ttft": 0.0, "cr": 0, "name": ""})
    stamps_by_conv = {}
    conversations = errors = 0

    for path in glob.glob(os.path.join(base, "conversations", "*.db")):
        tmp = None
        try:
            con, tmp = open_db(path)
            steps = {}
            for idx, meta in con.execute("select idx, metadata from steps"):
                try:
                    created = first(fields(meta), 1)
                    if created:
                        steps[idx] = first(fields(created), 1, 0)
                except Exception:
                    pass
            if not steps:
                con.close()
                continue
            conversations += 1
            fallback = max(steps.values())
            stamps_by_conv[path] = sorted(steps.values())

            for (data,) in con.execute("select data from gen_metadata"):
                try:
                    gm = fields(data)
                    chat = first(gm, 1)
                    if not chat:
                        continue
                    cm = fields(chat)
                    usage = fields(first(cm, 4, b""))
                    custom = {}
                    for f, _, v in cm:
                        if f == 20:
                            kv = fields(v)
                            custom[first(kv, 1, b"").decode("utf-8", "replace")] = first(kv, 2, b"").decode("utf-8", "replace")
                    model = custom.get("model_enum") or "MODEL_%s" % first(cm, 3, 0)
                    name = (first(cm, 21) or first(cm, 19) or b"").decode("utf-8", "replace")
                    idxs = [steps[i] for i in packed(gm, 2) if i in steps]
                    ts = min(idxs) if idxs else fallback
                    day = datetime.fromtimestamp(ts).strftime("%Y-%m-%d")
                    r = rows[(day, model)]
                    r["n"] += 1
                    r["in"] += first(usage, 2, 0)
                    r["out"] += first(usage, 3, 0)
                    r["think"] += first(usage, 9, 0)
                    r["cache"] += first(usage, 5, 0)
                    r["cw"] += first(usage, 4, 0)
                    r["ttft"] += duration(first(cm, 11))
                    r["gen"] += duration(first(cm, 11)) + duration(first(cm, 12))
                    r["cr"] += first(cm, 13, 0)
                    if name and not r["name"]:
                        r["name"] = name
                except Exception:
                    errors += 1
            con.close()
        except Exception:
            errors += 1
        finally:
            if tmp:
                shutil.rmtree(tmp, ignore_errors=True)

    # активность: шаги всех разговоров на одной шкале, паузы больше ACTIVE_GAP не считаем
    activity = defaultdict(lambda: {"sec": 0.0, "conv": set(), "steps": 0})
    events = sorted((t, c) for c, ts in stamps_by_conv.items() for t in ts)
    prev = None
    for t, c in events:
        day = datetime.fromtimestamp(t).strftime("%Y-%m-%d")
        a = activity[day]
        a["steps"] += 1
        a["conv"].add(c)
        if prev is not None and 0 <= t - prev <= ACTIVE_GAP:
            a["sec"] += t - prev
        prev = t

    out = {
        "conversations": conversations,
        "errors": errors,
        "first": events[0][0] if events else None,
        "last": events[-1][0] if events else None,
        "rows": [dict(d=d, m=m, **{k: (round(v, 2) if isinstance(v, float) else v) for k, v in r.items()})
                 for (d, m), r in sorted(rows.items())],
        "activity": [{"d": d, "min": round(a["sec"] / 60, 1), "conv": len(a["conv"]), "steps": a["steps"]}
                     for d, a in sorted(activity.items())],
        # дни, в которые шёл каждый разговор: чтобы считать разговоры за период без повторов
        "convs": [sorted({datetime.fromtimestamp(t).strftime("%Y-%m-%d") for t in ts})
                  for ts in stamps_by_conv.values()],
    }
    json.dump(out, sys.stdout, ensure_ascii=True)


if __name__ == "__main__":
    main()
