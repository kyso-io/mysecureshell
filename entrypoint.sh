#!/bin/sh

set -e

# ---------
# VARIABLES
# ---------

# DEFAULT VALUES
DEFAULT_HOST_KEYS="host_keys.txt"
DEFAULT_USER_KEYS="user_keys.txt"
DEFAULT_USER_PASS="user_pass.txt"
DEFAULT_USER_SIDS="user_sids.tgz"
DEFAULT_SECRET_NAME="mysecureshell-secrets"
# DEFAULT_SFTP_UID="" # computed running 'stat -c "%u" "$BASE_DIR"'
# DEFAULT_SFTP_GID="" # computed running 'stat -c "%g" "$BASE_DIR"'
DEFAULT_SSH_PORT="22"

# DIRECTORIES
BASE_DIR="/sftp"
CONF_DIR="/fileSecrets"
HOME_DIR="${BASE_DIR}/data"

# FILE NAMES
HOST_KEYS="${MYSSH_HOST_KEYS:=$DEFAULT_HOST_KEYS}"
USER_KEYS="${MYSSH_USER_KEYS:=$DEFAULT_USER_KEYS}"
USER_PASS="${MYSSH_USER_PASS:=$DEFAULT_USER_PASS}"
USER_SIDS="${MYSSH_USER_SIDS:=$DEFAULT_USER_SIDS}"

# FILE PATHS
HOST_KEYS_PATH="$CONF_DIR/$HOST_KEYS"
USER_KEYS_PATH="$CONF_DIR/$USER_KEYS"
USER_PASS_PATH="$CONF_DIR/$USER_PASS"

# KUBERNETES OBJECT NAMES
SECRET_NAME="${MYSSH_SECRET_NAME:=$DEFAULT_SECRET_NAME}"

# SFTP UID/GID
SFTP_UID="${MYSSH_SFTP_UID:=$(stat -c "%u" "$BASE_DIR" 2>/dev/null)}" || true
SFTP_GID="${MYSSH_SFTP_GID:=$(stat -c "%g" "$BASE_DIR" 2>/dev/null)}" || true

# SSH_PARAMS
SSH_PARAMS="-D -e -p ${MYSSH_SSH_PORT:=$DEFAULT_SSH_PORT}"

# FIXED VALUES

HOST_KEY_TYPES="dsa ecdsa ed25519 rsa"
AUTH_KEYS_PATH="/etc/ssh/auth_keys"
USER_SHELL_CMD="/usr/bin/mysecureshell"
KUBECTL="/usr/local/bin/kubectl"

# ---------
# FUNCTIONS
# ---------

# Private / Auxiliary Functions
# .............................

# Validate SFTP_UID and SFTP_GID
_check_ugids() {
  # Check SFTP_UID
  if [ "$SFTP_UID" -eq "0" ]; then
    echo "The 'SFTP_UID' can't be 0, adjust variable or '$BASE_DIR' owner"
    exit 1
  fi
  # Check SFTP_GID
  if [ "$SFTP_GID" -eq "0" ]; then
    echo "The 'SFTP_GID' can't be 0, adjust variable or '$BASE_DIR' group"
    exit 1
  fi
}

# Create new versions of the host keys on '$(pwd)/etc/ssh'
_new_host_keys() {
  mkdir -p ./etc/ssh
  ssh-keygen -A -f . >/dev/null
  sed -i -e 's/@.*$/@mysecureshell/' ./etc/ssh/ssh_host_*_key.pub
}

# Print the host keys in mime format
_print_host_keys() {
  makemime ./etc/ssh/ssh_host_*
}

# Print the JSON version of the kubernetes secret that includes our
# configuration files from the current directory
_print_k8s_secret() {
  $KUBECTL --dry-run=client -o json create secret generic "$SECRET_NAME" \
    --from-file="$HOST_KEYS=$HOST_KEYS" \
    --from-file="$USER_KEYS=$USER_KEYS" \
    --from-file="$USER_PASS=$USER_PASS" \
    --from-file="$USER_SIDS=$USER_SIDS"
}

