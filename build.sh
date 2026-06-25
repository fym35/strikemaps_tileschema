#!/usr/bin/env bash

# Set defaults
MEMORY="${MEMORY:-$(($(getconf _PHYS_PAGES) * $(getconf PAGE_SIZE) / 1024 / 1024 / 2))M}"

# Fetch args
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--memory)
            MEMORY="$2"
            shift 2
            ;;
        -m=*|--memory=*)
            MEMORY="${1#*=}"
            shift
            ;;
        -d|--max-depth)
            MAX_DEPTH="$2"
            shift 2
            ;;
        -d=*|--max-depth=*)
            MAX_DEPTH="${1#*=}"
            shift
            ;;
        -e|--exclude)
            EXCLUDE="$2"
            shift 2
            ;;
        -e=*|--exclude=*)
            EXCLUDE="${1#*=}"
            shift
            ;;
        -t|--test)
            TEST=1
            shift
            ;;
        -*)
            echo "Unknown option: $1"
            exit 1
            ;;
        *)
            if [[ -z "$PATH_ARG" ]]; then
                PATH_ARG="$1"
            elif [[ -z "$MODE" ]]; then
                MODE="$1"
            else
                echo "Unexpected argument: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate args
if [[ -z "$PATH_ARG" || -z "$MODE" ]]; then
    cat <<EOF

Usage:
  $(basename "$0") <path> <mode> [options]

Modes:
  single       Process path as single region
  recursive    Process all sub-regions under path recursively

Options:
  -m, --memory <size>
      RAM allocation given to Planetiler
      Default: system RAM / 2

  -d, --max-depth <n>
      Maximum recursion depth (only recursive mode)

  -e, --exclude <regions>
      Semicolon-separated list of full region paths to exclude from processing

  -t, --test
      Dry run mode. Prints all regions that would be processed without generating any output.

EOF
    exit 1
fi

case "$MODE" in
    single|recursive)
        ;;
    *)
        echo "Error: invalid mode '$MODE'"
        echo "Valid modes are: single, subreg, recursive"
        exit 1
        ;;
esac

if [[ -n "$MAX_DEPTH" ]]; then
    if ! [[ "$MAX_DEPTH" =~ ^[0-9]+$ ]]; then
        echo "Error: --max-depth must be a non-negative integer"
        exit 1
    fi
fi

if [[ -n "$MAX_DEPTH" && "$MODE" != "recursive" ]]; then
    echo "Warning: --max-depth can only work with recursive, ignoring..."
fi

echo "Processing path '$PATH_ARG' in $MODE mode with $MEMORY memory allocated..."

# Define functions
should_skip() {
  local path="$1"

  [[ -z "$EXCLUDE" ]] && return 1

  IFS=';' read -ra EXCL <<< "$EXCLUDE"
  for ex in "${EXCL[@]}"; do
    [[ "$path" == *"$ex"* ]] && return 0
  done

  return 1
}

single_planet() {
    if [[ "$TEST" == "1" ]]; then
        return 0
    fi

    mkdir -p "./data/osm/planet"
    wget "https://planet.openstreetmap.org/pbf/planet-latest.osm.pbf" -O "./data/osm/planet.osm.pbf"

    while IFS= read -r REG; do
      mkdir -p "./work/poly/europe"
      wget "https://download.geofabrik.de/$REG.poly" -O "./work/poly/$REG.poly"

      mkdir -p "./work/contours/$REG"
      pyhgtmap \
        --polygon="./work/poly/$REG.poly" \
        --step=100 \
        --hgtdir=work/hgt \
        --sources=view1,view3 \
        --simplifyContoursEpsilon=0.001 \
        -j16 \
        --max-nodes-per-tile=0 \
        --output-prefix="./work/contours/$REG/con"

      mv "./work/contours/$REG"/con* "./data/contours/osm/$REG.osm"

      osmium export ./data/contours/osm/$REG.osm \
        -o ./data/contours/geojson/$REG.geojson \
        --overwrite
    done < <(fetch_path "planet")
    fetch_path "planet" | awk '{print "./data/contours/geojson/" $0 ".geojson"}' | xargs osmium merge -o ./data/contours/geojson/planet.geojson

    java -Xmx"$MEMORY" \
      -jar ./bin/planetiler.jar schema.yml \
      --download \
      --osm_file="./data/osm/planet.osm.pbf" \
      --contour_file="./data/contours/geojson/planet.geojson" \
      --output="./out/planet.mbtiles" \
      --no-simplify \
      --simplify-tolerance-at-max-zoom=0 \
      --no-feature-merge \
      --simplify-tolerance=0
}

