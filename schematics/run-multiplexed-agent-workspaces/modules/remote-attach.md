# Module: remote-attach

## Purpose

Owns the transport `herdr --remote` arrives through, and the three properties
that decide whether it attaches to the real session or lands somewhere else. It
is explicitly NOT responsible for what an attaching client sees (that is the
session's workspace set) and not a user interface: it configures, starts and
verifies an SSH daemon, nothing more.

## Inputs

- `AGENT_SSH_ENABLE`, `AGENT_SSH_PORT`, `AGENT_SSH_LISTEN` (`P-18` … `P-20`).
- `AGENT_SSHD_DIR` and `AGENT_SSH_AUTHORIZED_KEYS` (`P-21`, `P-22`) — inside
  the mounted tree by default, which is what keeps the host identity across a
  recreate; a deployment that points them at `$HOME` moves the identity into the
  container's writable layer and loses it on the next recreate.
- `XDG_CONFIG_HOME` and `HERDR_SESSION` (`P-14`, `P-15`): the values the herdr
  server is started with, and therefore the values the SSH sessions must carry.
- `sshd` from the image's package set (`D-1`'s layer, built by `host-image.md`).

## Outputs

- `$AGENT_SSHD_DIR/ssh_host_ed25519_key` — generated on first boot, reused after.
- `$AGENT_SSHD_DIR/sshd_config`, written on every boot, key-only:

  ```
  Port <P-19>
  ListenAddress <P-20>
  HostKey <P-21>/ssh_host_ed25519_key
  AuthorizedKeysFile <P-22>
  PasswordAuthentication no
  KbdInteractiveAuthentication no
  PermitRootLogin no
  PubkeyAuthentication yes
  UsePAM no
  PidFile <P-21>/sshd.pid
  SetEnv XDG_CONFIG_HOME=<P-15> HERDR_SESSION=<P-14>
  ```

- A running sshd: started when its pid file names no live process, HUP-reloaded
  otherwise — never duplicated.
- Two boot-time messages the operator can act on: a warning when the daemon is
  not its own session leader (remote attach will offer a restart), and one when
  the authorized-keys file is empty (key-only auth will reject everything).
- `scripts/check-remote-attach.sh`, which verifies the same properties from
  inside the host and prints, per check, what to fix.

## The three requirements, and the symptom of each

| Requirement | How it is met | Symptom when missing |
|-------------|---------------|----------------------|
| a key-only sshd is reachable, running as the account that owns the herdr socket | the config above, started at boot | `Permission denied (publickey)`, or a connection that never establishes |
| every SSH session carries the server's `XDG_CONFIG_HOME` and `HERDR_SESSION` | the `SetEnv` line, written from the same variables the server was started with | a remote `herdr session list` is empty (wrong config root) or lists the wrong session; attach misses the real one |
| the server process is its own session leader | `setsid herdr server` at boot; the boot logs a warning if the running server is not | `herdr --remote` offers to restart the server; answering can fail with a stop error and then land in a brand-new empty session |

The third one is why the server is started the way it is. A plain background
server shares the boot session, fails the `detached_server_daemon` check, and
turns a routine attach into a restart of the process that hosts every agent.

## Dependencies

`D-1` (the layer from `host-image.md` installs `openssh-server`), `D-8` (an SSH
client and a herdr client binary on the operator's machine, for the attach
itself), and the parameters `P-14`, `P-15`, `P-18` … `P-22`.

## Failure Behavior

| Condition | Behavior |
|-----------|----------|
| `AGENT_SSH_ENABLE=1` and no `sshd` on the host | refusal, exit 78, naming the variable and the missing program |
| the generated configuration is rejected by `sshd -t` | refusal, exit 78, naming the config path — a daemon that will not start must not be left half-configured |
| the port is already in use | sshd's own error at start, then the refusal above |
| the authorized-keys file is empty | the host boots, with a warning: the operator may be about to add the key, and a refusal here would make the first boot impossible to finish |
| a client connects with a password | rejected: password authentication is off, and there is no password to use (the account's is locked in the base) |
| the listening address is the loopback default and nothing is published | nothing outside the container can reach the daemon — this is the default posture, not a fault; publishing is a deliberate deployment change |

## Idempotency Notes

`sshd_config` is rewritten with the same content on every boot, so a config
change is a reboot away and a reboot changes nothing else; the host key is
generated only when absent, which is what keeps a client's `known_hosts` entry
valid across recreates. Restarting the daemon is conditional on its pid file, so
re-running the boot does not accumulate daemons or orphan the pid file.

## Removal Notes

`AGENT_SSH_ENABLE=0` stops the host from starting a daemon; an already running
one keeps running until the container is recreated, since nothing supervises it.
To remove attach entirely: disable SSH, remove the published port from the
deployment, and delete `$AGENT_SSHD_DIR` if the host key should not be reused.
The herdr server keeps running either way — attach is a transport, not the
session.