# Restore the configuration files on the current working directory reading
# their contents from the kubernetes secret passed as argument
_restore_k8s_host_keys() {
  _secret="$1"
  _file="$HOST_KEYS"
  _jsonpath=".data.$(echo "$_file" | sed -e 's%\.%\\.%g')"
  $KUBECTL get "$_secret" -o jsonpath="{ $_jsonpath }" | base64 -d >"$_file"
}

_restore_k8s_user_data() {
  _secret="$1"
  # Dump all files, note that we have to escape dots on the file names for
  # the jsonpath (i.e. .data.file\.with\.dots)
  for _file in "$USER_KEYS" "$USER_PASS" "$USER_SIDS"; do
    _jsonpath=".data.$(echo "$_file" | sed -e 's%\.%\\.%g')"
    $KUBECTL get "$_secret" -o jsonpath="{ $_jsonpath }" | base64 -d >"$_file"
  done
}

# Create missing user home directories, if nothing has changed nothing is done
_setup_home_dirs() {
  # Check the main home directory
  if [ ! -d "$HOME_DIR" ]; then
    mkdir "$HOME_DIR"
    # Make sure the data dir can be managed by the sftp user
    chown "$SFTP_UID:$SFTP_GID" "$HOME_DIR"
    chmod 0555 "$HOME_DIR"
  fi
  # Get the list of new users
  _new_users="$(
    sed -n -e '/^[^#]/{ s/:.*$//p }' "$USER_PASS_PATH" | while read -r _u; do
      [ -d "$HOME_DIR/$_u" ] || echo "$_u"
    done
  )"
  # Create folders for new users
  if [ "$_new_users" ]; then
    # Allow the user (and root) to create directories inside the $HOME_DIR, if
    # we don't allow it the directory creation fails on EFS (AWS)
    chmod 0755 "$HOME_DIR"
    # Create home directories for new users
    echo "$_new_users" | while read -r _u; do
      mkdir "$HOME_DIR/$_u"
      chown "$SFTP_UID:$SFTP_GID" "$HOME_DIR/$_u"
      chmod 0755 "$HOME_DIR/$_u"
    done
    # Disable write permission on the directory to forbid remote sftp users to
    # remove their own root dir (they have already done it); we adjust that
    # here to avoid issues with EFS (see before)
    chmod 0555 "$HOME_DIR"
  fi
}

# Restore host keys from the mime file
_setup_host_keys() {
  opwd="$(pwd)"
  tmpdir="$(mktemp -d)"
  cd "$tmpdir"
  _ret="0"
  reformime <"$HOST_KEYS_PATH" || _ret="$?"
  for _kt in $HOST_KEY_TYPES; do
    key="ssh_host_${_kt}_key"
    pub="ssh_host_${_kt}_key.pub"
    if [ ! -f "$key" ]; then
      echo "Missing '$key' file"
      _ret="1"
    fi
    if [ ! -f "$pub" ]; then
      echo "Missing '$pub' file"
      _ret="1"
    fi
    if [ "$_ret" -ne "0" ]; then
      continue
    fi
    cat "$key" >"/etc/ssh/$key"
    chmod 0600 "/etc/ssh/$key"
    chown root:root "/etc/ssh/$key"
    cat "$pub" >"/etc/ssh/$pub"
    chmod 0600 "/etc/ssh/$pub"
    chown root:root "/etc/ssh/$pub"
  done
  cd "$opwd"
  rm -rf "$tmpdir"
  return "$_ret"
}

# Create missing /etc/passwd entries for ssh users on the container
_setup_new_users() {
  opwd="$(pwd)"
  tmpdir="$(mktemp -d)"
  cd "$tmpdir"
  _ret="0"
  # Create users file
  : >"newusers.txt"
  # Add the sftp user if missing
  if [ -z "$(getent passwd sftp)" ]; then
    echo "sftp:sftp:$SFTP_UID:$SFTP_GID:::/bin/false" >"newusers.txt"
  fi
  # Add other users if missing
  sed -n -e '/^[^#]/{ s/:/ /p }' "$USER_PASS_PATH" | while read -r _u _p; do
    if [ -z "$(getent passwd "$_u")" ]; then
      echo "$_u:$_p:$SFTP_UID:$SFTP_GID::$HOME_DIR/$_u:$USER_SHELL_CMD"
    fi
  done >>"newusers.txt"
  if [ -s "newusers.txt" ]; then
    newusers --badnames newusers.txt || _ret="$?"
  fi
  # Clean up the tmpdir
  cd "$opwd"
  rm -rf "$tmpdir"
  return "$_ret"
}

