#!/bin/bash
# ipfs-node/ingest.sh
#
# Stage content into the local IPFS repo and record what it hashed to.
#
#   ./ingest.sh            add + pin everything in content/, update manifest
#   ./ingest.sh --verify   re-hash every staged file against the manifest
#   ./ingest.sh --list     print the manifest
#
# NOTHING HERE TOUCHES THE NETWORK. `ipfs add` chunks and hashes locally and
# writes to the local blockstore. Announcing only happens when a daemon runs,
# which this never starts.
#
# WHY A MANIFEST
# --------------
# A CID is a claim about bytes. Keeping filename -> CID next to the files means
# you can prove later that a given file is still the one that produced a given
# address - and detect silently if it is not. That is the whole property the
# Pinata takedown demonstrated: losing a pin costs availability, and the bytes
# plus the CID are what makes it recoverable.
#
# --verify exists because a staged file can change without anyone noticing:
# an editor rewrite, a sync client, a partial copy. If the recomputed CID no
# longer matches the manifest, the file is not the file any more, and that is
# worth knowing before it is served as though it were.
#
# PARAMETERS ARE NOT GUESSED
# --------------------------
# CIDv0, dag-pb leaves (rawLeaves false) - measured against a real Loopring
# pinned file rather than assumed. --raw-leaves would produce a different and
# wrong address for the same bytes.

set -uo pipefail
cd "$(dirname "$0")" || exit 1

export IPFS_PATH="$(pwd)/repo"
K="$(pwd)/kubo/ipfs"
CONTENT="$(pwd)/content"

# The manifest lives WITH the content, in the public ipfs-content repo, not here.
# That is deliberate: it lets anyone who clones the content verify every CID
# themselves with `ipfs add --only-hash`, without this node and without trusting
# whoever staged it. Keeping it in the private repo would make the content
# unverifiable except on the owner's word.
MANIFEST="$CONTENT/manifest.tsv"

# Files that belong to the content REPO rather than being content. Ingesting
# these would publish CIDs for a README and a git config as though they were
# NFT payloads.
SKIP=(manifest.tsv README.md .gitignore .gitkeep)

[ -x "$K" ] || { echo "kubo not found at $K"; exit 1; }
[ -d "$CONTENT" ] || { echo "content/ missing - expected symlink to ../ipfs-content"; exit 1; }

add_opts=(--cid-version=0 --pin=true -Q)

case "${1:-}" in

  --list)
    [ -f "$MANIFEST" ] && column -t -s $'\t' "$MANIFEST" || echo "no manifest yet"
    exit 0
    ;;

  --verify)
    [ -f "$MANIFEST" ] || { echo "no manifest to verify against"; exit 1; }
    fail=0; n=0
    while IFS=$'\t' read -r cid name bytes added; do
      [ "$cid" = "cid" ] && continue
      f="$CONTENT/$name"
      n=$((n+1))
      if [ ! -f "$f" ]; then
        printf "  MISSING   %-40s %s\n" "$name" "$cid"; fail=$((fail+1)); continue
      fi
      now=$("$K" add --only-hash "${add_opts[@]}" "$f" 2>/dev/null)
      if [ "$now" = "$cid" ]; then
        printf "  ok        %-40s %s\n" "$name" "$cid"
      else
        printf "  CHANGED   %-40s\n            manifest: %s\n            actual:   %s\n" "$name" "$cid" "$now"
        fail=$((fail+1))
      fi
    done < "$MANIFEST"
    echo
    echo "  $((n-fail))/$n verified"
    exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
    ;;

esac

# ---- ingest
shopt -s nullglob
files=("$CONTENT"/*)
[ ${#files[@]} -gt 0 ] || { echo "nothing in $CONTENT"; exit 0; }

[ -f "$MANIFEST" ] || printf "cid\tname\tbytes\tadded\n" > "$MANIFEST"

for f in "${files[@]}"; do
  [ -f "$f" ] || continue
  name=$(basename "$f")

  skip=0
  for s in "${SKIP[@]}"; do [ "$name" = "$s" ] && skip=1; done
  [ "$skip" -eq 1 ] && continue
  cid=$("$K" add "${add_opts[@]}" "$f" 2>/dev/null)
  [ -n "$cid" ] || { printf "  FAILED    %s\n" "$name"; continue; }
  bytes=$(stat -c%s "$f")

  prev=$(awk -F'\t' -v n="$name" '$2==n {print $1}' "$MANIFEST" | head -1)
  if [ -n "$prev" ] && [ "$prev" != "$cid" ]; then
    printf "  CHANGED   %-40s\n            was: %s\n            now: %s\n" "$name" "$prev" "$cid"
    grep -v -P "^[^\t]*\t\Q$name\E\t" "$MANIFEST" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
  elif [ -n "$prev" ]; then
    printf "  unchanged %-40s %s\n" "$name" "$cid"
    continue
  else
    printf "  added     %-40s %s\n" "$name" "$cid"
  fi

  printf "%s\t%s\t%s\t%s\n" "$cid" "$name" "$bytes" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$MANIFEST"
done

echo
"$K" repo stat 2>/dev/null | sed 's/^/  /'
echo
echo "  manifest: $MANIFEST"
echo "  nothing has been announced - a daemon must be running for that."
