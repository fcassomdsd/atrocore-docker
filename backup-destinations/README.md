# Backup destination drivers

An offsite copy of a backup set, without the platform caring where "offsite"
is. Each adopting authority has different infrastructure — a second building,
a cloud tenancy, a courier and an encrypted disk — and none of that should
reach into the code that takes the backup.

## Why the seam is here and not inside `backup-platform.sh`

`backup-platform.sh` already produces a self-describing unit: a timestamped
**set directory** holding three `pg_dump`s, three `pg_basebackup`s, the
Alfresco content tarball, and a `MANIFEST` with a sha256 for every file.
`restore-platform.sh --from <dir>` verifies every one of those checksums
before it touches anything.

That boundary is the right one, so nothing about it changes. A driver only
has to move a directory somewhere and bring it back. In particular:

- **The ordering rules stay where they are.** Databases are dumped before the
  content store, and restored in the reverse order, because the other way
  round yields dangling references. That is a property of the data, not of
  the storage.
- **Verification stays honest.** Because restore already works from a local
  directory, checking an offsite copy is "fetch it back and run the existing
  drill" — no second implementation of the thing that has to be right.
- **Nothing network-shaped runs near the destructive path.**

## The contract

A driver is an executable script that takes a verb. It is passed configuration
through the environment and must not prompt.

```
<driver> capabilities
<driver> push <set-dir> <set-id>
<driver> pull <set-id> <dest-dir>
<driver> list
<driver> prune <keep-days>
```

### `capabilities`

Prints `key=value` lines. Unknown keys are ignored, so the contract can grow.

| Key | Values | Meaning |
|---|---|---|
| `fetch` | `yes` \| `no` | Can sets be read back? `no` means a write-only destination: WORM storage, tape, a courier. Verification is then limited to what was sent, and `backup-offsite.sh verify` refuses rather than pretending. |
| `prune` | `yes` \| `no` \| `self` | `self` means the destination expires sets on its own — an S3 lifecycle rule, say. A client that also prunes is at best redundant and at worst fighting the bucket policy, so the dispatcher skips pruning entirely for `self`. |
| `name` | free text | Shown in output. |

### `push <set-dir> <set-id>`

Copy every file in `set-dir` to the destination under `set-id`.

**`MANIFEST` must be written last.** Every network destination can fail
half-way, and a set whose MANIFEST is present is treated as complete. Sending
it first would let a partial set look restorable. (The same rule as the
release update feed in `compliance_checklist`, for the same reason.)

Must be idempotent: re-pushing an existing set overwrites it rather than
failing.

### `pull <set-id> <dest-dir>`

Copy the set into `dest-dir`, which the dispatcher creates. Drivers with
`fetch=no` must exit non-zero with a clear message.

### `list`

One set id per line, sorted oldest first. No other output on stdout.

### `prune <keep-days>`

Remove sets older than `keep-days`, print the number removed. **Age is
computed from the set id, never from a file timestamp** — object stores have
no directory mtime, and copying a set changes file times. Set ids are
`YYYYMMDDTHHMMSSZ`; `lib/set-age.sh` does the arithmetic so every driver
agrees. Drivers reporting `prune=self` may exit 0 without doing anything.

## Writing your own

Around forty lines. Copy `local.sh`, replace the five verbs, and then — this
is the part that matters — run the conformance test against your destination:

```bash
BACKUP_DESTINATION=my-driver ./scripts/verify-backup-destination.sh
```

It pushes a synthetic set, lists it, pulls it back, compares every checksum
byte for byte, re-pushes to prove idempotency, checks that MANIFEST-last
holds, and exercises pruning.

**We verify the contract; you verify your backend.** Nobody here can test an
Azure tenancy or a tape robot, and a driver that has not been run against the
storage it targets is a guess. That test is the difference between
"pluggable" as a property and as a claim.

## Shipped drivers

| Driver | For | Needs |
|---|---|---|
| `local.sh` | A second disk, an NFS or SMB mount, an attached USB drive | nothing |
| `rsync-ssh.sh` | Any second host reachable over SSH | `rsync`, `ssh` |
| `s3.sh` | AWS S3 and anything S3-compatible — MinIO, Ceph, Wasabi, most national cloud offerings | `aws` CLI |

Configuration for each is documented at the top of its own file.

> **A destination on the same machine is not offsite.** `local.sh` pointed at
> another directory on the same disk protects against nothing this is for. It
> is meant for a genuinely separate volume, and the conformance test cannot
> tell the difference — only you can.
