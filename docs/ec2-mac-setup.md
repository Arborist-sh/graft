# Running graft on an EC2 Mac (headless host setup)

Tart boots VMs with Apple's **Virtualization.framework**, which **requires an active
GUI login session** on the host. EC2 Macs boot to the login window with *no* session
and are only touched over SSH — so Tart fails with:

```
an error occurred while attempting to obtain endpoint for listener
'ClientCallsAuxiliary': Connection interrupted
```

…and graft sits on `booting VM` forever (`acquire failed: timed out … waiting for
graft-… to get an IP`). **"The instance is running" is not the same as "a user is
logged into the GUI."**

This guide creates a persistent **auto-login session** so VMs can boot. After setup
it's fully headless — no monitor, no human — and you operate entirely over SSH. EC2
Macs ship with **FileVault off**, so auto-login works without extra steps.

> Applies to any headless Apple Silicon Mac, not just EC2 — substitute your username
> for `ec2-user` throughout.

---

## Steps

Run everything over SSH as `ec2-user`.

### 1. Confirm the problem

```sh
stat -f '%Su' /dev/console     # prints "root" → no GUI session (this is the cause)
who                            # no "ec2-user … console" line
```

### 2. Give `ec2-user` a password

`ec2-user` has no password by default; auto-login needs one.

```sh
sudo dscl . -passwd /Users/ec2-user 'CHOOSE_A_PASSWORD'
```

### 3. Enable automatic login

```sh
sudo sysadminctl -autologin set -userName ec2-user -password 'CHOOSE_A_PASSWORD'
```

### 4. Reboot so the GUI session comes up

```sh
sudo reboot
```

Wait ~2 minutes, then SSH back in.

### 5. Verify the GUI session now exists

```sh
stat -f '%Su' /dev/console     # should now print "ec2-user"
who                            # should show "ec2-user … console"
```

If it still says `root`, auto-login didn't take — see [Troubleshooting](#troubleshooting).

### 6. Prove Tart can boot a VM (no graft involved)

```sh
tart clone ghcr.io/cirruslabs/macos-tahoe-base:latest iptest
tart run iptest --no-graphics &
sleep 60 && tart ip iptest     # should print an IP, not an error
tart stop iptest && tart delete iptest
```

If you get an IP here, the hard part is done.

### 7. Run graft, kept awake so the session never sleeps

```sh
caffeinate -dimsu graft run
```

---

## Troubleshooting

**Step 5 still shows `root` (auto-login didn't take).**
Enable Screen Sharing, VNC in once, and set auto-login via System Settings → Users &
Groups → *Automatically log in as → ec2-user*, then reboot:

```sh
sudo launchctl enable system/com.apple.screensharing
sudo launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist
# then connect a VNC client to <instance-ip>:5900 as ec2-user
```

**Step 6 still errors with `ClientCallsAuxiliary` despite a console session.**
The SSH process isn't seeing the session — run *inside* it via `launchctl asuser`:

```sh
sudo launchctl asuser "$(id -u ec2-user)" sudo -u ec2-user tart run iptest --no-graphics &
# and run graft the same way:
sudo launchctl asuser "$(id -u ec2-user)" sudo -u ec2-user caffeinate -dimsu graft run
```

**Leftover VMs blocking the 2-macOS-VM limit.**
Stray `graft-*` VMs from a previous run hold the quota so new clones can't boot:

```sh
tart list
tart list | awk '/graft-/{print $1}' | xargs -n1 tart delete
```

---

## Security considerations

Auto-login is a real trade-off — it trades *credential-at-rest auth* for
*network-perimeter auth*. For a dedicated, network-isolated CI runner that's a
reasonable and standard trade (it's how the industry runs Mac CI), but understand
what changes:

- **The host boots into an unlocked, authenticated session** with no screen-lock
  auth, and the **login keychain is unlocked at boot** — so the GitHub App key is
  readable by any process running as `ec2-user`. You lose the defense-in-depth a
  locked keychain would give against a stray host process.
- **Screen Sharing / VNC (port 5900)** is dangerous if exposed. If you enable it for
  setup, lock it to your VPN/security group and disable it again afterward.

What actually keeps the host safe (these matter more than the login screen):

- **Lock the AWS security group** — SSH from known IPs/your VPN only, port 5900 never
  public. This is the dominant control; with it in place, auto-login's "no console
  auth" is only reachable from inside your network.
- **The VM boundary protects the key.** CI jobs run *inside the ephemeral guest VM*,
  not on the host — the host keychain (and the App key) is not reachable from the
  guest. A malicious job can't read the key, auto-login or not.
- **Scope the GitHub App minimally** — a dedicated App for runners, installed only on
  the repo(s) it needs, least permissions (self-hosted-runner admin). If the key ever
  leaks, the blast radius is one repo, not the org. Rotate it periodically
  (`graft secrets import` makes re-import trivial).
- **Treat the runner as low-trust by design** — it runs untrusted code; don't store
  anything else sensitive on it.

On a corporate/regulated host, check your security team's policy on auto-login before
rolling it out — CI Macs are usually a known exception, but get sign-off.

## Notes

- **Auto-login persists across reboots** — this is a one-time setup.
- With the login session unlocked at boot, the **login keychain is reachable**, so
  graft's GitHub App key can live there — no system keychain needed. Import with:
  ```sh
  graft secrets import --app-id <APP_ID> --pem ./app.pem
  ```
- **Don't run graft as a LaunchDaemon** — daemons have no GUI session and hit this
  exact wall. Use a **LaunchAgent** (loaded in the user's GUI session) if you want
  graft to start automatically on boot instead of SSH-ing in to launch it.
