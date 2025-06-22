#!/usr/bin/env bash
set -e

function wait_for() {
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

function create_registry() {
  local name="${1}"
  local host_port="${2}"
  local k3d_version="${3}"
  local log_dir="${4}"
  docker run \
    --env REGISTRY_HTTP_HEADERS_Access-Control-Allow-Headers='[Authorization,Accept,Cache-Control]' \
    --env REGISTRY_HTTP_HEADERS_Access-Control-Allow-Methods='["*"]' \
    --env REGISTRY_HTTP_HEADERS_Access-Control-Allow-Origin='["*"]' \
    --env REGISTRY_HTTP_HEADERS_Access-Control-Expose-Headers='[Docker-Content-Digest]' \
    --env REGISTRY_STORAGE_DELETE_ENABLED=true \
    --name "${name}" \
    --network k3d-local \
    --publish "${host_port}":5000 \
    --volume "${name//./_}":/var/lib/registry \
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
    1>"${log_dir}/docker/${name//./_}.log" \
    2>"${log_dir}/docker/${name//./_}.err.log" \
    || docker start "${name}" \
      1>"${log_dir}/docker/${name//./_}.log" \
      2>"${log_dir}/docker/${name//./_}.err.log"
}

function create_registry_mirror() {
  local name="${1}"
  local host_port="${2}"
  local registry_to_mirror="${3}"
  local k3d_version="${4}"
  local log_dir="${5}"
  docker run \
    --env REGISTRY_HTTP_HEADERS_Access-Control-Allow-Headers='[Authorization,Accept,Cache-Control]' \
    --env REGISTRY_HTTP_HEADERS_Access-Control-Allow-Methods='["*"]' \
    --env REGISTRY_HTTP_HEADERS_Access-Control-Allow-Origin='["*"]' \
    --env REGISTRY_HTTP_HEADERS_Access-Control-Expose-Headers='[Docker-Content-Digest]' \
    --env REGISTRY_PROXY_REMOTEURL="${registry_to_mirror}" \
    --name "${name}" \
    --network k3d-local \
    --publish "${host_port}":5000 \
    --volume "${name//./_}":/var/lib/registry \
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
    1>"${log_dir}/docker/${name//./_}.log" \
    2>"${log_dir}/docker/${name//./_}.err.log" \
    || docker start "${name}" \
      1>"${log_dir}/docker/${name//./_}.log" \
      2>"${log_dir}/docker/${name//./_}.err.log"
}

cd -- "$(dirname "$(readlink -f "$0")")" &> /dev/null
log_dir="../logs"
mkdir -p "${log_dir}"
rm -rf "${log_dir:?}/"

kubectl config unset users.admin@k3d-local 1>/dev/null
kubectl config unset clusters.k3d-local 1>/dev/null
kubectl config unset contexts.k3d-local 1>/dev/null

k3d_version="$(k3d --version | head -n 1 | sed 's|k3d version v\(.*\)$*|\1|g')"
mkdir -p "${log_dir}/docker"

printf "starting local registry..."
create_registry local.registry.localhost 5000 "${k3d_version}" "${log_dir}"
echo " Done!"

printf "starting docker registry mirror..."
create_registry_mirror docker.mirror.registry.localhost 5001 https://registry-1.docker.io "${k3d_version}" "${log_dir}"
echo " Done!"

printf "starting quay registry mirror..."
create_registry_mirror quay.mirror.registry.localhost 5002 https://quay.io "${k3d_version}" "${log_dir}"
echo " Done!"

printf "starting k8s community registry mirror..."
create_registry_mirror k8s-community.mirror.registry.localhost 5003 https://registry.k8s.io "${k3d_version}" "${log_dir}"
echo " Done!"

printf "starting k3s..."
kubectl config unset users.admin@k3d-local 1>/dev/null
kubectl config unset clusters.k3d-local 1>/dev/null
kubectl config unset contexts.k3d-local 1>/dev/null
k3d cluster create local \
  --config ../k3d-local.yml \
  --registry-config ../k3d-registry.yml \
  1>"${log_dir}/k3s.log" \
  2>"${log_dir}/k3s.err.log"
echo " Done!"

kubeconfig="${K3D_KUBECONFIG:-${HOME}/.kube/config.k3d}"
k3d kubeconfig merge local --output "${kubeconfig}" 1>/dev/null 2>/dev/null
kubectl config use-context k3d-local 1>/dev/null

mkdir -p "${log_dir}/helm"
printf "Installing argocd through helm..."
helm repo add argocd https://argoproj.github.io/argo-helm 1>/dev/null \
  || helm repo update argo-cd 1>/dev/null
helm install \
  argocd argo-cd/argo-cd \
  --version 7.4.4 \
  --values ../argocd/helm-values.yml \
  --namespace argocd \
  --create-namespace \
  1>"${log_dir}/helm/argocd.log" \
  2>"${log_dir}/helm/argocd.err.log"
echo " Done!"

printf "Installing traefik through helm..."
helm repo add traefik https://traefik.github.io/charts 1>/dev/null || \
  helm repo update traefik 1>/dev/null
helm install \
  traefik traefik/traefik \
  --version 30.1.0 \
  --values ../traefik/helm-values.yml \
  --namespace traefik \
  --create-namespace \
  1>"${log_dir}/helm/traefik.log" \
  2>"${log_dir}/helm/traefik.err.log"
echo " Done!"

printf "Waiting for ArgoCD to become ready.."
wait_for 5m \
  "curl \
    --fail \
    --insecure \
    --silent \
    https://argocd.k3d.localhost"
echo " Done!"

mkdir -p "${log_dir}/argocd"

printf "Reinstalling argocd through argocd..."
kubectl apply \
  --kustomize ../argocd/argocd-application \
  --namespace argocd \
  1>"${log_dir}/argocd/log.log" \
  2>"${log_dir}/argocd/err.log"
echo " Done!"

printf "Reinstalling traefik through argocd..."
kubectl apply \
  --kustomize ../traefik/argocd-application \
  --namespace argocd \
  1>"${log_dir}/argocd/log.log" \
  2>"${log_dir}/argocd/err.log"
echo " Done!"

printf "(Re-)installing apps through argocd..."
kubectl apply \
  --kustomize ../argocd/all-argocd-applications \
  --namespace argocd \
  1>"${log_dir}/argocd/log.log" \
  2>"${log_dir}/argocd/err.log"
echo " Done!"

printf "Waiting for serviceaccount 'admin' in namespace 'kubernetes-dashboard' to exist.."
wait_for 5m \
  "kubectl get sa/admin \
    --namespace kubernetes-dashboard \
    1> /dev/null 2> /dev/null"
echo " Done!"

printf "Adding middleware with bearer token for kubernetes-dashboard..."
token=$(kubectl \
  --namespace kubernetes-dashboard \
  --duration=999999h \
  create token admin)
sed 's/TOKEN/'"${token}"'/g' ../kubernetes-dashboard/templates/middleware.yml \
  | 1> /dev/null \
    kubectl apply \
      --namespace kubernetes-dashboard \
      --filename -
unset token
echo " Done!"

printf "Installing certificates.."
../cert-manager/certs/build-certs.sh
wait_for 5m \
  "kubectl apply \
    --kustomize ../cert-manager/certs \
    --namespace cert-manager"
echo " Done!"

printf "Creating ArgoCD meta-project holding all applications.."
wait_for 5m \
  "kubectl apply \
    --kustomize ../argocd/argocd-all-argocd-applications \
    --namespace argocd"
echo " Done!"

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
  "https://k8s-community.registry.k3d.localhost" \
)
for url in "${urls[@]}"
do
  printf "Waiting for %s to become reachable.." "${url}"
  wait_for 5m \
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
echo "    https://k8s-community.registry.k3d.localhost (k8s-community registry mirror)"
echo
echo "The system provides a registry at"
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
