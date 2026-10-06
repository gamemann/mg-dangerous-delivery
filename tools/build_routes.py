#!/usr/bin/env python3
"""Writes every route document in routes/ from the descriptions below.

    tools/build_routes.py            # rewrite routes/*.json
    tools/build_routes.py --check    # exit 1 if a file on disk is not what this writes

A route is a list of segments, each a length, a turn (degrees, positive right) and a climb
from where the last one ended; game/dd_route_doc.gd is the format and its validator. The
JSON is what the game reads and is committed. Every number is written as a float, because
JSON has one number type and a document that round-trips through a parser must come back
byte-identical (mg-wipeout's finding).
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "routes")


def seg(length, turn=0, climb=0, wall="left", rail="none", zone="", checkpoint=False, boulders=0, width=None, bank=0, ice=0, debris=0):
    s = {"length": float(length), "turn": float(turn), "climb": float(climb), "wall": wall, "rail": rail}
    if zone:
        s["zone"] = zone
    if checkpoint:
        s["checkpoint"] = True
    if boulders:
        s["boulders"] = int(boulders)
    if ice:
        s["ice"] = int(ice)
    if debris:
        s["debris"] = int(debris)
    if width is not None:
        s["width"] = float(width)
    if bank:
        s["bank"] = float(bank)
    return s


def hairpin(direction, climb, zone="", width=None):
    """A 180-degree bend: 95 m, about a 30 m radius, which a long truck takes at walking pace.

    The cliff is on the INSIDE, always: a switchback turns uphill, and the inside of the bend is
    the mountain. The first version took the side as an argument and put the drop on the inside
    of three of them, where a truck cutting the corner (which every truck does) went over —
    found by a stand-in falling 41 times in one hairpin of Devil's Spine.
    """
    return seg(95, 180 * direction, climb, wall="right" if direction > 0 else "left", zone=zone, width=width)


def route(rid, name, level, pay, blurb, width, zones, segments, cargo="crates"):
    return {
        "format": 1, "kind": "route", "id": rid, "name": name, "author": "mg-dangerous-delivery",
        "blurb": blurb, "level": level, "pay": pay, "width": float(width), "cargo": cargo,
        "zones": zones, "segments": segments,
    }


ROUTES = [
    route("dd_foothills", "Foothills", 1, 300,
          "A gentle climb with rails most of the way. Learn how the truck stops.", 8.5,
          {"valley": {"name": "The Valley", "rain": 0.35, "wind": 0.1}},
          [
              seg(80, wall="none", rail="both"),
              seg(120, 25, 6, wall="left", rail="right", zone="valley"),
              seg(100, -30, 8, wall="left", rail="right", zone="valley", checkpoint=True),
              seg(140, 0, 12, wall="left", rail="none", zone="valley"),
              seg(110, 45, 6, wall="right", rail="left", zone="valley", checkpoint=True),
              seg(120, -20, 10, wall="left", zone="valley", boulders=1, debris=1),
              seg(90, 30, 4, wall="left", checkpoint=True),
              seg(100, 0, 2, wall="none", rail="both"),
          ]),
    route("dd_river_cut", "River Cut", 2, 380,
          "Cut into the cliff over the river. No rails, and it rains here more often than not.", 7.5,
          {"gorge": {"name": "The Gorge", "rain": 0.7, "wind": 0.25}},
          [
              seg(70, wall="left"),
              seg(140, -35, 10, wall="left", zone="gorge"),
              seg(110, 40, 8, wall="left", zone="gorge", boulders=1, checkpoint=True),
              seg(160, -20, 14, wall="left", zone="gorge", width=7.0, debris=1),
              seg(120, 50, 6, wall="left", zone="gorge", boulders=2, checkpoint=True),
              seg(140, -45, 12, wall="left", zone="gorge", width=6.8),
              seg(120, 20, 8, wall="left", zone="gorge", checkpoint=True),
              seg(90, 0, 0, wall="none", rail="both"),
          ]),
    route("dd_snowline", "Snowline Pass", 3, 480,
          "Switchbacks up into the snow. Brake before the bend, not in it.", 7.0,
          {"lower": {"name": "Lower Pass", "rain": 0.4}, "upper": {"name": "Snowline", "snow": 0.8, "wind": 0.3}},
          [
              seg(80, wall="left"),
              seg(130, 0, 14, wall="left", zone="lower"),
              hairpin(-1, 6, zone="lower"),
              seg(140, 0, 16, wall="right", zone="lower", boulders=1, checkpoint=True),
              hairpin(1, 6, zone="upper"),
              seg(140, 0, 16, wall="left", zone="upper", boulders=1, ice=2),
              hairpin(-1, 6, zone="upper", width=6.8),
              seg(120, 10, 12, wall="right", zone="upper", checkpoint=True),
              seg(150, -30, 6, wall="right", zone="upper", boulders=1, ice=1, debris=1),
              seg(100, 20, 0, wall="none", zone="upper", checkpoint=True),
              seg(90, 0, -4, wall="none", rail="both"),
          ]),
    route("dd_wind_ridge", "Wind Ridge", 4, 560,
          "Along the top of a ridge with a drop on both sides, in a wind that comes in gusts.", 6.8,
          {"ridge": {"name": "The Ridge", "wind": 0.9, "rain": 0.3}, "saddle": {"name": "The Saddle", "wind": 0.6, "snow": 0.3}},
          [
              seg(80, wall="left"),
              seg(140, 15, 14, wall="left", zone="saddle"),
              seg(160, -20, 8, wall="none", zone="ridge", width=6.5, checkpoint=True),
              seg(140, 30, 4, wall="none", zone="ridge", width=6.2),
              seg(120, -35, -6, wall="none", zone="ridge", width=6.2, checkpoint=True),
              seg(150, 25, 10, wall="right", zone="saddle", boulders=2, ice=1),
              seg(130, -20, 6, wall="none", zone="ridge", width=6.0, checkpoint=True),
              seg(90, 0, 0, wall="none", rail="both"),
          ]),
    route("dd_devils_spine", "Devil's Spine", 5, 700,
          "Everything at once, and narrow. The pay is for the people who get there.", 6.5,
          {"gate": {"name": "The Gate", "rain": 0.5, "wind": 0.4},
           "spine": {"name": "The Spine", "snow": 0.7, "wind": 0.7},
           "summit": {"name": "Summit", "snow": 0.9, "wind": 0.5}},
          [
              seg(70, wall="left"),
              seg(140, -25, 16, wall="left", zone="gate", boulders=2),
              hairpin(1, 8, zone="gate"),
              seg(130, 0, 18, wall="left", zone="gate", boulders=1, checkpoint=True),
              hairpin(-1, 8, zone="spine", width=6.2),
              seg(150, 20, 16, wall="none", zone="spine", width=6.0, ice=2),
              seg(120, -40, 8, wall="left", zone="spine", boulders=2, checkpoint=True),
              hairpin(1, 6, zone="summit", width=6.2),
              seg(140, -15, 14, wall="none", zone="summit", width=5.8, boulders=1),
              seg(110, 35, 6, wall="right", zone="summit", checkpoint=True, debris=1, ice=1),
              seg(130, -10, 4, wall="none", zone="summit", width=5.8),
              seg(90, 0, 0, wall="none", rail="both"),
          ]),
]


def text_of(doc):
    return json.dumps(doc, indent="\t", sort_keys=False) + "\n"


def main():
    check = "--check" in sys.argv
    os.makedirs(OUT, exist_ok=True)
    stale = []

    for doc in ROUTES:
        path = os.path.join(OUT, doc["id"] + ".json")
        text = text_of(doc)

        if check:
            if not os.path.exists(path) or open(path).read() != text:
                stale.append(doc["id"])
            continue

        with open(path, "w") as f:
            f.write(text)

    if check and stale:
        print("not what tools/build_routes.py writes:", ", ".join(stale))
        return 1

    if not check:
        print("wrote %d routes" % len(ROUTES))

    return 0


if __name__ == "__main__":
    sys.exit(main())