# Adjust user keys
_setup_user_keys() {
  # Remove old key files, if there are any
  find "$AUTH_KEYS_PATH" -type f -exec rm {} \;
  # Create new key files
  sed -n -e '/^[^#]/{ s/:/ /p }' "$USER_KEYS_PATH" | while read -r _u _k; do
    echo "$_k" >>"$AUTH_KEYS_PATH/$_u"
  done
}

# Setup sshd daemon and exececute it
_sshd_exec() {
  _setup_host_keys
  _setup_new_users
  _setup_user_keys
  echo "Running: /usr/sbin/sshd $SSH_PARAMS"
  # shellcheck disable=SC2086
  exec /usr/sbin/sshd -D $SSH_PARAMS
}

# Update user files (passwords and keys), adding and removing users while
# keeping the data for the existing ones, if any. Fails if called without a
# list of usernames as an argument
_update_user_files() {
  [ "$#" -gt "0" ] || return 1
  # Use a variable to mark if users have been updated or not
  UPDATED_USERS="false"
  # We assume that if '$USER_PASS' exists it has all the valid users
  if [ -f "$USER_PASS" ]; then
    # Generate a sorted list of the old users
    _old_users_file="$(mktemp)"
    # Generate a sorted list of the new users
    sed -n -e '/^[^#]/{ s/:.*$//p }' "$USER_PASS" | sort >"$_old_users_file"
    _new_users_file="$(mktemp)"
    for _u in "$@"; do echo "$_u"; done | sort >"$_new_users_file"
    # Get the lists of deleted users, new users and old users
    _del_users="$(comm -23 "$_old_users_file" "$_new_users_file")"
    _new_users="$(comm -13 "$_old_users_file" "$_new_users_file")"
    _old_users="$(comm -12 "$_old_users_file" "$_new_users_file")"
    # Remove sorted user lists files
    rm -f "$_old_users_file" "$_new_users_file"
    # If we have no new or deleted users we are done
    if [ -z "$_del_users" ] && [ -z "$_new_users" ]; then
      return 0
    fi
    # Check if we are going to remove users
    if [ "$_del_users" ]; then
      # Remove password entries for deleted users if they exist
      for _u in $_del_users; do
        if [ "$(getent passwd "$_u")" ]; then
          deluser "$_u" || true
        fi
      done
      # If we have old users leave them on USER_PASS_PATH & USER_KEYS_PATH, if
      # not leave the files empty
      if [ "$_old_users" ]; then
        for _file in "$USER_PASS" "$USER_KEYS"; do
          if [ -f "$_file" ]; then
            mv "$_file" "$_file.orig"
            for _u in $_old_users; do echo "^$_u:"; done >"$_file.patterns"
            grep -f "$_file.patterns" "$_file.orig" >"$_file"
            rm -f "$_file.orig" "$_file.patterns"
          fi
        done
      else
        : >"$USER_PASS"
        : >"$USER_KEYS"
      fi
    fi
    # Extract old users keys, if available (the keys will not be re-generated
    # if missing)
    if [ "$_old_users" ]; then
      for _u in $_old_users; do
        tar axf "$USER_SIDS" "id_ed25519-$_u" "id_rsa-$_u" "id_rsa-$_u.pem" ||
          true
      done
    fi
    # Remove original USER_SIDS
    rm -f "$USER_SIDS"
  else
    _new_users="$*"
    : >"$USER_PASS"
    : >"$USER_KEYS"
    rm -f "$USER_SIDS"
  fi
  for _u in $_new_users; do
    ssh-keygen -q -a 100 -t ed25519 -f "id_ed25519-$_u" -C "$_u" -N ""
    ssh-keygen -q -a 100 -b 4096 -t rsa -f "id_rsa-$_u" -C "$_u" -N ""
    # Legacy RSA private key format
    cp -a "id_rsa-$_u" "id_rsa-$_u.pem"
    ssh-keygen -q -p -m pem -f "id_rsa-$_u.pem" -N "" -P "" >/dev/null
    chmod 0600 "id_rsa-$_u.pem"
    echo "$_u:$(pwgen -s 16 1)" >>"$USER_PASS"
    echo "$_u:$(cat "id_ed25519-$_u.pub")" >>"$USER_KEYS"
    echo "$_u:$(cat "id_rsa-$_u.pub")" >>"$USER_KEYS"
  done
  tar acf "$USER_SIDS" id_* 2>/dev/null
  rm -f id_*
  UPDATED_USERS="true"
}

