#!/usr/bin/env bash
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Usage: collect-artifacts.sh DEST_DIR FIND_PATH_PATTERN [FIND_PATH_PATTERN...]
#
# CircleCI's `store_artifacts` takes a single literal path and does not expand
# globs, whereas actions/upload-artifact accepts glob patterns such as
#   **/build/**/*.html
# This script stages every file matching one or more `find -path` patterns into
# DEST_DIR, preserving the path relative to the current directory, so that a
# single `store_artifacts` can publish the lot.
#
# Matching zero files is not an error: that is the behaviour of
# actions/upload-artifact with `if-no-files-found: ignore`, which is what every
# call site in .github/workflows used.
#
# Deliberately POSIX-portable (no `cp --parents`, no `tar --null`, no GNU-only
# find predicates) so that it behaves identically on a CircleCI Linux executor
# and on a developer's macOS machine.

set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: $0 DEST_DIR FIND_PATH_PATTERN [FIND_PATH_PATTERN...]" >&2
  exit 2
fi

dest=$1
shift

mkdir -p "$dest"

# Build the alternation for find: \( -path P1 -o -path P2 ... \)
find_args=()
for pattern in "$@"; do
  if [ "${#find_args[@]}" -eq 0 ]; then
    find_args+=(-path "$pattern")
  else
    find_args+=(-o -path "$pattern")
  fi
done

# If DEST_DIR happens to live under the search root, prune it so that a second
# invocation does not re-collect what the first one staged.
prune_args=()
case "$dest" in
  /*) ;;
  *) prune_args=(-path "./${dest#./}" -prune -o) ;;
esac

# NB: the results go through a temp file rather than a here-document. A
# here-document always yields one (empty) line when the command substitution is
# empty, which made the zero-match case try to `cp ""`.
listing=$(mktemp)
trap 'rm -f "$listing"' EXIT

find . "${prune_args[@]}" -type f \( "${find_args[@]}" \) -print > "$listing"

count=0
while IFS= read -r file; do
  [ -n "$file" ] || continue
  # Strip the leading "./" that find prints so the staged tree is clean.
  rel=${file#./}
  target="$dest/$rel"
  mkdir -p "$(dirname "$target")"
  cp "$file" "$target"
  count=$((count + 1))
done < "$listing"

if [ "$count" -eq 0 ]; then
  echo "No files matched $* -- nothing to publish (if-no-files-found: ignore)" >&2
else
  echo "Staged $count file(s) into $dest" >&2
fi
