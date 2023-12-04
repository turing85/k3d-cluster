#!/usr/bin/env bash
set -e

k3d cluster stop local || true

docker stop k8s-community.mirror.registry.localhost || true
docker stop quay.mirror.registry.localhost || true
docker stop docker.mirror.registry.localhost || true
docker stop local.registry.localhost || true