#!/usr/bin/env bash
set -e

docker stop local.registry.localhost || true
docker stop docker.mirror.registry.localhost || true
docker stop quay.mirror.registry.localhost || true

k3d cluster stop local || true