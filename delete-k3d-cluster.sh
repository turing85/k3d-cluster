#!/usr/bin/env bash
set -e

k3d cluster delete local || true

docker stop quay.mirror.registry.localhost || true
docker stop docker.mirror.registry.localhost || true
docker stop local.registry.localhost || true