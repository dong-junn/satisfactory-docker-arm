#!/bin/sh

IMAGE=$(
  sed -nE "s/^[[:space:]]*image:[[:space:]]*['\"]([^'\"]+)['\"][[:space:]]*$/\1/p" \
    docker-compose.yml
)
WAIT_INTERVAL=30

if docker image inspect "$IMAGE" >/dev/null 2>&1; then
  printf '이미지가 존재합니다. 서버를 실행합니다.\n'
else
  printf '이미지가 없습니다. 이미지를 내려받고 서버를 초기화합니다.\n'
  if ! docker pull "$IMAGE"; then
    printf 'Satisfactory 서버 이미지를 내려받지 못했습니다.\n' >&2
    exit 1
  fi
fi

if ! docker compose up -d; then
  printf 'Satisfactory 서버 컨테이너를 실행하지 못했습니다.\n' >&2
  exit 1
fi

CONTAINER_ID=$(
  docker compose ps \
    --all \
    --quiet \
    "satisfactory-server"
)

if [ -z "$CONTAINER_ID" ]; then
  printf 'Satisfactory 서버 컨테이너를 찾지 못했습니다.\n' >&2
  exit 1
fi

STARTED_AT=$(
  docker inspect \
    --format '{{.State.StartedAt}}' \
    "$CONTAINER_ID"
)

while true; do
  LOGS=$(
    docker logs \
      --since "$STARTED_AT" \
      "$CONTAINER_ID" 2>&1
  )

  if printf '%s\n' "$LOGS" |
       grep -Eq "Server API listening on '?0[.]0[.]0[.]0:7777'?"; then
    printf 'Satisfactory 서버가 성공적으로 실행 중입니다.\n'
    exit 0
  fi

  if [ "$(docker inspect --format '{{.State.Running}}' "$CONTAINER_ID")" != 'true' ]; then
    printf 'Satisfactory 서버 컨테이너가 중지되었습니다.\n' >&2
    exit 1
  fi

  sleep "$WAIT_INTERVAL"
done
