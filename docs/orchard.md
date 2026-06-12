# Multi-host runners with Orchard

A single Mac caps at **2 macOS VMs** (Apple's kernel limit). To run more runners,
add hosts — and let [Orchard](https://github.com/cirruslabs/orchard) schedule VMs
across them. Orchard is Cirrus Labs' orchestrator for Tart: a **controller** that
holds desired state and a fleet of **workers** (Apple Silicon Macs running `tart`)
that actually boot the VMs.

graft's `OrchardProvider` is a drop-in swap for the local Tart backend — same pool
config, same ephemeral runner loop, same `.graft` images. The only change is
`provider: "orchard"` plus an `orchard` block. graft asks the controller to create a
VM; the controller picks a worker with free capacity (and enforces the per-host
2-macOS limit for you); graft runs the runner over Orchard's SSH tunnel and deletes
the VM when the job's done.

> **Status:** built and unit-tested, but unverified end-to-end without a live
> controller + worker. Treat the first real run as a shakedown.

---

## How graft talks to Orchard

graft shells out to the `orchard` CLI (just like the local backend shells out to
`tart`), so the [`orchard` binary](https://tart.run/orchard/quick-start/) must be on
the `PATH` of the machine running `graft run`:

```sh
brew install cirruslabs/cli/orchard
```

Auth + endpoint are passed to every `orchard` call via environment, so graft never
runs `orchard context create` or touches `~/.config/orchard`:

| Env var | From config |
|---|---|
| `ORCHARD_URL` | `orchard.controllerURL` |
| `ORCHARD_SERVICE_ACCOUNT_NAME` | `orchard.serviceAccount` |
| `ORCHARD_SERVICE_ACCOUNT_TOKEN` | `orchard.token` |

Each `VMProvider` method maps to one `orchard` subcommand:

| graft | orchard |
|---|---|
| acquire | `orchard create vm --image … --os darwin\|linux --restart-policy never [--host-dirs …] [--net-*] graft-<uuid>`, then poll `get vm <name>/status` until `running` |
| release | `orchard delete vm <name>` |
| exec | `orchard ssh vm --wait 0 <name> "<cmd>"` |
| run the runner | `orchard ssh vm --wait 0 <name> "bash -s"` (script on stdin) |

graft names every VM `graft-<uuid>` so the shutdown sweep (`orchard list vms`) can
find and delete its own VMs without touching anything else on the cluster.

## Setup

### 1. Stand up a controller and workers
Follow the [Orchard deployment guide](https://tart.run/orchard/deploying-controller/).
In short: run the controller somewhere reachable, then join one or more Macs as
workers (`orchard worker run …`). Each worker needs `tart` and — like any Tart
host — an **active GUI login session** to boot VMs (see
[ec2-mac-setup.md](ec2-mac-setup.md) for headless hosts).

### 2. Create a service account for graft
graft authenticates as an Orchard service account with rights to create/manage VMs.
Create one and grab its token (see `orchard create service-account --help`).

### 3. Point graft at the controller
```json
{
  "provider": "orchard",
  "orchard": {
    "controllerURL": "https://orchard.example.com:6120",
    "serviceAccount": "graft",
    "token": "<service-account-token>",
    "maxVMs": 8
  },
  "pools": [
    {
      "name": "macos-ci",
      "image": "ghcr.io/cirruslabs/macos-tahoe-xcode:latest",
      "os": "macos",
      "count": 6,
      "github": { "appId": 12345, "target": "org:my-org", "runnerGroupId": 1 }
    }
  ],
  "secrets": { "store": "keychain", "scope": "login" }
}
```

Validate and run:
```sh
graft config validate
graft run
```

## Capacity & scheduling

graft does **not** second-guess placement — the controller schedules across the
fleet and owns Apple's per-host 2-macOS-VM limit. `maxVMs` (default 100) is just the
ceiling graft fills toward; anything that doesn't fit right now the controller
queues. So set your pool `count` to the number of runners you actually want and let
the cluster absorb it.

> **The 2-macOS escape hatch.** Orchard can schedule a macOS image as an `os: linux`
> VM to dodge the 2-macOS-VM/host cap (the guest still runs macOS; only the
> bookkeeping differs). graft passes the pool's declared `os` straight through, so
> this is an operator choice — set `os: linux` on the pool if you've accepted the
> tradeoffs. See the Orchard docs.

## Mounts & images

- **Images:** workers pull pool images themselves (`image-pull-policy` =
  *if-not-present*), so graft skips the local pre-pull it does for the Tart backend.
  Push your `.graft`-built images to a registry the workers can reach.
- **Mounts:** a pool's `mounts` become `orchard create vm --host-dirs …`. Note these
  resolve on the **worker** host, not on the machine running `graft run` — only
  useful for paths that exist on the workers.
- **Networking:** a pool's `network` maps to `--net-bridged <iface>` / `--net-softnet`
  on the worker, same as the local backend.

## Troubleshooting

- **`orchard ssh` / port-forward fails instantly with `context deadline exceeded` (500).**
  Orchard's `--wait` flag is the deadline for the *entire* port-forward rendezvous (the
  controller waiting for the worker to stand up the SSH tunnel), not just "wait for the VM
  to be running" — so `--wait 0` kills the tunnel in ~100µs before the worker can respond.
  graft never passes `--wait 0` for this reason (see `OrchardProvider.sshArgs`); if you
  hit this driving `orchard` by hand, pass a real `--wait` (the CLI default is 60s).
- **Tart's default 1-day DHCP lease** can independently cause worker↔VM comms issues
  (Orchard warns about it at startup); if VMs are genuinely unreachable, fix it per
  [tart.run/faq → DHCP lease time](https://tart.run/faq/#changing-the-default-dhcp-lease-time).

**Verified end-to-end against Orchard 0.55.0** (`orchard dev`, single Mac): `create vm`
(with `--os`), `get vm <name>/status` polling, `ssh vm` exec, the JIT runner downloading
over `orchard ssh` and registering on GitHub ("Listening for Jobs"), and `delete vm`.
graft avoids `list vms --quiet` (added after 0.55.0) and doesn't pass `--restart-policy`
(Orchard defaults to `Never`, which is what ephemeral runners want).