# Public functions
# ................

# Initialise or update configuration data (host keys and user files)
do_init() {
  # Check user and group ids
  _check_ugids
  # Check user files and arguments
  if [ "$#" -eq "0" ] && [ ! -f "$USER_PASS_PATH" ]; then
    echo "No usernames were given and the '$USER_PASS_PATH' file is missing!"
    echo "Pass a list of usernames to this command to create it."
    return 1
  fi
  # Re-generate host keys if the file does not exist
  if [ ! -f "$HOST_KEYS_PATH" ]; then
    opwd="$(pwd)"
    cd /
    _new_host_keys
    _print_host_keys >"$HOST_KEYS_PATH"
    cd "$opwd"
  fi
  # Update the user files if we received arguments (we already know that the
  # '$USER_PASS_PATH' file exists)
  if [ "$#" -gt "0" ]; then
    opwd="$(pwd)"
    cd "$CONF_DIR"
    _update_user_files "$@"
    cd "$opwd"
  fi
}

# Run the sshd on the container
do_sshd() {
  do_init "$@"
  _setup_home_dirs
  _sshd_exec
}

# Setup the "CONF_DIR" using a kubernetes secret and update it if the
# LIST_OF_USERS was changed; if the secret does not exist and we get the
# LIST_OF_USERS we create the files and add the secret to kubernetes
k8s_init() {
  _secret="secret/$SECRET_NAME"
  _check_ugids
  opwd="$(pwd)"
  cd "$CONF_DIR"
  _ret="0"
  # Get secret or see if we have to create files
  if $KUBECTL get "$_secret" >/dev/null 2>&1; then
    echo "Secret '$SECRET_NAME' found, extracting files to '$CONF_DIR'"
    _restore_k8s_host_keys "$_secret" || _ret="$?"
    _restore_k8s_user_data "$_secret" || _ret="$?"
    # Check user files and arguments
    if [ "$#" -eq "0" ] && [ ! -f "$USER_PASS_PATH" ]; then
      echo "No usernames were given and the '$USER_PASS_PATH' file is missing!"
      echo "Pass a list of usernames to this command to create it."
      return 1
    fi
    UPDATED_HOSTS="false"
    if [ ! -f "$HOST_KEYS_PATH" ]; then
      cd /
      _new_host_keys || _ret="$?"
      _print_host_keys >"$HOST_KEYS_PATH" || _ret="$?"
      cd "$CONF_DIR"
      UPDATED_HOSTS="true"
    fi
    UPDATED_USERS="false"
    # Update the user files if we received arguments (we already know that the
    # '$USER_PASS' file exists)
    if [ "$#" -gt "0" ]; then
      _update_user_files "$@" || _ret="$?"
    fi
    if [ "$UPDATED_HOSTS" = "true" ] || [ "$UPDATED_USERS" = "true" ]; then
      echo "Files were changed, updating '$_secret' on kubernetes"
      _print_k8s_secret "$@" | $KUBECTL apply -f - || _ret="$?"
    fi
  elif [ "$#" -gt "0" ]; then
    echo "Secret '$SECRET_NAME' NOT found, creating files on '$CONF_DIR'"
    cd /
    _new_host_keys || _ret="$?"
    _print_host_keys >"$HOST_KEYS_PATH" || _ret="$?"
    cd "$CONF_DIR"
    _update_user_files "$@" || _ret="$?"
    echo "Adding '$_secret' to kubernetes"
    _print_k8s_secret "$@" | $KUBECTL apply -f - || _ret="$?"
  else
    echo "Secret '$SECRET_NAME' NOT found, create it or pass a list of users"
    return 1
  fi
  cd "$opwd"
  _setup_home_dirs
  return "$_ret"
}

# Execute sshd on a kubernetes pod, only useful when not using init containers
k8s_sshd() {
  k8s_init "$@"
  _sshd_exec
}