generate_region() {
  local PATH_ARG="$1"
  local MEMORY="$2"

  PATH_ARG="${PATH_ARG%/}"

  if should_skip "$PATH_ARG"; then
    echo "Skipping excluded region: $PATH_ARG"
    return 0
  fi

  echo "Generating region: $PATH_ARG"

  if [[ "$TEST" == "1" ]]; then
     return 0
  fi

  mkdir -p "./work/poly/${PATH_ARG%/*}"
  wget "https://download.geofabrik.de/$PATH_ARG.poly" -O "./work/poly/$PATH_ARG.poly"

  mkdir -p "./work/contours/${PATH_ARG}"
  pyhgtmap \
    --polygon="./work/poly/$PATH_ARG.poly" \
    --step=100 \
    --hgtdir=work/hgt \
    --sources=view1,view3 \
    --simplifyContoursEpsilon=0.001 \
    -j16 \
    --max-nodes-per-tile=0 \
    --output-prefix="./work/contours/$PATH_ARG/con"

  mkdir -p "./data/contours/osm/${PATH_ARG%/*}"
  # max-nodes-per-tile=0 SHOULD generate only one file
  # still very much wonky though
  mv "./work/contours/$PATH_ARG"/con* "./data/contours/osm/$PATH_ARG.osm"

  mkdir -p "./data/contours/geojson/${PATH_ARG%/*}"
  osmium export ./data/contours/osm/${PATH_ARG}.osm \
    -o ./data/contours/geojson/${PATH_ARG}.geojson \
    --overwrite

  mkdir -p "./out/${PATH_ARG%/*}"

  mkdir -p "./data/osm/${PATH_ARG%/*}"
  wget "$(
    curl -s https://download.geofabrik.de/index-v1-nogeom.json |
    jq -r --arg pid "${PATH_ARG##*/}" --arg parent "$(awk -F/ '{print $(NF-1)}' <<< "$PATH_ARG")" '
      .. | objects
      | select(.id? == $pid and .parent? == $parent)
      | .urls.pbf
     '
  )" -O "./data/osm/${PATH_ARG}.osm.pbf"

  java -Xmx"$MEMORY" \
    -jar ./bin/planetiler.jar schema.yml \
    --download \
    --osm_file="./data/osm/${PATH_ARG}.osm.pbf" \
    --contour_file="./data/contours/geojson/${PATH_ARG}.geojson" \
    --output="./out/${PATH_ARG}.mbtiles" \
    --no-simplify \
    --simplify-tolerance-at-max-zoom=0 \
    --no-feature-merge \
    --simplify-tolerance=0
}

fetch_path() {
    local PATH_ARG="$1"
    curl -s https://download.geofabrik.de/index-v1-nogeom.json | jq -r --arg pid "${PATH_ARG##*/}" '
    .features[]
    | select(
        if ($pid == "" or $pid == "planet") then
            .properties.parent == null
        else
            .properties.parent == $pid
        end
        )
    | .properties.id
    '
}

all_path() {
    local PATH_ARG="$1"
    local DEPTH="${2:-0}"

    if [ "$PATH_ARG" = "planet" ]; then
        PATH_ARG=""
    fi

    SUBS=$(fetch_path "$PATH_ARG")

    if [[ -z "$SUBS" ]]; then
        while IFS= read -r REG; do
            generate_region "$PATH_ARG" "$MEMORY"
        done <<< "$SUBS"
    elif [[ -n "$MAX_DEPTH" &&  "$DEPTH" -ge "$MAX_DEPTH" ]]; then
        generate_region "$PATH_ARG" "$MEMORY"
    else
        while IFS= read -r REG; do
            if [[ -n "$PATH_ARG" ]]; then
                all_path "$PATH_ARG/$REG" "$((DEPTH + 1))"
            else
                all_path "$REG" "$((DEPTH + 1))"
            fi
        done <<< "$SUBS"
    fi
}

# Prepare environment
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

# Generate
if [ "$MODE" == "single" ]; then
    if [ "$PATH_ARG" = "planet" ]; then
        single_planet
        exit 0
    fi
    generate_region "$PATH_ARG" "$MEMORY"
    exit 0
elif [[ "$MODE" == "recursive" ]]; then
    all_path "$PATH_ARG"
fi
