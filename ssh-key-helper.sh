#!/usr/bin/env bash
set -Eeuo pipefail

if [[ -t 1 || -t 2 ]] && [[ "${NO_COLOR:-0}" != "1" ]]; then
  C_RESET=$'\033[0m'
  C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'
  C_GREEN=$'\033[32m'
  C_CYAN=$'\033[36m'
else
  C_RESET=""
  C_RED=""
  C_YELLOW=""
  C_GREEN=""
  C_CYAN=""
fi

SSH_DIR="${SSH_DIR:-$HOME/.ssh}"
VERSION="0.1.0"
INSTALL_PATH="${INSTALL_PATH:-/usr/local/bin/ssh-key-helper}"
BASH_COMPLETION_NAME="ssh-key-helper"
UPDATE_URL="${UPDATE_URL:-https://raw.githubusercontent.com/peternickol/ssh-key-helper/master/ssh-key-helper.sh}"

FORCE=0
NO_COMPLETION=0
COMPLETION_ONLY=0
UNINSTALL_COMPLETION=0

info() { printf '%b[INFO]%b %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok() { printf '%b[OK]%b %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%b[WARN]%b %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
error() { printf '%b[ERROR]%b %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die() { error "$*"; exit 1; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<EOF
Usage:
  ssh-key-helper [global-options] fix-perms
  ssh-key-helper [global-options] test [host] [identity-file]
  ssh-key-helper [global-options] config <host> <identity-file>
  ssh-key-helper [global-options] install
  ssh-key-helper [global-options] update
  ssh-key-helper [global-options] uninstall
  ssh-key-helper [global-options] help

Commands:
  fix-perms         Set safe permissions on SSH files
  test [host] [key] Test SSH auth, defaults to git@github.com
  config <host>     Write an SSH config entry with IdentitiesOnly=yes
  install           Install to: $INSTALL_PATH
  update            Download and install the latest version
  uninstall         Remove installed binary and bash completion

Global options:
  -f, --force             Overwrite existing installed files
  -V, --version           Show version
  -h, --help              Show help
  --no-completion         Install/update binary only
  --completion-only       Install bash completion only
  --uninstall-completion  Remove installed bash completion

Environment:
  SSH_DIR      Override SSH directory, default: $HOME/.ssh
EOF
}

show_version() {
  printf 'ssh-key-helper v%s\n' "$VERSION"
}

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    die "must be run as root. Try: sudo ssh-key-helper ${*:-}"
  fi
}

ensure_ssh_dir() {
  [[ -d "$SSH_DIR" ]] || die "SSH directory not found: $SSH_DIR"
}

is_private_key() {
  local file="$1"
  local name
  local first_line

  [[ -f "$file" ]] || return 1
  name="$(basename "$file")"
  [[ "$name" != *.pub ]] || return 1

  case "$name" in
    authorized_keys|config|environment|known_hosts|known_hosts.old)
      return 1
      ;;
  esac

  IFS= read -r first_line <"$file" || return 1
  [[ "$first_line" == "-----BEGIN "*PRIVATE\ KEY----- ]]
}

private_keys() {
  local file

  ensure_ssh_dir
  while IFS= read -r -d '' file; do
    if is_private_key "$file"; then
      printf '%s\0' "$file"
    fi
  done < <(find "$SSH_DIR" -maxdepth 1 -type f -print0)
}

fix_perms() {
  local file
  local private_count=0
  local public_count=0

  ensure_ssh_dir

  chmod 700 "$SSH_DIR"
  info "Set $SSH_DIR to 700"

  while IFS= read -r -d '' file; do
    chmod 600 "$file"
    private_count=$((private_count + 1))
    info "Set private key to 600: $file"
  done < <(private_keys)

  while IFS= read -r -d '' file; do
    chmod 644 "$file"
    public_count=$((public_count + 1))
    info "Set public key to 644: $file"
  done < <(find "$SSH_DIR" -maxdepth 1 -type f -name '*.pub' -print0)

  ok "Fixed $private_count private key(s) and $public_count public key(s)."
}

expand_identity_path() {
  local path="$1"

  case "$path" in
    "~/"*) printf '%s/%s\n' "$HOME" "${path#"~/"}" ;;
    *) printf '%s\n' "$path" ;;
  esac
}

fix_identity_perms() {
  local identity_file="$1"
  local local_identity_file

  local_identity_file="$(expand_identity_path "$identity_file")"
  [[ -f "$local_identity_file" ]] || die "Identity file not found: $identity_file"
  [[ "$local_identity_file" != *.pub ]] || die "Identity file must be a private key, not a .pub file: $identity_file"

  chmod 600 "$local_identity_file"
  info "Set private key to 600: $local_identity_file"
}

