#!/bin/sh

IMAGE=$(
  sed -nE "s/^[[:space:]]*image:[[:space:]]*['\"]([^'\"]+)['\"][[:space:]]*$/\1/p" \
    docker-compose.yml
)
CONTAINER_NAME=$(
  sed -nE "s/^[[:space:]]*container_name:[[:space:]]*['\"]([^'\"]+)['\"][[:space:]]*$/\1/p" \
    docker-compose.yml
)
WAIT_INTERVAL=30

if [ -z "$CONTAINER_NAME" ]; then
  printf 'docker-compose.yml 파일에서 컨테이너 이름을 가져오는데 실패했습니다. docker-compose.yml을 수정하진 않았는지 확인해주세요\n' >&2
  exit 1
fi

if docker image inspect "$IMAGE" >/dev/null 2>&1; then
  printf '이미지가 존재합니다. 서버를 실행합니다.\n'
else
  printf '이미지가 없습니다. 이미지를 내려받고 서버를 초기화합니다.\n'
  if ! docker pull "$IMAGE"; then
    printf 'Satisfactory 서버 이미지를 내려받지 못했습니다.\n' >&2
    exit 1
  fi
fi

if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  printf '서버 컨테이너가 존재합니다. 기존 컨테이너를 시작합니다.\n'
  if ! docker compose start; then
    printf 'Satisfactory 서버 컨테이너를 다시 시작하지 못했습니다.\n' >&2
    exit 1
  fi
else
  printf '서버 컨테이너가 없습니다. 새 컨테이너를 생성하고 실행합니다.\n'
  if ! docker compose up -d; then
    printf 'Satisfactory 서버 컨테이너를 실행하지 못했습니다.\n' >&2
    exit 1
  fi
fi

CONTAINER_ID=$(
  docker inspect \
    --format '{{.Id}}' \
    "$CONTAINER_NAME" 2>/dev/null
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
