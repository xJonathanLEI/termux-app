#!/usr/bin/env bash
set -euo pipefail

# Setup script for a debug Termux APK on a connected Android emulator/device.
#
# The script:
#   1. Uninstalls Termux if it is installed.
#   2. Installs the debug APK.
#   3. Starts Termux once so its app data/bootstrap can initialize.
#   4. Enables RUN_COMMAND access for automated testing.
#   5. Runs a command inside the Termux environment that installs OpenSSH.
#   6. Configures and launches sshd with ~/.ssh/termux-emulator.pub and password logins disabled.
#   7. Forwards the SSH port over adb and verifies SSH connectivity with `ssh termux-emulator`.
#   8. Pulls and prints command results written by Termux.
#
# Usage:
#   ./scripts/setup-termux.sh

ADB="adb"
PACKAGE="com.termux"
APK="app/build/outputs/apk/debug/termux-app_apt-android-7-debug_universal.apk"

BOOTSTRAP_TIMEOUT_SECONDS="90"
COMMAND_TIMEOUT_SECONDS="180"
SSH_PORT="8022"
HOST_SSH_PORT="8022"
SSH_CONNECT_TIMEOUT_SECONDS="30"
TERMUX_SSH_USER=""

RUN_COMMAND_ACTION="${PACKAGE}.RUN_COMMAND"
RUN_COMMAND_PATH_EXTRA="${PACKAGE}.RUN_COMMAND_PATH"
RUN_COMMAND_ARGUMENTS_EXTRA="${PACKAGE}.RUN_COMMAND_ARGUMENTS"
RUN_COMMAND_WORKDIR_EXTRA="${PACKAGE}.RUN_COMMAND_WORKDIR"
RUN_COMMAND_RUNNER_EXTRA="${PACKAGE}.RUN_COMMAND_RUNNER"
RUN_COMMAND_RESULT_DIRECTORY_EXTRA="${PACKAGE}.RUN_COMMAND_RESULT_DIRECTORY"
RUN_COMMAND_RESULT_SINGLE_FILE_EXTRA="${PACKAGE}.RUN_COMMAND_RESULT_SINGLE_FILE"
RUN_COMMAND_RESULT_FILE_BASENAME_EXTRA="${PACKAGE}.RUN_COMMAND_RESULT_FILE_BASENAME"

REMOTE_RESULT_DIR="/data/data/${PACKAGE}/files/home/.termux-setup-results"
REMOTE_RESULT_FILE="${REMOTE_RESULT_DIR}/result.txt"
LOCAL_RESULT_DIR="$(mktemp -d "/tmp/termux-setup-results.XXXXXXXXXX")"
LOCAL_RESULT_FILE="${LOCAL_RESULT_DIR}/result.txt"
LOCAL_SSH_PRIVATE_KEY="${HOME}/.ssh/termux-emulator"
LOCAL_SSH_PUBLIC_KEY="${LOCAL_SSH_PRIVATE_KEY}.pub"
TERMUX_SSH_PUBLIC_KEY=""

cleanup() {
  rm -rf "${LOCAL_RESULT_DIR}"
}
trap cleanup EXIT

log() {
  printf '[termux-setup] %s\n' "$*"
}

fail() {
  printf '[termux-setup] ERROR: %s\n' "$*" >&2
  exit 1
}

adb_shell() {
  "${ADB}" shell "$@"
}

