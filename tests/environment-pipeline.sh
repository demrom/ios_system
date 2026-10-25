#!/bin/sh
# Run in a-Shell with Dash and tmux, with MallocScribble set on the host process.
set -eu
directory=$1
mkdir -p "$directory"
tmux -V > "$directory/VERSION"
i=0
while test "$i" -lt 20; do
	cat "$directory/VERSION" | tmux -V > "$directory/output"
	i=$((i + 1))
done
echo MINIMAL_PIPELINE_PASS
