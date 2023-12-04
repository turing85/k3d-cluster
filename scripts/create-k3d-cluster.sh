#!/usr/bin/env bash
set -e

function waitFor() {
  timeout \
    --foreground \
    --kill-after "${1}" \
    "${1}" \
    bash -c \
      "while :
        printf '.'
      do
        ${2} 1>/dev/null 2>/dev/null && break
        sleep 5
      done"
}

cd -- "$(dirname "$(readlink -f "$0")")" &> /dev/null
log_dir="../logs"
mkdir -p "${log_dir}"
rm -rf "${log_dir:?}/"

k3d_version="$(k3d --version | head -n 1 | sed 's|k3d version v\(.*\)$*|\1|g')"

mkdir -p "${log_dir}/docker"
kubectl config unset users.admin@k3d-local 1>/dev/null
kubectl config unset clusters.k3d-local 1>/dev/null
kubectl config unset contexts.k3d-local 1>/dev/null
docker run \
  --env REGISTRY_HTTP_HEADERS_Access-Control-Allow-Headers='[Authorization,Accept,Cache-Control]' \
  --env REGISTRY_HTTP_HEADERS_Access-Control-Allow-Methods='["*"]' \
  --env REGISTRY_HTTP_HEADERS_Access-Control-Allow-Origin='["*"]' \
  --env REGISTRY_HTTP_HEADERS_Access-Control-Expose-Headers='[Docker-Content-Digest]' \
  --env REGISTRY_STORAGE_DELETE_ENABLED=true \
  --name local.registry.localhost \
  --network k3d-local \
  --publish 5000:5000 \
  --volume local-registry:/var/lib/registry \
  --label app=k3d \
  --label k3d.cluster	\
  --label k3d.registry.host	\
  --label k3d.registry.hostIP=0.0.0.0 \
  --label k3d.role=registry \
  --label k3d.version="${k3d_version}" \
  --label k3s.registry.port.external=5000 \
  --label k3s.registry.port.internal=5000 \
  --restart=unless-stopped \
  --detach \
  docker.io/library/registry:2.8.2 \
  1>"${log_dir}/docker/docker_local_registry.log" \
  2>"${log_dir}/docker/docker_local_registry.err.log" \
  || docker start local.registry.localhost \
    1>"${log_dir}/docker/docker_local_registry.log" \
    2>"${log_dir}/docker/docker_local_registry.err.log"

echo "starting docker registry mirror"
docker run \
  --env REGISTRY_HTTP_HEADERS_Access-Control-Allow-Headers='[Authorization,Accept,Cache-Control]' \
  --env REGISTRY_HTTP_HEADERS_Access-Control-Allow-Methods='["*"]' \
  --env REGISTRY_HTTP_HEADERS_Access-Control-Allow-Origin='["*"]' \
  --env REGISTRY_HTTP_HEADERS_Access-Control-Expose-Headers='[Docker-Content-Digest]' \
  --env REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io \
  --name docker.mirror.registry.localhost \
  --network k3d-local \
  --publish 5001:5000 \
  --volume docker-mirror-registry:/var/lib/registry \
  --label app=k3d \
  --label k3d.cluster	\
  --label k3d.registry.host	\
  --label k3d.registry.hostIP=0.0.0.0 \
  --label k3d.role=registry \
  --label k3d.version="${k3d_version}" \
  --label k3s.registry.port.external=5000 \
  --label k3s.registry.port.internal=5000 \
  --restart=unless-stopped \
  --detach \
  docker.io/library/registry:2.8.2 \
  1>"${log_dir}/docker/docker_docker_registry.log" \
  2>"${log_dir}/docker/docker_docker_registry.err.log" \
  || docker start docker.mirror.registry.localhost \
    1>"${log_dir}/docker/docker_docker_registry.log" \
    2>"${log_dir}/docker/docker_docker_registry.err.log" \

