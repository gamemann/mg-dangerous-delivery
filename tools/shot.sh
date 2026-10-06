#!/usr/bin/env bash
# Render the game and look at it. The check no assertion in this repository makes.
#
#   tools/shot.sh                                         # the garage
#   tools/shot.sh --view=drive --route=dd_snowline --seconds=40   # a stand-in at the wheel, chase camera
#   tools/shot.sh --view=cab --route=dd_river_cut --seconds=20    # from the cab
#   tools/shot.sh --view=above --route=dd_devils_spine     # the whole route from above
#   tools/shot.sh --view=drive --sky=snow                  # force the weather everywhere
#   tools/shot.sh --view=drive --route=dd_snowline --at=880 --seconds=4   # put the truck 880 m along first
#
# xvfb-run because this needs a rendering context; --headless gives a null renderer and saves
# a frame of nothing. --fixed-fps so a stand-in forty seconds up a route is forty simulated
# seconds, not forty seconds of waiting.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p screenshots

view="garage"; seconds="6"; out=""; route="dd_foothills"; sky=""; at="0"; truck=""
for arg in "$@"; do
    case "$arg" in
        --view=*)    view="${arg#*=}" ;;
        --seconds=*) seconds="${arg#*=}" ;;
        --out=*)     out="${arg#*=}" ;;
        --route=*)   route="${arg#*=}" ;;
        --sky=*)     sky="${arg#*=}" ;;
        --at=*)      at="${arg#*=}" ;;
        --truck=*)   truck="${arg#*=}" ;;
        *)           echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done
[ -n "$out" ] || out="res://screenshots/${view}.png"

exec xvfb-run -a "${GODOT:-godot}" --fixed-fps 60 --path . --resolution 1280x720 \
    res://tools/shot.tscn -- "--seconds=$seconds" "--view=$view" "--out=$out" "--route=$route" "--sky=$sky" "--at=$at" "--truck=$truck"
