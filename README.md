# ssh-key-helper

Repair local SSH key permissions and write explicit per-host SSH client config to avoid common OpenSSH authentication issues.

## What It Does

- sets safe permissions on `~/.ssh`, private keys, and public keys
- writes managed per-host `~/.ssh/config` blocks with `IdentityFile` and `IdentitiesOnly yes`
- tests SSH authentication with an optional identity file

It is a client-side helper. It does not edit server-side `sshd_config`, manage `authorized_keys`, or load keys into `ssh-agent`.

## Install

Download the script, review it, then install the `ssh-key-helper` command:

```bash
curl -fsSL https://raw.githubusercontent.com/peternickol/ssh-key-helper/master/ssh-key-helper.sh -o ssh-key-helper.sh
less ssh-key-helper.sh
sudo bash ssh-key-helper.sh install
rm ssh-key-helper.sh
```

The installed command is:

```bash
/usr/local/bin/ssh-key-helper
```

Install without bash completion:

```bash
sudo bash ssh-key-helper.sh install --no-completion
```

## Update And Uninstall

Update the installed command from GitHub:

```bash
sudo ssh-key-helper update
```

Update without refreshing bash completion:

```bash
sudo ssh-key-helper update --no-completion
```

Uninstall the command and bash completion:

```bash
sudo ssh-key-helper uninstall
```

## Local Use

You can also run the script directly without installing it:

```bash
./ssh-key-helper.sh fix-perms
./ssh-key-helper.sh test git@github.com
./ssh-key-helper.sh config user@example.com ~/.ssh/example_key
ssh example.com
```

## Commands

`fix-perms`
: Set `~/.ssh` to `700`, private keys to `600`, and public keys to `644`.

`config <host> <identity-file>`
: Write a managed host block to `~/.ssh/config`. Hosts may include a user, such as `user@example.com`.

`test [host] [identity-file]`
: Run `ssh -T` against a host. When an identity file is provided, the helper uses `IdentitiesOnly=yes` for that test.

`install [--force] [--no-completion]`
: Install the current script to `/usr/local/bin/ssh-key-helper` and install bash completion when available.

`update [--no-completion]`
: Download the latest public script from GitHub, syntax-check it, and install it to `/usr/local/bin/ssh-key-helper`.

`uninstall`
: Remove `/usr/local/bin/ssh-key-helper` and its bash completion file.

Completion-only helpers:

```bash
sudo ssh-key-helper install --completion-only
sudo ssh-key-helper install --uninstall-completion
```

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
bash -n ssh-key-helper.sh
shellcheck ssh-key-helper.sh
```

## License

MIT
