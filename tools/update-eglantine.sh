#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# make update: moves the Eglantine submodule to the newest commit of its default branch, lists what
# came in, and checks that the text anchors of the port (tools/prepare-vulkan-port.py) still match.
# It stages the submodule's new commit and nothing else; commit that yourself once `make test`
# passes.
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
# Do not check out the recorded (possibly older) submodule commit before taking out patches.
# That checkout rejects the tracked changes from the last run of apply-eglantine-patches.sh:
# the rollback/stash below would never get a chance to protect them.
# "git submodule init" registers the submodule without moving its working tree.
git submodule init Eglantine
if [[ ! -f Eglantine/.git && ! -d Eglantine/.git ]]; then
    # First checkout only: nothing has been patched in this submodule yet.
    git submodule update --init Eglantine
fi
# The patches (tools/eglantine-patches) come out first, so the submodule moves from a clean tree.
bash tools/apply-eglantine-patches.sh --revert
# When several patches change the same source, reverting them one by one can leave some edits
# behind. Save those edits inside Eglantine's own stash before checking out a newer core.
# Do not discard the user's work with reset --hard or checkout --force.
if [[ -n $(git -C Eglantine status --porcelain --untracked-files=no) ]]; then
    echo "Eglantine still has tracked changes after patch reversal; backing them up in its stash."
    git -C Eglantine stash push -m "Automatic backup of leftover Eglantine changes before nx2 update"
    if [[ -n $(git -C Eglantine status --porcelain --untracked-files=no) ]]; then
        echo "Eglantine is still modified after stashing; checkout aborted to protect changes." >&2
        exit 1
    fi
    echo "Backup saved in Eglantine's stash. Do not pop it onto the updated source."
fi
# Patch-created files are untracked in the Lichii submodule (for example
# bananza_terrain_compat.h in 0021). If a later patch changed an earlier patch,
# --revert cannot always remove them. The tracked-only stash above leaves them
# in place, making "git apply --check" fail with "already exists".
# Back up ONLY existing untracked files created by a patch, never all of the
# user's other untracked source, build or cache files.
shopt -s nullglob
mapfile -t patch_created < <(
    for patch in "$root"/tools/eglantine-patches/*.patch; do
        git -C Eglantine apply --summary "$patch" |
            sed -n 's/^ create mode [0-9][0-9]* //p'
    done | sort -u
)
patch_leftovers=()
for path in "${patch_created[@]}"; do
    if [[ -e "Eglantine/$path" || -L "Eglantine/$path" ]] &&
       [[ -z $(git -C Eglantine ls-files -- "$path") ]] &&
       [[ -n $(git -C Eglantine ls-files --others --exclude-standard -- "$path") ]]; then
        patch_leftovers+=("$path")
    fi
done
if ((${#patch_leftovers[@]})); then
    printf 'Backing up untracked patch-created file: %s\\n' "${patch_leftovers[@]}"
    git -C Eglantine stash push --include-untracked \
        -m "Automatic backup of patch-created files before nx2 update" -- "${patch_leftovers[@]}"
    for path in "${patch_leftovers[@]}"; do
        if [[ -e "Eglantine/$path" || -L "Eglantine/$path" ]]; then
            echo "Cannot safely move $path out of the way; update aborted." >&2
            exit 1
        fi
    done
    echo "Patch-created file backup saved in Eglantine's stash. Do not pop onto the new core."
fi
before=$(git -C Eglantine rev-parse HEAD)
git submodule update --remote Eglantine
after=$(git -C Eglantine rev-parse HEAD)
# Staged, so that make deps (git submodule update --init) keeps this commit instead of going back to
# the one recorded before; committing is left to you.
git add Eglantine
if [[ $before == "$after" ]]; then
    echo "Eglantine is already at the newest commit ($(git -C Eglantine rev-parse --short HEAD))."
else
    echo "Eglantine ${before:0:10} -> ${after:0:10}:"
    git -C Eglantine log --oneline --max-count=40 "$before..$after"
    echo "($(git -C Eglantine rev-list --count "$before..$after") commits, $(git -C Eglantine diff --shortstat "$before" "$after"))"
fi
# Put them back on the new commit: if one no longer applies, say so now.
bash tools/apply-eglantine-patches.sh
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
if ! python3 -I tools/prepare-vulkan-port.py --report Eglantine "$scratch" >/dev/null; then
    echo "The port needs adapting to the new source (above). The new commit is staged;" >&2
    echo "'git restore --staged Eglantine && git submodule update Eglantine' goes back." >&2
    exit 1
fi
echo "The Vulkan port still applies. Next: make test, then commit the submodule."