# Create host keys on a temporary folder and return them in mime format
new_host_keys() {
  opwd="$(pwd)"
  tmpdir="$(mktemp -d)"
  cd "$tmpdir"
  _ret="0"
  _new_host_keys || _ret="$?"
  _print_host_keys || _ret="$?"
  cd "$opwd"
  rm -rf "$tmpdir"
  return "$_ret"
}

# Create host keys and user data on a temporary folder and print them as a
# kubernetes secret in json format
new_k8s_secret() {
  [ "$#" -gt "0" ] || return 1
  opwd="$(pwd)"
  tmpdir="$(mktemp -d)"
  cd "$tmpdir"
  _ret="0"
  _new_host_keys || _ret="$?"
  _print_host_keys >"$HOST_KEYS" || _ret="$?"
  _update_user_files "$@" || _ret="$?"
  _print_k8s_secret || _ret="$?"
  cd "$opwd"
  rm -rf "$tmpdir"
  return "$_ret"
}

# Return a tar file with new host keys and user data files (needs LIST_OF_USERS)
new_users_tar() {
  [ "$#" -gt "0" ] || return 1
  opwd="$(pwd)"
  tmpdir="$(mktemp -d)"
  cd "$tmpdir"
  _ret="0"
  _update_user_files "$@" || _ret="$?"
  tar cf - "$USER_PASS" "$USER_KEYS" "$USER_SIDS" 2>/dev/null || _ret="$?"
  cd "$opwd"
  rm -rf "$tmpdir"
  return "$_ret"
}

# Export existing host keys in mime format
print_host_keys() {
  (cd / && _print_host_keys)
}

# Export host keys and user data files as a kubernetes secret in json format
print_k8s_secret() {
  opwd="$(pwd)"
  cd "$CONF_DIR"
  _ret="0"
  if [ -f "$HOST_KEYS" ] && [ -f "$USER_PASS" ] && [ -f "$USER_KEYS" ] &&
    [ -f "$USER_SIDS" ]; then
    _print_k8s_secret
  else
    _ret="1"
  fi
  cd "$opwd"
  return "$_ret"
}

# Export user data files in a tar file
print_users_tar() {
  opwd="$(pwd)"
  cd "$CONF_DIR"
  _ret="0"
  if [ -f "$USER_PASS" ] && [ -f "$USER_KEYS" ] && [ -f "$USER_SIDS" ]; then
    tar cf - "$USER_PASS" "$USER_KEYS" "$USER_SIDS" 2>/dev/null || _ret="$?"
  else
    _ret="1"
  fi
  cd "$opwd"
  return "$_ret"
}

# Create new versions of the host keys and reload the sshd daemon
update_host_keys() {
  opwd="$(pwd)"
  cd /
  echo "Creating new host keys"
  _new_host_keys
  _print_host_keys >"$HOST_KEYS_PATH"
  cd "$opwd"
  echo "Reloading the sshd process"
  _sshd_pid="$(pidof sshd)"
  if [ "$_sshd_pid" ]; then
    kill -HUP "$_sshd_pid"
  fi
}

# Update the list of users using the passed list, save the updated
# configuration data and export the secret
update_k8s_users() {
  [ "$#" -gt "0" ] || return 1
  if [ ! -f "$USER_PASS_PATH" ]; then
    echo "The '$USER_PASS_PATH' file is missing!"
    echo "Call the 'k8s-init' command to update the existing one or create it."
    return 1
  fi
  opwd="$(pwd)"
  cd "$CONF_DIR"
  _update_user_files "$@"
  if [ "$UPDATED_USERS" = "true" ]; then
    echo "User data was modified, updating '$_secret' on kubernetes"
    _print_k8s_secret "$@" | $KUBECTL apply -f -
    echo "Setting up the users"
    _setup_new_users
    _setup_user_keys
    echo "Reloading the sshd process"
    _sshd_pid="$(pidof sshd)"
    if [ "$_sshd_pid" ]; then
      kill -HUP "$_sshd_pid"
    fi
  fi
}

# Update the list of users using the passed list and reload the sshd daemon
update_user_data() {
  [ "$#" -gt "0" ] || return 1
  _update_user_files "$@"
  if [ "$UPDATED_USERS" = "true" ]; then
    echo "User data was modified"
    echo "Setting up the users"
    _setup_new_users
    _setup_user_keys
    echo "Reloading the sshd process"
    _sshd_pid="$(pidof sshd)"
    if [ "$_sshd_pid" ]; then
      kill -HUP "$_sshd_pid"
    fi
  fi
}