split_ssh_host() {
  local value="$1"
  local user_var="$2"
  local host_var="$3"
  local parsed_user=""
  local parsed_host="$value"

  if [[ "$value" == *@* ]]; then
    parsed_user="${value%@*}"
    parsed_host="${value#*@}"
  fi

  [[ -n "$parsed_host" ]] || die "Host cannot be empty"

  printf -v "$user_var" '%s' "$parsed_user"
  printf -v "$host_var" '%s' "$parsed_host"
}

remove_managed_block() {
  local config_file="$1"
  local begin_marker="$2"
  local end_marker="$3"
  local temp_file="$4"
  local in_managed_block=0
  local line

  if [[ -f "$config_file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in
        "$begin_marker")
          in_managed_block=1
          continue
          ;;
        "$end_marker")
          in_managed_block=0
          continue
          ;;
      esac

      if ((in_managed_block == 0)); then
        printf '%s\n' "$line" >>"$temp_file"
      fi
    done <"$config_file"
  fi
}

install_config() {
  local temp_file="$1"
  local config_file="$SSH_DIR/config"

  mv "$temp_file" "$config_file"
  chmod 600 "$config_file"
}

write_host_config() {
  local target="${1:-}"
  local identity_file="${2:-}"
  local user=""
  local host=""
  local config_file="$SSH_DIR/config"
  local temp_file=""

  [[ -n "$target" ]] || die "config requires a host, for example: ssh-key-helper config root@example.com ~/.ssh/director"
  [[ -n "$identity_file" ]] || die "config requires an identity file"

  ensure_ssh_dir
  split_ssh_host "$target" user host
  fix_identity_perms "$identity_file"

  identity_file="${identity_file/#$HOME/~}"
  temp_file="$(mktemp)"
  remove_managed_block "$config_file" "# ssh-key-helper: begin $host" "# ssh-key-helper: end $host" "$temp_file"

  {
    if [[ -s "$temp_file" ]]; then
      printf '\n'
    fi
    printf '# ssh-key-helper: begin %s\n' "$host"
    printf 'Host %s\n' "$host"
    printf '  HostName %s\n' "$host"
    if [[ -n "$user" ]]; then
      printf '  User %s\n' "$user"
    fi
    printf '  IdentityFile %s\n' "$identity_file"
    printf '  IdentitiesOnly yes\n'
    printf '# ssh-key-helper: end %s\n' "$host"
  } >>"$temp_file"

  install_config "$temp_file"
  ok "Wrote SSH config for $target in $config_file"
}

test_ssh() {
  local host="${1:-git@github.com}"
  local identity_file="${2:-}"
  local ssh_options=(-T)

  if [[ -n "$identity_file" ]]; then
    ssh_options+=(-o IdentitiesOnly=yes -i "$identity_file")
  fi

  ssh "${ssh_options[@]}" "$host"
}

generate_bash_completion() {
  cat <<'EOF'
# bash completion for ssh-key-helper

_ssh_key_helper()
{
  local cur prev words cword

  if type _init_completion >/dev/null 2>&1; then
    _init_completion || return
  else
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    words=("${COMP_WORDS[@]}")
    cword="$COMP_CWORD"
  fi

  local commands="fix-perms test config install update uninstall help"
  local opts="-f --force -V --version -h --help --no-completion --completion-only --uninstall-completion"

  if [[ $cword -eq 1 ]]; then
    COMPREPLY=( $(compgen -W "$opts $commands" -- "$cur") )
    return 0
  fi

  if [[ "$cur" == -* ]]; then
    COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
    return 0
  fi

  case "${words[1]}" in
    config|test)
      if [[ $cword -eq 3 ]]; then
        COMPREPLY=( $(compgen -f -- "$cur") )
        compopt -o filenames 2>/dev/null || true
      fi
      ;;
  esac
}

complete -F _ssh_key_helper ssh-key-helper
EOF
}

detect_completion_dir() {
  if [[ -d /usr/share/bash-completion ]]; then
    mkdir -p /usr/share/bash-completion/completions 2>/dev/null || true
    if [[ -d /usr/share/bash-completion/completions ]]; then
      printf '%s\n' "/usr/share/bash-completion/completions"
      return 0
    fi
  fi

  if [[ -d /etc/bash_completion.d ]]; then
    printf '%s\n' "/etc/bash_completion.d"
    return 0
  fi

  return 1
}

install_completion() {
  local dir file

  dir="$(detect_completion_dir)" || {
    warn "bash-completion not installed. Skipping completion."
    warn "Install with: sudo apt install bash-completion"
    return 0
  }

  file="$dir/$BASH_COMPLETION_NAME"
  if [[ -e "$file" && "$FORCE" -ne 1 ]]; then
    die "Completion already exists at $file (use --force to overwrite)."
  fi

  info "Installing bash completion: $file"
  generate_bash_completion >"$file"
  chmod 0644 "$file"
  ok "Bash completion installed."
}

