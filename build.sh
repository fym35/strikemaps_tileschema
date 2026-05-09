#!/usr/bin/env bash

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <region_root> <region> <memory>"
    exit 1
fi

#Define functions
generate_region() {
  local REGION="$1"
  local REGION_ROOT="$2"
  local MEMORY="${3:-8g}"

  local POLY_FILE="${REGION}.poly"

  mkdir -p work
  wget -O "work/$POLY_FILE" \
    "https://download.geofabrik.de/${REGION_ROOT}/${REGION}.poly"

  mkdir -p "work/contours/$REGION_ROOT/$REGION"

  pyhgtmap \
    --polygon="work/$POLY_FILE" \
    --step=75 \
    --hgtdir=work/hgt \
    --sources=view1,view3 \
    --simplifyContoursEpsilon=0.001 \
    -j16 \
    --max-nodes-per-tile=0 \
    --output-prefix="work/contours/$REGION_ROOT/$REGION/con"

  rm -f work/contours.osm

  # max-nodes-per-tile=0 SHOULD generate only one file
  mv "work/contours/$REGION_ROOT/$REGION"/con* work/contours.osm

  rm -f data/contours.geojson

  osmium export work/contours.osm \
    -o data/contours.geojson \
    --overwrite

  rm -f work/contours.osm

  mkdir -p "./out/$REGION_ROOT"

  java -Xmx"$MEMORY" \
    -jar ./bin/planetiler.jar schema.yml \
    --download \
    --area="${REGION}" \
    --output="./out/${REGION_ROOT}/${REGION}.mbtiles" \
    --no-simplify \
    --simplify-tolerance-at-max-zoom=0 \
    --no-feature-merge \
    --simplify-tolerance=0
}

generate_root() {
    local REGION_ROOT="$1"
    local REGION="$2"
    if [[ "$REGION" == "each" ]]; then
        while IFS= read -r REGION; do
            generate_region "$REGION" "$REGION_ROOT" "$MEMORY"
        done < "defs/regions/roots/${REGION_ROOT}.txt"
    else
        generate_region "$REGION" "$REGION_ROOT" "$MEMORY"
    fi
}

#Prepare environment
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
    source "$VENV_DIR/bin/activate"
else
    source "$VENV_DIR/bin/activate"
fi

REGION_ROOT="$1"
REGION="$2"
MEMORY="$3"

#Generate
if [ "$REGION_ROOT" == "each" ]; then
    if [ "$REGION" != "each" ]; then
        echo "Cannot generate 'each' root region for non-each region, exiting..."
        exit 1
    fi
    while IFS= read -r REGION_ROOT; do
        generate_root "$REGION_ROOT" "each" "$MEMORY"
    done < "defs/regions/planet.txt"
else
    generate_root "$REGION_ROOT" "$REGION" "$MEMORY"
fi
