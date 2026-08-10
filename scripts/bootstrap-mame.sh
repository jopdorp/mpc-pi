#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mame_source_dir=${MAME_SOURCE_DIR:-"$repo_root/.cache/mame"}
mame_ref=${MAME_REF:-f8c55f4cdad70fa5b7dfae9a26a15114aea70f9a}
mame_remote=https://github.com/mamedev/mame.git

if [[ -e "$mame_source_dir" && ! -d "$mame_source_dir/.git" ]]; then
    printf 'error: %s exists but is not a Git checkout\n' "$mame_source_dir" >&2
    exit 1
fi

if [[ ! -d "$mame_source_dir/.git" ]]; then
    mkdir -p -- "$(dirname -- "$mame_source_dir")"
    git clone --filter=blob:none --no-checkout "$mame_remote" "$mame_source_dir"
fi

if [[ -n "$(git -C "$mame_source_dir" status --porcelain)" ]]; then
    printf 'error: refusing to change a dirty MAME checkout at %s\n' "$mame_source_dir" >&2
    exit 1
fi

git -C "$mame_source_dir" fetch --depth=1 origin "$mame_ref"
git -C "$mame_source_dir" checkout --detach FETCH_HEAD
git -C "$mame_source_dir" log -1 --format='MAME source: %H (%cs) %s'