uninstall_completion() {
  local dir file

  dir="$(detect_completion_dir)" || {
    warn "No bash-completion directory found."
    return 0
  }

  file="$dir/$BASH_COMPLETION_NAME"
  if [[ ! -e "$file" ]]; then
    warn "No completion installed at $file"
    return 0
  fi

  info "Removing bash completion: $file"
  rm -f "$file"
  ok "Bash completion removed."
}

self_path() {
  if have_cmd readlink; then
    readlink -f "$0" 2>/dev/null || printf '%s\n' "$0"
  else
    printf '%s\n' "$0"
  fi
}

cmd_install() {
  local src dest

  while (($# > 0)); do
    case "$1" in
      -f|--force) FORCE=1; shift ;;
      --no-completion) NO_COMPLETION=1; shift ;;
      --completion-only) COMPLETION_ONLY=1; shift ;;
      --uninstall-completion) UNINSTALL_COMPLETION=1; shift ;;
      *) die "Unknown install option: $1" ;;
    esac
  done

  require_root install
  src="$(self_path)"
  dest="$INSTALL_PATH"

  if [[ "$UNINSTALL_COMPLETION" -eq 1 ]]; then
    uninstall_completion
    exit 0
  fi

  if [[ "$COMPLETION_ONLY" -eq 1 ]]; then
    install_completion
    exit 0
  fi

  [[ -f "$src" ]] || die "Cannot locate script file to install: $src"
  if [[ -e "$dest" && "$FORCE" -ne 1 ]]; then
    die "$dest already exists. Re-run with --force to overwrite."
  fi

  info "Installing $src to $dest"
  install -m 0755 -o root -g root "$src" "$dest"
  ok "Installed binary: $dest"

  if [[ "$NO_COMPLETION" -eq 0 ]]; then
    install_completion
  else
    info "Skipping completion installation (--no-completion)."
  fi
}

download_update_source() {
  local dest="$1"

  if have_cmd curl; then
    curl -fsSL "$UPDATE_URL" -o "$dest"
    return 0
  fi

  if have_cmd wget; then
    wget -qO "$dest" "$UPDATE_URL"
    return 0
  fi

  die "Neither curl nor wget is installed. Install one of them to use update."
}

cmd_update() {
  local tmp

  while (($# > 0)); do
    case "$1" in
      --no-completion) NO_COMPLETION=1; shift ;;
      *) die "Unknown update option: $1" ;;
    esac
  done

  require_root update
  tmp="$(mktemp "${TMPDIR:-/tmp}/ssh-key-helper.update.XXXXXX")"
  trap 'rm -f "$tmp"' RETURN

  info "Downloading latest ssh-key-helper from $UPDATE_URL"
  download_update_source "$tmp"
  [[ -s "$tmp" ]] || die "Downloaded update is empty."
  bash -n "$tmp" || die "Downloaded update failed syntax check."

  info "Installing update to $INSTALL_PATH"
  install -m 0755 -o root -g root "$tmp" "$INSTALL_PATH"
  ok "Updated binary: $INSTALL_PATH"

  if [[ "$NO_COMPLETION" -eq 0 ]]; then
    install_completion
  else
    info "Skipping completion installation (--no-completion)."
  fi
}

cmd_uninstall() {
  while (($# > 0)); do
    case "$1" in
      --uninstall-completion) UNINSTALL_COMPLETION=1; shift ;;
      *) die "Unknown uninstall option: $1" ;;
    esac
  done

  require_root uninstall

  if [[ "$UNINSTALL_COMPLETION" -eq 1 ]]; then
    uninstall_completion
    exit 0
  fi

  if [[ -e "$INSTALL_PATH" ]]; then
    info "Removing $INSTALL_PATH"
    rm -f "$INSTALL_PATH"
    ok "Removed binary: $INSTALL_PATH"
  else
    warn "Not installed: $INSTALL_PATH"
  fi

  uninstall_completion
}

main() {
  local command="${1:-help}"

  while (($# > 0)); do
    case "$1" in
      -f|--force) FORCE=1; shift ;;
      --no-completion) NO_COMPLETION=1; shift ;;
      --completion-only) COMPLETION_ONLY=1; shift ;;
      --uninstall-completion) UNINSTALL_COMPLETION=1; shift ;;
      -V|--version) show_version; exit 0 ;;
      -h|--help) usage; exit 0 ;;
      --) shift; break ;;
      -*) die "Unknown option: $1" ;;
      *) break ;;
    esac
  done

  command="${1:-help}"
  shift || true

  case "$command" in
    fix-perms) fix_perms "$@" ;;
    test) test_ssh "$@" ;;
    config) write_host_config "$@" ;;
    install) cmd_install "$@" ;;
    update) cmd_update "$@" ;;
    uninstall) cmd_uninstall "$@" ;;
    help|-h|--help) usage ;;
    *) die "Unknown command: $command" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
