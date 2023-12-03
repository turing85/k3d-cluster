#!/usr/bin/env bash
set -e

function waitFor() {
  timeout -k "${1}" "${1}" bash -c "while :
    printf '.'
    do
    ${2} 1>/dev/null 2>/dev/null && break
    sleep 5
    done"
}

cd -- "$(dirname "$(readlink -f "$0")")" &> /dev/null

k3d_version="$(k3d --version | head -n 1 | sed 's|k3d version v\(.*\)$*|\1|g')"

docker run \
  --env REGISTRY_HTTP_HEADERS_Access-Control-Allow-Headers='[Authorization,Accept,Cache-Control]' \
  --env REGISTRY_HTTP_HEADERS_Access-Control-Allow-Methods='["*"]' \
  --env REGISTRY_HTTP_HEADERS_Access-Control-Allow-Origin='["*"]' \
  --env REGISTRY_HTTP_HEADERS_Access-Control-Expose-Headers='[Docker-Content-Digest]' \
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
  docker.io/library/registry:2.8.2 2>/dev/null \
  || docker start local.registry.localhost
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
  docker.io/library/registry:2.8.2 2>/dev/null \
  || docker start docker.mirror.registry.localhost
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
  docker.io/library/registry:2.8.2 2>/dev/null \
  || docker start quay.mirror.registry.localhost

k3d cluster create local \
  --config ../k3d-local.yml \
  --registry-config ../k3d-registry.yml

kubeconfig="${K3D_KUBECONFIG:-${HOME}/.kube/config.k3d}"
echo "" "${kubeconfig}"
k3d kubeconfig merge local --output "${kubeconfig}"
kubectl ctx k3d-local

helm repo add traefik https://traefik.github.io/charts || \
  helm repo update traefik
printf "Trying to uninstall traefik"
waitFor 2m \
  "helm uninstall traefik -n kube-system"
echo " Done!"
helm uninstall traefik-crd -n kube-system
helm install \
  traefik traefik/traefik \
  --values ../traefik/helm-values.yml \
  --namespace kube-system

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts \
  || helm repo update prometheus-community
helm install \
  prometheus-operator prometheus-community/kube-prometheus-stack \
  --values ../prometheus/helm-values.yml \
  --namespace monitoring \
  --create-namespace

helm repo add argocd https://argoproj.github.io/argo-helm \
  || helm repo update argo-cd
helm install \
  argocd argo-cd/argo-cd \
  --values ../argocd/helm-values.yml \
  --namespace argocd \
  --create-namespace

printf "Waiting for ArgoCD to become available"
waitFor 2m \
    "kubectl get secret/argocd-initial-admin-secret --namespace argocd"
waitFor 2m \
  "argocd login \
    --insecure \
    --grpc-web \
    --username admin \
    --password $( \
        kubectl get secret/argocd-initial-admin-secret \
          --output yaml \
          --namespace argocd \
          | yq .data.password \
          | base64 --decode \
    ) \
    argocd.k3d.localhost"
echo " Done!"

kubectl apply \
  --filename ../argocd/argocd-project-system.yml \
  --namespace argocd

kubectl apply \
  --filename ../argocd/argocd-application.yml \
  --namespace argocd

kubectl apply \
  --filename ../traefik/argocd-application.yml \
  --namespace argocd

../cert-manager/certs/build-certs.sh
kubectl create namespace cert-manager
kubectl apply \
  --filename ../cert-manager/helm/argocd-application.yml \
  --namespace argocd
printf "Deploying Certificate chain for cert-manager"
waitFor 2m \
  "kubectl apply \
    --kustomize ../cert-manager/certs \
    --namespace cert-manager"
echo " Done!"
kubectl apply \
  --filename ../cert-manager/default-tls-crt/argocd-application.yml \
  --namespace argocd

kubectl apply \
  --filename ../prometheus/argocd-application.yml \
  --namespace argocd

kubectl create namespace kubernetes-dashboard
kubectl apply \
  --filename ../kubernetes-dashboard/argocd-application.yml \
  --namespace argocd

kubectl create namespace registry-ui
kubectl apply \
  --filename ../registry-ui/argocd-application.yml \
  --namespace argocd

kubectl create namespace portainer
kubectl apply \
  --filename ../portainer/argocd-application.yml \
  --namespace argocd