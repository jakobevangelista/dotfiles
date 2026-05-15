#!/bin/bash

read -p "Project name (e.g. austin_vlog): " NAME
DATE=$(date +%Y-%m-%d)
DIR="${DATE}_${NAME}"

mkdir -p "$DIR/footage"
mkdir -p "$DIR/exports"
mkdir -p "$DIR/project-files"
mkdir -p "$DIR/thumbnails"

echo "Project scaffolded at: $(pwd)/$DIR"
echo "Next: ingestFootage /Volumes/Untitled \"$(pwd)/$DIR\""
