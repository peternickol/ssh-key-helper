# ssh-key-helper

Repair local SSH key permissions and write explicit per-host SSH client config to avoid common OpenSSH authentication issues.

## What It Does

- sets safe permissions on `~/.ssh`, private keys, and public keys
- writes managed per-host `~/.ssh/config` blocks with `IdentityFile` and `IdentitiesOnly yes`
- tests SSH authentication with an optional identity file

It is a client-side helper. It does not edit server-side `sshd_config`, manage `authorized_keys`, or load keys into `ssh-agent`.

## Usage

```bash
./ssh-key-helper fix-perms
./ssh-key-helper test git@github.com
./ssh-key-helper config user@example.com ~/.ssh/example_key
ssh example.com
```

## Commands

`fix-perms`
: Set `~/.ssh` to `700`, private keys to `600`, and public keys to `644`.

`config <host> <identity-file>`
: Write a managed host block to `~/.ssh/config`. Hosts may include a user, such as `user@example.com`.

`test [host] [identity-file]`
: Run `ssh -T` against a host. When an identity file is provided, the helper uses `IdentitiesOnly=yes` for that test.

## Config Blocks

Host config entries are wrapped in managed markers so they can be updated safely on repeat runs:

```sshconfig
# ssh-key-helper: begin example.com
Host example.com
  HostName example.com
  User user
  IdentityFile ~/.ssh/example_key
  IdentitiesOnly yes
# ssh-key-helper: end example.com
```

## Environment

`SSH_DIR`
: Override the SSH directory. Defaults to `~/.ssh`.

## Verification

```bash
bash -n ssh-key-helper
```
