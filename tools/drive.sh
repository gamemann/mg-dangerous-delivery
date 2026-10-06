#!/usr/bin/env bash
# A stand-in drives every route (or the ones named) to the depot, as fast as the machine can
# simulate it, and prints how each went. A route a stand-in cannot finish is a route with a
# bend, a gap or a rock nobody can get past; every route here was finished by one on 2026-10-06.
#
#   tools/drive.sh                                # every route, the box truck
#   tools/drive.sh dd_snowline dd_devils_spine    # just these
#   TRUCK=bulk BOTSPEED=7 tools/drive.sh          # the hardest truck, slower
#   CALM=1 ROCKS=0 tools/drive.sh                 # no weather, no rock
set -uo pipefail
cd "$(dirname "$0")/.."
routes=("$@")
[ ${#routes[@]} -gt 0 ] || routes=(dd_foothills dd_river_cut dd_snowline dd_wind_ridge dd_devils_spine)
status=0
for r in "${routes[@]}"; do
    line=$(ROUTE="$r" SECS="${SECS:-600}" timeout 600 "${GODOT:-godot}" --headless --fixed-fps 60 --path . res://tools/drive.tscn 2>&1 | grep -E '^END')
    echo "$r: ${line:-no result}"
    [[ "$line" == *delivered* ]] || status=1
done
exit $status
