#!/bin/sh

set -e

# VARIABLES
IMG_NAME="registry.kyso.io/docker/mysecureshell/main"
CNAME="myssh"

# RUNTIME VARIABLES
SCRIPT="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT")"
WORK_DIR="$(readlink -f "$SCRIPT_DIR/..")"

HOST_KEYS="host_keys.txt"
USER_KEYS="user_keys.txt"
USER_PASS="user_pass.txt"
USERS_TAR="user_data.tar"

DOCKER_SFTP_PATH="/sftp"
DOCKER_FILES_DIR="/fileSecrets"
DOCKER_HOST_KEYS="$DOCKER_FILES_DIR/$HOST_KEYS"
DOCKER_USER_KEYS="$DOCKER_FILES_DIR/$USER_KEYS"
DOCKER_USER_PASS="$DOCKER_FILES_DIR/$USER_PASS"

SERVER_SFTP_PATH="$WORK_DIR/sftp"
SERVER_FILES_DIR="$WORK_DIR/fileSecrets"
SERVER_HOST_KEYS="$SERVER_FILES_DIR/$HOST_KEYS"
SERVER_USER_KEYS="$SERVER_FILES_DIR/$USER_KEYS"
SERVER_USER_PASS="$SERVER_FILES_DIR/$USER_PASS"
SERVER_USERS_TAR="$SERVER_FILES_DIR/$USERS_TAR"

MYSSH_PORT="${MYSSH_PORT:=2022}"

# FUNCTIONS
_build() {
  cd "$WORK_DIR"
  docker build --build-arg "$(cat .build-args)" -t "$IMG_NAME" .
}

_pull() {
  # pull latest image
  docker pull "$IMG_NAME"
  # remove dangling images
  for _img in $(docker images --filter "dangling=true" -q "$IMG_NAME"); do
    docker rmi "${_img}" || true
  done
}

_init() {
  if [ ! -d "$SERVER_SFTP_PATH" ]; then
    mkdir "$SERVER_SFTP_PATH"
  fi
  if [ ! -d "$SERVER_FILES_DIR" ]; then
    mkdir "$SERVER_FILES_DIR"
  fi
  if [ ! -f "$SERVER_HOST_KEYS" ]; then
    docker run --rm "$IMG_NAME" host-keys >"$SERVER_HOST_KEYS"
  fi
  if [ ! -f "$SERVER_USER_PASS" ]; then
    if [ -n "$#" ]; then
      docker run --rm "$IMG_NAME" users-tar "$@" >"$SERVER_USERS_TAR"
    else
      docker run --rm "$IMG_NAME" users-tar "$(id -un)" \
        >"$SERVER_USERS_TAR"
    fi
    if [ -s "$SERVER_USERS_TAR" ]; then
      cd "$SERVER_FILES_DIR"
      tar xf "$SERVER_USERS_TAR" user_keys.txt user_pass.txt
    fi
  fi
}

_host_keys() {
  docker run --rm "$IMG_NAME" host-keys
}

_utar() {
  docker run --rm "$IMG_NAME" users-tar "$@"
}

_run() {
  if [ ! -f "$SERVER_HOST_KEYS" ] || [ ! -f "$SERVER_USER_PASS" ]; then
    echo "Required files missing, call '$0 init USERS_LIST' to create them"
    return 1
  fi
  docker run --detach \
    --cap-add "IPC_OWNER" \
    --publish "$MYSSH_PORT:22" \
    --env MYSSH_SFTP_UID="${MYSSH_SFTP_UID}" \
    --env MYSSH_SFTP_GID="${MYSSH_SFTP_GID}" \
    --env MYSSH_HOST_KEYS="${HOST_KEYS}" \
    --env MYSSH_USER_KEYS="${USER_KEYS}" \
    --env MYSSH_USER_PASS="${USER_PASS}" \
    --volume "$SERVER_SFTP_PATH:$DOCKER_SFTP_PATH:rw,z" \
    --volume "$SERVER_HOST_KEYS:$DOCKER_HOST_KEYS:ro,z" \
    --volume "$SERVER_USER_KEYS:$DOCKER_USER_KEYS:ro,z" \
    --volume "$SERVER_USER_PASS:$DOCKER_USER_PASS:ro,z" \
    --restart always \
    --name "$CNAME" \
    "$IMG_NAME" "$@"
}

_logs() {
  docker logs "${CNAME}" "$@"
}

_ps_status() {
  docker ps -a -f name="${CNAME}" --format '{{.Status}}' 2>/dev/null || true
}

_inspect_status() {
  docker inspect ${CNAME} -f "{{.State.Status}}" 2>/dev/null || true
}

_status() {
  _st="$(_ps_status)"
  if [ -z "$_st" ]; then
    echo "The container '${CNAME}' does not exist"
    exit 1
  else
    echo "$_st"
  fi
}

_start() {
  _st="$(_inspect_status)"
  if [ -z "$_st" ]; then
    _run "$@"
  elif [ "$_st" != "running" ] && [ "$_st" != "restarting" ]; then
    docker start "${CNAME}"
  fi
}

_stop() {
  _st="$(_inspect_status)"
  if [ "$_st" = "running" ] || [ "$_st" = "restarting" ]; then
    docker stop "${CNAME}"
  fi
}

_restart() {
  _stop
  _start "$@"
}

_rm() {
  _st="$(_inspect_status)"
  if [ -n "$_st" ]; then
    _stop
    docker rm "${CNAME}"
  fi
}

_exec() {
  docker exec -ti "${CNAME}" "$@"
}

_usage() {
  cat <<EOF
Usage: $0 {start|stop|status|restart|rm|logs|exec|build|pull|init|hkeys|utar}
EOF
  exit 0
}

# ====
# MAIN
# ====
case "$1" in
start)
  shift
  _start "$@"
  ;;
stop) _stop ;;
status) _status ;;
restart)
  shift
  _restart "$@"
  ;;
rm) _rm ;;
logs)
  shift
  _logs "$@"
  ;;
exec)
  shift
  _exec "$@"
  ;;
build) _build ;;
pull) _pull ;;
init)
  shift
  _init "$@"
  ;;
hkeys)
  shift
  _host_keys
  ;;
utar)
  shift
  _utar "$@"
  ;;
*) _usage ;;
esac

# vim: ts=2:sw=2:et
