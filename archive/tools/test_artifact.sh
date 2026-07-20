#!/usr/bin/env bash
set -euo pipefail

# test_artifact.sh <artifact_id> <filename> <command> [args...]
# Materializes an artifact only in a disposable directory and removes it on
# normal exit or termination signals. It never writes to the project workspace.

export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-kasey}"
export PGDATABASE="${PGDATABASE:-task_train}"

ARTIFACT_ID="${1:?usage: test_artifact.sh <artifact_id> <filename> <command> [args...]}"
FILENAME="${2:?usage: test_artifact.sh <artifact_id> <filename> <command> [args...]}"
shift 2
(( $# > 0 )) || { printf 'A test command is required.\n' >&2; exit 2; }
[[ "$ARTIFACT_ID" =~ ^[0-9]+$ ]] || { printf 'Artifact ID must be numeric.\n' >&2; exit 2; }
[[ "$FILENAME" != */* && "$FILENAME" != '.' && "$FILENAME" != '..' ]] || { printf 'Filename must not contain a path.\n' >&2; exit 2; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/task-train-artifact.XXXXXX")"
cleanup() { rm -rf -- "$WORKDIR"; }
trap cleanup EXIT HUP INT TERM

psql --no-psqlrc -v ON_ERROR_STOP=1 -c \
  "COPY (SELECT body FROM tagg.artifact WHERE id = $ARTIFACT_ID) TO STDOUT" \
  > "$WORKDIR/$FILENAME"
test -s "$WORKDIR/$FILENAME" || { printf 'Artifact %s has no body.\n' "$ARTIFACT_ID" >&2; exit 1; }

set +e
(cd "$WORKDIR" && "$@")
EXIT_CODE=$?
set -e
printf 'artifact_id=%s exit_code=%s\n' "$ARTIFACT_ID" "$EXIT_CODE"
exit "$EXIT_CODE"
