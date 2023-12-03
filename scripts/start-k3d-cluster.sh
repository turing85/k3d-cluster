#!/usr/bin/env bash
set -e

docker start local.registry.localhost || true
docker start docker.mirror.registry.localhost || true
docker start quay.mirror.registry.localhost || true

k3d cluster start local || true