adb_shell_silent() {
  "${ADB}" shell "$@" >/dev/null 2>&1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

wait_until() {
  local timeout_seconds="$1"
  local description="$2"
  shift 2

  local start now
  start="$(date +%s)"

  while true; do
    if "$@"; then
      return 0
    fi

    now="$(date +%s)"
    if (( now - start >= timeout_seconds )); then
      fail "Timed out after ${timeout_seconds}s waiting for: ${description}"
    fi

    sleep 2
  done
}

device_connected() {
  "${ADB}" get-state >/dev/null 2>&1
}

package_installed() {
  adb_shell "pm path '${PACKAGE}'" 2>/dev/null | grep -q '^package:'
}

termux_bootstrap_ready() {
  adb_shell "run-as '${PACKAGE}' sh -c 'test -x files/usr/bin/bash && test -x files/usr/bin/pkg'" >/dev/null 2>&1
}

termux_app_user() {
  adb_shell "run-as '${PACKAGE}' sh -c 'id -un'" 2>/dev/null | tr -d '\r' | head -n 1
}

result_file_exists() {
  adb_shell "run-as '${PACKAGE}' sh -c 'test -f \"${REMOTE_RESULT_FILE}\"'" >/dev/null 2>&1
}

result_file_complete() {
  result_file_exists || return 1
  adb_shell "run-as '${PACKAGE}' cat '${REMOTE_RESULT_FILE}'" 2>/dev/null | grep -q '^TERMUX_SETUP_DONE$'
}

ssh_config_value() {
  local key="$1"
  ssh -F "${HOME}/.ssh/config" -G termux-emulator 2>/dev/null | awk -v key="${key}" '$1 == key { $1 = ""; sub(/^ /, ""); print; exit }'
}

ssh_config_host_entry_exists() {
  [[ -f "${HOME}/.ssh/config" ]] || return 1

  awk '
    /^[[:space:]]*[Hh][Oo][Ss][Tt][[:space:]]+/ {
      for (i = 2; i <= NF; i++) {
        if ($i == "termux-emulator") {
          found = 1
        }
      }
    }
    END {
      exit(found ? 0 : 1)
    }
  ' "${HOME}/.ssh/config"
}

ensure_local_ssh_key() {
  mkdir -p "$(dirname "${LOCAL_SSH_PRIVATE_KEY}")"
  chmod 700 "$(dirname "${LOCAL_SSH_PRIVATE_KEY}")"

  if [[ ! -f "${LOCAL_SSH_PRIVATE_KEY}" ]]; then
    log "Generating persistent SSH key for setup login: ${LOCAL_SSH_PRIVATE_KEY}"
    ssh-keygen -t ed25519 -f "${LOCAL_SSH_PRIVATE_KEY}" -N "" -C "termux-emulator-setup" >/dev/null
    chmod 600 "${LOCAL_SSH_PRIVATE_KEY}"
  fi

  if [[ ! -f "${LOCAL_SSH_PUBLIC_KEY}" ]]; then
    log "Regenerating missing SSH public key: ${LOCAL_SSH_PUBLIC_KEY}"
    ssh-keygen -y -f "${LOCAL_SSH_PRIVATE_KEY}" > "${LOCAL_SSH_PUBLIC_KEY}"
  fi
}

ensure_emulator_ssh_host_config() {
  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"

  if ssh_config_host_entry_exists; then
    log "SSH config already contains Host termux-emulator."
    return 0
  fi

  log "Appending Host termux-emulator entry to ~/.ssh/config..."
  {
    printf '\n'
    printf '%s\n' 'Host termux-emulator'
    printf '%s\n' '  HostName localhost'
    printf '  Port %s\n' "${HOST_SSH_PORT}"
    printf '%s\n' "  IdentityFile ${LOCAL_SSH_PRIVATE_KEY}"
    printf '%s\n' "  User termux"
    printf '%s\n' '  IdentitiesOnly yes'
    printf '%s\n' '  PasswordAuthentication no'
    printf '%s\n' '  KbdInteractiveAuthentication no'
    printf '%s\n' '  StrictHostKeyChecking no'
    printf '%s\n' '  UserKnownHostsFile /dev/null'
    printf '%s\n' '  LogLevel ERROR'
  } >> "${HOME}/.ssh/config"
  chmod 600 "${HOME}/.ssh/config"
}

validate_emulator_ssh_host_config() {
  local hostname port identity_file

  hostname="$(ssh_config_value hostname)"
  port="$(ssh_config_value port)"
  identity_file="$(ssh_config_value identityfile)"

  [[ "${hostname}" == "localhost" ]] || fail "~/.ssh/config Host termux-emulator must set HostName localhost; got: ${hostname:-<unset>}"
  [[ "${port}" == "${HOST_SSH_PORT}" ]] || fail "~/.ssh/config Host termux-emulator must set Port ${HOST_SSH_PORT}; got: ${port:-<unset>}"
  [[ "${identity_file}" == "${LOCAL_SSH_PRIVATE_KEY}" ]] || fail "~/.ssh/config Host termux-emulator must set IdentityFile ${LOCAL_SSH_PRIVATE_KEY}; got: ${identity_file:-<unset>}"
}

ssh_connects_from_host() {
  [[ -n "${TERMUX_SSH_USER}" ]] || return 1
  ssh -F "${HOME}/.ssh/config" termux-emulator 'printf "TERMUX_SSH_HOST_OK\n"'
}

require_command "${ADB}"
require_command ssh
require_command ssh-keygen

[[ -f "${APK}" ]] || fail "APK not found: ${APK}. Build it first with ./gradlew assembleDebug."

log "Waiting for adb device..."
wait_until 20 "adb device connection" device_connected

log "Connected device:"
"${ADB}" devices

if package_installed; then
  log "Uninstalling existing ${PACKAGE} installation..."
  adb_shell_silent "am force-stop '${PACKAGE}'" || true
  "${ADB}" uninstall "${PACKAGE}" >/dev/null || fail "Failed to uninstall ${PACKAGE}"
else
  log "${PACKAGE} is not currently installed; skipping uninstall."
fi

log "Installing APK: ${APK}"
"${ADB}" install -g "${APK}" >/dev/null || fail "Failed to install APK"

log "Launching ${PACKAGE} to initialize bootstrap..."
adb_shell "monkey -p '${PACKAGE}' -c android.intent.category.LAUNCHER 1" >/dev/null

log "Waiting for Termux bootstrap to become available..."
wait_until "${BOOTSTRAP_TIMEOUT_SECONDS}" "Termux bootstrap files" termux_bootstrap_ready

TERMUX_SSH_USER="$(termux_app_user)"
[[ -n "${TERMUX_SSH_USER}" ]] || fail "Termux SSH user must not be empty"
log "Using Termux SSH login user: ${TERMUX_SSH_USER}"

ensure_local_ssh_key
ensure_emulator_ssh_host_config
log "Validating Host termux-emulator entry in ~/.ssh/config..."
validate_emulator_ssh_host_config
log "Using persistent SSH public key for setup login: ${LOCAL_SSH_PUBLIC_KEY}"
TERMUX_SSH_PUBLIC_KEY="$(cat "${LOCAL_SSH_PUBLIC_KEY}")"
[[ -n "${TERMUX_SSH_PUBLIC_KEY}" ]] || fail "SSH public key is empty: ${LOCAL_SSH_PUBLIC_KEY}"
log "Enabling RUN_COMMAND for external automation..."
adb_shell "run-as '${PACKAGE}' sh -c 'mkdir -p files/home/.termux && printf \"%s\n\" \"allow-external-apps=true\" > files/home/.termux/termux.properties && mkdir -p \"${REMOTE_RESULT_DIR}\" && rm -f \"${REMOTE_RESULT_FILE}\"'" >/dev/null

log "Restarting ${PACKAGE} so termux.properties is reloaded..."
adb_shell_silent "am force-stop '${PACKAGE}'" || true
adb_shell "monkey -p '${PACKAGE}' -c android.intent.category.LAUNCHER 1" >/dev/null
sleep 5

TERMUX_COMMAND="
set -eu
export DEBIAN_FRONTEND=noninteractive
export SSH_PORT=${SSH_PORT}
echo \"TERMUX_SETUP_START\"
echo \"Pinning Termux repositories to packages.termux.io...\"
mkdir -p \"\$PREFIX/etc/apt/sources.list.d\" \"\$PREFIX/etc/apt/preferences.d\" \"\$PREFIX/etc/termux/mirrors/setup\"
rm -f \"\$PREFIX/etc/apt/sources.list.d\"/*.list \"\$PREFIX/etc/apt/sources.list.d\"/*.sources
printf \"%s\n\" \"deb https://packages.termux.io/apt/termux-main stable main\" > \"\$PREFIX/etc/apt/sources.list\"
printf \"%s\n\" \"deb https://packages.termux.io/apt/termux-root root stable\" > \"\$PREFIX/etc/apt/sources.list.d/root.list\"
printf \"%s\n\" \"deb https://packages.termux.io/apt/termux-x11 x11 main\" > \"\$PREFIX/etc/apt/sources.list.d/x11.list\"
cat > \"\$PREFIX/etc/termux/mirrors/setup/packages.termux.io\" <<EOF
# This file is sourced by pkg. Keep setup-termux.sh installs on packages.termux.io.
WEIGHT=100
MAIN=\"https://packages.termux.io/apt/termux-main\"
ROOT=\"https://packages.termux.io/apt/termux-root\"
X11=\"https://packages.termux.io/apt/termux-x11\"
EOF
rm -rf \"\$PREFIX/etc/termux/chosen_mirrors\"
ln -s \"\$PREFIX/etc/termux/mirrors/setup/packages.termux.io\" \"\$PREFIX/etc/termux/chosen_mirrors\"
cat > \"\$PREFIX/etc/apt/preferences.d/termux-setup-pinned-repos\" <<EOF
Package: *
Pin: origin packages.termux.io
Pin-Priority: 1001
EOF
rm -rf \"\$PREFIX/var/lib/apt/lists\"/*
echo \"Updating package metadata...\"
pkg update
echo \"Installing OpenSSH...\"
pkg install -y openssh
echo \"Configuring sshd for setup key login with password logins disabled...\"
mkdir -p \"\$PREFIX/etc/ssh\" \"\$HOME/.ssh\" \"\$PREFIX/var/run\"
ssh-keygen -A
printf \"%s\n\" \"${TERMUX_SSH_PUBLIC_KEY}\" > \"\$HOME/.ssh/authorized_keys\"
chmod 700 \"\$HOME/.ssh\"
chmod 600 \"\$HOME/.ssh/authorized_keys\"
cat > \"\$PREFIX/etc/ssh/sshd_config\" <<EOF
Port \${SSH_PORT}
ListenAddress 0.0.0.0
AllowUsers ${TERMUX_SSH_USER}
PidFile \${PREFIX}/var/run/sshd.pid
PasswordAuthentication no
PermitEmptyPasswords no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
PrintMotd no
Subsystem sftp \${PREFIX}/libexec/sftp-server
EOF
pkill sshd >/dev/null 2>&1 || true
sshd -f \"\$PREFIX/etc/ssh/sshd_config\" -E \"\$HOME/.termux-setup-sshd.log\"
echo \"sshd listening on port \${SSH_PORT}\"
echo \"TERMUX_SETUP_DONE\"
"

log "Starting RUN_COMMAND setup command with timeout ${COMMAND_TIMEOUT_SECONDS}s..."
adb_shell \
  "run-as '${PACKAGE}' am startservice --user 0 \
    -a '${RUN_COMMAND_ACTION}' \
    -n '${PACKAGE}/.app.RunCommandService' \
    --es '${RUN_COMMAND_PATH_EXTRA}' '/data/data/${PACKAGE}/files/usr/bin/bash' \
    --esa '${RUN_COMMAND_ARGUMENTS_EXTRA}' '-lc','${TERMUX_COMMAND}' \
    --es '${RUN_COMMAND_WORKDIR_EXTRA}' '/data/data/${PACKAGE}/files/home' \
    --es '${RUN_COMMAND_RUNNER_EXTRA}' 'app-shell' \
    --es '${RUN_COMMAND_RESULT_DIRECTORY_EXTRA}' '${REMOTE_RESULT_DIR}' \
    --ez '${RUN_COMMAND_RESULT_SINGLE_FILE_EXTRA}' true \
    --es '${RUN_COMMAND_RESULT_FILE_BASENAME_EXTRA}' 'result.txt'" >/dev/null

log "Waiting for Termux command to finish..."
wait_until "${COMMAND_TIMEOUT_SECONDS}" "RUN_COMMAND result completion" result_file_complete

log "Forwarding host port ${HOST_SSH_PORT} to device SSH port ${SSH_PORT}..."
"${ADB}" forward "tcp:${HOST_SSH_PORT}" "tcp:${SSH_PORT}" >/dev/null || fail "Failed to forward SSH port"

log "Testing SSH connectivity from host..."
wait_until "${SSH_CONNECT_TIMEOUT_SECONDS}" "host SSH connection to Termux sshd" ssh_connects_from_host

log "Pulling result..."
adb_shell "run-as '${PACKAGE}' cat '${REMOTE_RESULT_FILE}'" > "${LOCAL_RESULT_FILE}"

printf '\n========== Termux setup result ==========\n'
cat "${LOCAL_RESULT_FILE}"
printf '==============================================\n\n'

if grep -q '^TERMUX_SETUP_DONE$' "${LOCAL_RESULT_FILE}"; then
  log "Setup completed successfully, including host SSH connectivity."
else
  fail "Setup result did not contain completion marker."
fi
