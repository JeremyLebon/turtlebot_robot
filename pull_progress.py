#!/usr/bin/env python3
"""Voortgang van `docker compose --progress json pull` naar de statusregel.

Leest de JSON-regels van stdin en schrijft om de 2 s naar het statusbestand
(state/update_status.txt, getoond op de statuspagina), bv.
    ⬇️ Nieuwe image ophalen: 42 % (230 / 548 MB, 5/12 lagen)
Docker kent de grootte van een laag pas als hij begint te downloaden; het
percentage gaat daarom nooit achteruit (een nieuwe laag verhoogt enkel het
totaal) en is pas exact als alle lagen gestart zijn.

Gebruik (update_turtlebot.sh):
    docker compose --progress json pull 2>&1 | python3 pull_progress.py <statusbestand>
"""
import json
import sys
import time

PREFIX = "⬇️ Nieuwe image ophalen"


def main():
    status_file = sys.argv[1]
    layers = {}          # id -> {"cur": bytes, "tot": bytes, "done": bool}
    last_write, best = 0.0, 0

    def write(force=False):
        nonlocal last_write, best
        now = time.monotonic()
        if not force and now - last_write < 2:
            return
        last_write = now
        todo = [l for l in layers.values() if not l.get("cached")]
        if not todo:
            return
        tot = sum(l["tot"] for l in todo)
        cur = sum(l["tot"] if l["done"] else l["cur"] for l in todo)
        if tot:
            best = max(best, min(99, int(100 * cur / tot)))
        done = sum(1 for l in todo if l["done"])
        line = "%s: %d %% (%d / %d MB, %d/%d lagen)" % (PREFIX, best, cur / 1e6, tot / 1e6, done, len(todo))
        try:
            with open(status_file, "w") as f:
                f.write(line + "\n")
        except OSError:
            pass

    for raw in sys.stdin:
        try:
            ev = json.loads(raw)
        except ValueError:
            print(raw.rstrip())          # geen JSON (fout of oude compose): naar de journal
            continue
        if not ev.get("parent_id"):      # service-niveau: "Pulling", "Pulled", fouten
            print(ev.get("id", ""), ev.get("text", ""), ev.get("status", ""))
            continue
        l = layers.setdefault(ev["id"], {"cur": 0, "tot": 0, "done": False})
        text = ev.get("text", "")
        if text == "Already exists":
            l["cached"] = True
        elif text == "Downloading":
            l["cur"], l["tot"] = ev.get("current", l["cur"]), ev.get("total", l["tot"]) or l["tot"]
        elif text in ("Download complete", "Verifying Checksum", "Extracting", "Pull complete"):
            l["done"] = True
            l["cur"] = l["tot"]
        write()
    write(force=True)


if __name__ == "__main__":
    main()