usage() {
  MORE="--exit-on-eof" more <<EOF
Usage: $0 COMMAND [ARGS]

Where COMMAND can be:

- init [LIST_OF_USERS]: create or update host keys and user data on the
  /fileSecrets directory (if there are no files we need the LIST_OF_USERS to
  create new ones). The home directories of removed users are not deleted.

- sshd [LIST_OF_USERS]: call the init command, create missing home directories
  and start the ssh daemon.

- k8s-init [LIST_OF_USERS]: create secret if does not exist (needs the
  LIST_OF_USERS), restore it into the /fileSecrets directory updating the
  user data and the secret and create the home directory for new users (old
  users dissapear, but their home directories are not deleted).

- k8s-sshd [LIST_OF_USERS]: calls k8s-init and starts the ssh daemon.

- new-host-keys: create new sshd host keys and return them in mime format.

- new-k8s-secret LIST_OF_USERS: create new host-keys and user-data for the
  LIST_OF_USERS and return them in a kubernetes secret in json format.

- new-users-tar LIST_OF_USERS: create a new set of user data files for the
  LIST_OF_USERS and export them in a .tar file sent to stdout.

- print-host-keys: print current sshd host keys in mime format.

- print-k8s-secret: print current host-keys and user-data in a k8s secret in
  json format.

- print-users-tar: export current user data in a .tar file sent to stdout

- update-host-keys: create new sshd host keys, export them and reload the sshd
  daemon if running (requires write permission on /fileSecrets)

- update-k8s-users LIST_OF_USERS: add or remove users from the user data,
  update the secret and reload the sshd daemon (writes on /fileSecrets)

- update-user-data LIST_OF_USERS: add or remove users from the user data and
  reload the sshd daemon if running (writes on /fileSecrets)

- variables: print the list of environment variables that can be overriden with
  their description and default value.

If any other command is passed it is executed with 'exec'
EOF
}

vars() {
  MORE="--exit-on-eof" more <<EOF
Script variables
================

- MYSSH_HOST_KEYS ['$DEFAULT_HOST_KEYS']:

  Name of the MIME file that contains the ssh server host keys

- MYSSH_USER_KEYS ['$DEFAULT_USER_KEYS']:

  Name of the file that contais the public ssh user's keys

- MYSSH_USER_PASS ['$DEFAULT_USER_PASS']:

  Name of a file that contais username:plaintext-password lines

- MYSSH_USER_SIDS ['$DEFAULT_USER_SIDS']:

  Name of a tarfile that contains the previous two files and the private ssh
  keys of the generated users

- MYSSH_SECRET_NAME ['$DEFAULT_SECRET_NAME']:

  Name of the kubernetes secret that contais the config files (previous four)

- MYSSH_SFTP_UID ['owner of the /sftp dir']:

  UID of the files managed by the SFTP server

- MYSSH_SFTP_GID ['group of the /sftp dir']:

  GID of the files managed by the SFTP server

- MYSSH_SSH_PORT ['$DEFAULT_SSH_PORT']:

  Port used by the SFTP server, no real need to change it

EOF
}

# ----
# MAIN
# ----

case "$1" in
"") usage ;;
"vars") vars ;;
"init") shift && do_init "$@" ;;
"sshd") shift && do_sshd "$@" ;;
"k8s-sshd") shift && k8s_sshd "$@" ;;
"k8s-init") shift && k8s_init "$@" ;;
"new-host-keys") new_host_keys ;;
"new-k8s-secret") shift && new_k8s_secret "$@" ;;
"new-users-tar") shift && new_users_tar "$@" ;;
"print-host-keys") print_host_keys ;;
"print-k8s-secret") print_k8s_secret ;;
"print-users-tar") shift && print_users_tar "$@" ;;
"update-host-keys") update_host_keys ;;
"update-k8s-users") shift && update_k8s_users "$@" ;;
"update-user-data") shift && update_user_data "$@" ;;
*) exec "$@" ;;
esac

# vim: ts=2:sw=2:et
