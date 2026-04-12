#!/usr/bin/env bash

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <region_root> <region> <memory>"
    exit 1
fi

REGION_ROOT="$1"
REGION="$2"
MEMORY="$3"

if [ ! -f ./bin/planetiler.jar ]; then
    mkdir -p ./bin
    wget -O ./bin/planetiler.jar https://github.com/onthegomap/planetiler/releases/latest/download/planetiler.jar
fi

VENV_DIR="./venv"
if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
    . "$VENV_DIR/bin/activate"
    pip install --upgrade pip
    pip install pyhgtmap
else
    source "$VENV_DIR/bin/activate"
fi

POLY_FILE="${REGION}.poly"
mkdir -p work
wget -O "work/$POLY_FILE" "https://download.geofabrik.de/${REGION_ROOT}${REGION}.poly"

rm -f data/contours.osm
pyhgtmap --polygon="work/$POLY_FILE" --step=10 --hgtdir=work/hgt --sources=view1,view3 --simplifyContoursEpsilon=0.00001 -j16 --max-nodes-per-tile=0 --output-prefix data/contours

osmium export data/contours.osm -o data/contours.geojson --overwrite
rm -f data/contours.osm

mkdir -p ./out
java -Xmx"$MEMORY" -jar ./bin/planetiler.jar schema.yml \
    --download \
    --area=${REGION} \
    --output="./out/${REGION}.mbtiles" \
    --no-simplify \
    --simplify-tolerance-at-max-zoom=0 \
    --no-feature-merge \
    --simplify-tolerance=0
