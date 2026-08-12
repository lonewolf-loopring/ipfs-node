# ipfs-node

A local IPFS node for serving Loopring NFT content, and the staging pipeline that
puts files into it.

This exists because of what the Pinata takedown demonstrated: a CID is a permanent
address, but availability is not permanent. The bytes stopped being served and the
address kept resolving to nothing. Whoever holds the bytes can restore that address
at any time, and nobody else can - not the gateway, not Loopring, not an index.
Running the node is what turns "the creator still has the file" into "the file is
reachable again."

## Two repos

This one is **private** and holds only the machinery. The content it serves is a
separate **public** repo, `ipfs-content`, checked out alongside it:

```
~/github/lonewolf-loopring/
  ipfs-node/          private - this repo
    content -> ../ipfs-content     symlink, gitignored
    repo/             kubo blockstore. HOLDS THE NODE PRIVATE KEY.
    kubo/             the binary, v0.43.0 - fetch it, do not carry it
    ingest.sh
  ipfs-content/       PUBLIC - its own repo
    <the files>
    manifest.tsv      cid, name, bytes, added
```

They are siblings rather than nested, and neither records the other's URL. Either
can be cloned on its own, and the private repo cannot leak the public one's
existence or vice versa.

**The manifest lives with the content, not here.** That is the load-bearing choice:
a stranger clones `ipfs-content`, runs `ipfs add --only-hash --cid-version=0` over
the files, and confirms every CID without this node, without a gateway, and without
trusting whoever staged it. Keeping the manifest in the private repo would leave
the content verifiable only on the owner's word - which is the exact dependency
this whole project exists to remove.

## Use

```
./ingest.sh            add + pin everything in content/, update the manifest
./ingest.sh --verify   re-hash every staged file against the manifest
./ingest.sh --list     print the manifest
```

Nothing in that touches the network. `ipfs add` chunks and hashes locally against
the local blockstore. Announcing requires a running daemon, which the script never
starts.

## Hashing parameters are measured, not assumed

CIDv0, dag-pb leaves (`rawLeaves` false) - kubo defaults, confirmed against a real
Loopring-pinned file rather than taken on faith. `--raw-leaves` yields a different
and wrong address for identical bytes, which would look like success right up until
it failed to match anything.

Verified 8/8 against real Loopring metadata plus two published reference vectors,
including `hello world\n` -> `QmT78zSuBmuS4z925WZfrqQ1qHaJ56DQaTfyMUF7F8ff5o`.

## Why --verify exists

A staged file can change without anyone touching it deliberately - an editor
rewrite, a sync client, a truncated copy. If the recomputed CID no longer matches
the manifest, that file is not the file any more. Worth knowing before it is served
as though it were.

## Network posture

The machine runs a fail-closed nftables kill switch (see the `system-config` repo).
Egress is `policy drop` except loopback, the tunnel, LAN, the WireGuard handshake,
and the cached API addresses. A daemon started here therefore has no route out
except through the tunnel - if the tunnel drops, the node loses network rather than
falling back to the physical NIC. That is the intended behaviour and it was the
condition for running a daemon at all.

The consequence: NordVPN does not forward inbound ports, so the node can dial out
and fetch, but cannot be dialled. It will announce and mostly not be reachable by
peers. For content that must actually be retrievable by others, serving over HTTPS
from the explorer is the path that works, with this node as a secondary.

`Routing.Type` is `autoclient` - it queries the DHT without advertising itself as a
server. API 5101 and gateway 8180, both bound to 127.0.0.1.

## Getting kubo back

```
curl -L https://dist.ipfs.tech/kubo/v0.43.0/kubo_v0.43.0_linux-amd64.tar.gz | tar xz
```

`IPFS_PATH` is set by `ingest.sh` to this directory's `repo/`, so the system-wide
`~/.ipfs` is never touched.
