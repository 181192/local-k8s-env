#!/bin/bash

set -o errexit
set -o nounset

function log {
    local dt
    dt=$(date '+%Y/%m/%d %H:%M:%S')
    local level=$1
    local msg=$2

    if [[ $# == 1 ]]; then
        msg=$1
    fi

    case $level in
        INFO)
            echo -e "\\e[34m$dt $level: $msg\\e[0m"
        ;;
        DEBUG)
            echo -e "\\e[33m$dt $level: $msg\\e[0m"
        ;;
        ERROR)
            echo -e "\\e[31m$dt $level: $msg\\e[0m"
        ;;
        *)
            echo "$dt $msg"
        ;;
    esac
}

function require {
    command -v "$1" >/dev/null 2>&1 || { log "ERROR" "Script requires $1 but it's not installed. Aborting..."; exit 1; }
}

function wait_for_deployment {
    local app=$1
    local namespace=${2:-kube-system}
    local label=${3:-app}
    local output="jsonpath='{.items[*].metadata.labels.$label}'"

    while [[ $(kubectl get pod -n "$namespace" -l "$label"="$app" --output="$output") != *"$app"* ]]; do
        log "DEBUG" "Waiting for $app pod to be created..."
        sleep 1
    done

    log "DEBUG" "Waiting for $app pod to be ready..."
    kubectl -n "$namespace" wait --for=condition=ready --timeout=300s pod/"$(kubectl get pod -n "$namespace" -l "$label"="$app" -o jsonpath='{.items[0].metadata.name}')"
}

log "INFO" "Checking requirements..."
require docker
require kubectl
require k3d

k3d check-tools

create_new_cluster=false

if [[ $(k3d list | grep k3s-default) != *"k3s-default"* ]]; then
    create_new_cluster=true

    docker volume create kube-volume

    k3d create \
    --workers 2  \
    --server-arg --no-deploy=traefik \
    --publish 80:80 \
    --publish 443:443 \
    --volume kube-volume:/opt/local-path-provisioner \
    --wait 300 \
    --image docker.io/rancher/k3s:v0.7.0
fi

log "INFO" "Getting kubeconfig..."
if $create_new_cluster; then
    sleep 10
fi

KUBECONFIG="$(k3d get-kubeconfig --name='k3s-default')"
export KUBECONFIG

kubectl label namespace kube-system certmanager.k8s.io/disable-validation=true --overwrite
wait_for_deployment kube-dns kube-system k8s-app

log "INFO" "Setting up cluster..."
kubectl apply -k deploy/
kubectl apply -k deploy/local-path-storage
wait_for_deployment webhook
sleep 10

log "INFO" "Deploy podinfo..."
kubectl apply -k deploy/podinfo/
kubectl apply -n default -f deploy/ca-key-pair.yaml
wait_for_deployment podinfo default

log "INFO" "Invoking podinfo"
curl -k\
    --connect-timeout 5 \
    --max-time 10 \
    --retry 5 \
    --retry-delay 0 \
    --retry-max-time 40 \
    --silent \
    --output /dev/null \
    -H "Host: podinfo.test" \
    https://127.0.0.1 || true

curl -H "Host: podinfo.test" -k https://127.0.0.1 && echo

log "INFO" "Add podinfo.test to your hosts file with:\n\tsudo echo \"127.0.0.1 podinfo.test\" >> /etc/hosts"
