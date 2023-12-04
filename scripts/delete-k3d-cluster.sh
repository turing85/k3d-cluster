#!/usr/bin/env bash
set -e

KUBECONFIG="${K3D_KUBECONFIG:-${HOME}/.kube/config.k3d}" 
k3d cluster delete local || true
kubectl config unset users.admin@k3d-local
kubectl config unset clusters.k3d-local
kubectl config unset contexts.k3d-local

docker stop quay.mirror.registry.localhost || true
docker stop docker.mirror.registry.localhost || true
docker stop local.registry.localhost || true