echo "starting quay registry mirror"
docker run \
  --env REGISTRY_HTTP_HEADERS_Access-Control-Allow-Headers='[Authorization,Accept,Cache-Control]' \
  --env REGISTRY_HTTP_HEADERS_Access-Control-Allow-Methods='["*"]' \
  --env REGISTRY_HTTP_HEADERS_Access-Control-Allow-Origin='["*"]' \
  --env REGISTRY_HTTP_HEADERS_Access-Control-Expose-Headers='[Docker-Content-Digest]' \
  --env REGISTRY_PROXY_REMOTEURL=https://quay.io \
  --name quay.mirror.registry.localhost \
  --network k3d-local \
  --publish 5002:5000 \
  --volume quay-mirror-registry:/var/lib/registry \
  --label app=k3d \
  --label k3d.cluster	\
  --label k3d.registry.host	\
  --label k3d.registry.hostIP=0.0.0.0 \
  --label k3d.role=registry \
  --label k3d.version="${k3d_version}" \
  --label k3s.registry.port.external=5000 \
  --label k3s.registry.port.internal=5000 \
  --restart=unless-stopped \
  --detach \
  docker.io/library/registry:2.8.2 \
  1>"${log_dir}/docker/docker_quay_registry.log" \
  2>"${log_dir}/docker/docker_quay_registry.err.log" \
  || docker start quay.mirror.registry.localhost \
    1>"${log_dir}/docker/docker_quay_registry.log" \
    2>"${log_dir}/docker/docker_quay_registry.err.log" \

echo "starting k3s"
kubectl config unset users.admin@k3d-local 1>/dev/null
kubectl config unset clusters.k3d-local 1>/dev/null
kubectl config unset contexts.k3d-local 1>/dev/null
k3d cluster create local \
  --config ../k3d-local.yml \
  --registry-config ../k3d-registry.yml \
  1>"${log_dir}/k3s.log" \
  2>"${log_dir}/k3s.err.log" \

kubeconfig="${K3D_KUBECONFIG:-${HOME}/.kube/config.k3d}"
k3d kubeconfig merge local --output "${kubeconfig}" 1>/dev/null 2>/dev/null
kubectl config use-context k3d-local 1>/dev/null

mkdir -p "${log_dir}/helm"
echo "Installing argocd through helm"
helm repo add argocd https://argoproj.github.io/argo-helm 1>/dev/null \
  || helm repo update argo-cd 1>/dev/null
helm install \
  argocd argo-cd/argo-cd \
  --values ../argocd/helm-values.yml \
  --namespace argocd \
  --create-namespace \
  1>"${log_dir}/helm/argocd.log" \
  2>"${log_dir}/helm/argocd.err.log"

echo "Installing traefik through helm"
helm repo add traefik https://traefik.github.io/charts 1>/dev/null || \
  helm repo update traefik 1>/dev/null
helm install \
  traefik traefik/traefik \
  --values ../traefik/helm-values.yml \
  --namespace traefik \
  --create-namespace \
  1>"${log_dir}/helm/traefik.log" \
  2>"${log_dir}/helm/traefik.err.log"

printf "Waiting for ArgoCD to become ready.."
waitFor 2m \
  "curl \
    --fail \
    --insecure \
    --silent \
    https://argocd.k3d.localhost"
echo " Done!"

mkdir -p "${log_dir}/argocd"
echo "Re-installing argocd through argocd"
kubectl apply \
  --kustomize ../argocd/argocd-project-system \
  --namespace argocd \
  1>"${log_dir}/argocd/argocd-project-system.log" \
  2>"${log_dir}/argocd/argocd-project-system.err.log"
kubectl apply \
  --kustomize ../argocd/argocd-application \
  --namespace argocd \
  1>"${log_dir}/argocd/argocd.log" \
  2>"${log_dir}/argocd/argocd.err.log"
printf "Waiting for ArgoCD to become ready.."
waitFor 2m \
  "curl \
    --fail \
    --insecure \
    --silent \
    https://argocd.k3d.localhost"
echo " Done!"

echo "Re-installing traefik through argocd"
kubectl apply \
  --kustomize ../traefik/argocd-application \
  --namespace argocd \
  1>"${log_dir}/argocd/traefik.log" \
  2>"${log_dir}/argocd/traefik.err.log"

echo "Installing cert-manager through argocd"
../cert-manager/certs/build-certs.sh
kubectl apply \
  --kustomize ../cert-manager/argocd-application \
  --namespace argocd \
  1>"${log_dir}/argocd/cert-manager.log" \
  2>"${log_dir}/argocd/cert-manager.err.log"
printf "Deploying Certificate chain for cert-manager.."
waitFor 2m \
  "kubectl apply \
    --kustomize ../cert-manager/certs \
    --namespace cert-manager"
echo " Done!"
kubectl apply \
  --kustomize ../cert-manager/default-tls-crt/argocd-application \
  --namespace argocd \
  1>"${log_dir}/argocd/cert-manager.log" \
  2>"${log_dir}/argocd/cert-manager.err.log"

echo "Re-installing prometheus through argocd"
kubectl apply \
  --kustomize ../prometheus/argocd-application \
  --namespace argocd \
  1>"${log_dir}/argocd/prometheus.log" \
  2>"${log_dir}/argocd/prometheus.err.log"

echo "Installing kubernetes-dashboard through argocd"
kubectl apply \
  --kustomize ../kubernetes-dashboard/argocd-application \
  --namespace argocd \
  1>"${log_dir}/argocd/kubernetes-dashboard.log" \
  2>"${log_dir}/argocd/kubernetes-dashboard.err.log"

echo "Installing UIs for image registres through argocd"
kubectl apply \
  --kustomize ../registry-ui/argocd-application \
  --namespace argocd \
  1>"${log_dir}/argocd/registry-ui.log" \
  2>"${log_dir}/argocd/registry-ui.err.log"

echo "Installing portainer through argocd"
kubectl apply \
  --kustomize ../portainer/argocd-application \
  --namespace argocd \
  1>"${log_dir}/argocd/portainer.log" \
  2>"${log_dir}/argocd/portainer.err.log"

echo
echo "Asserting that all deployed services are reachable"
urls=( \
  "https://dashboard.k3d.localhost" \
  "https://argocd.k3d.localhost" \
  "https://grafana.k3d.localhost" \
  "https://prometheus.k3d.localhost" \
  "https://traefik.k3d.localhost" \
  "https://local.registry.k3d.localhost" \
  "https://docker.registry.k3d.localhost" \
  "https://quay.registry.k3d.localhost" \
)
for url in "${urls[@]}"
do
  printf "Waiting for %s to becomen reachable.." "${url}"
  waitFor 2m \
    "curl \
      --cacert ../cert-manager/certs/ca/ca.crt \
      --fail \
      --silent \
      ${url}"
  echo " Done!"
done

echo
echo "Cluster is started up!"
echo
echo "The following Services are provided out of the box:"
echo "    https://dashboard.k3d.localhost"
echo "    https://argocd.k3d.localhost"
echo "    https://grafana.k3d.localhost (username: 'admin', password: 'prom-operator')"
echo "    https://prometheus.k3d.localhost"
echo "    https://traefik.k3d.localhost"
echo "    https://local.registry.k3d.localhost"
echo "    https://docker.registry.k3d.localhost (dockerhub mirror)"
echo "    https://quay.registry.k3d.localhost (quay.io mirror)"
echo
echo "The system  provides a registry at"
echo "    local.registry.localhost:5000"
echo
echo "If you want to deploy custom images, push them into this registry."
echo "To deploy images from this registry, reference them as local.registry.localhost:5000/<image-name>:<image-tag>"
echo
echo "All endpoints (except for the registry) are TLS-secured by default. You can find the self-signed CA certificate under"
echo "    cert-manager/certs/ca/ca.crt"
echo
echo "The kubernetes configuration has been written to"
echo "    ${kubeconfig}"
