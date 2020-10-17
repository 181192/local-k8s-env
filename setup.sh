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
        INFO)   echo -e "\033[34m$dt $level: $msg\033[0m";;
        DEBUG)  echo -e "\033[33m$dt $level: $msg\033[0m";;
        ERROR)  echo -e "\033[31m$dt $level: $msg\033[0m";;
        *)      echo "$dt $msg";;
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

function usage {
    cat <<EOF
A bootstrapper script for k3d.

This script will create a new k3d cluster with 1 master
and 2 worker nodes, it it doesn't already exists.

The cluster will be configured with a local-path-provisioner,
to be able to use HostPath for persistent local storage within
Kubernetes.

The cluster will also bind port 80 and 443 to your host machine,
such that you can deploy a nginx ingress controller with a
LoadBalancer service type making it possible to use Ingress
resources the same way as in a real cloud environment
(no more port-forwarding og NodePort 🎉).

The script will install and configure nginx-ingress,
sealed-secrets, cert-manager, a cluster-wide tiller
instance and an example application called podinfo.

Usage:
    ./setup.sh [[-n name] | [-h]]

Options:
    -n value        Name of the cluster (default: k3s-default)
    -h              Display this message

Remeber to stop other running k3d clusters before starting/creating
a new one, as the cluster is binding port 80 and 443 to the
host-machine using docker bridge network.

    k3d list
    k3d stop [-n name]

EOF
}

NAME=k3d-default

while getopts hn: option; do
    case "${option}" in
        n) NAME=${OPTARG};;
        h) usage; exit 0;;
        *) ;;
    esac
done

log "INFO" "🤞  Checking requirements..."
require docker
require kubectl
require k3d

create_new_cluster=false

if k3d cluster start $NAME; then
    log "INFO" "Getting kubeconfig for cluster $NAME..."
    k3d kubeconfig merge $NAME --merge-default-kubeconfig --switch-context
else
    log "INFO" "Creating new cluster $NAME..."
    create_new_cluster=true

    docker volume create kube-volume

    k3d cluster create $NAME \
    --servers 1 \
    --agents 2 \
    --no-lb \
    --k3s-server-arg --no-deploy=traefik \
    --k3s-server-arg --tls-san="127.0.0.1" \
    --api-port 6444 \
    --port 80:80@server[0] \
    --port 443:443@server[0] \
    --volume kube-volume:/var/lib/rancher/k3s/storage \
    --timeout 300s \
    --wait \
    --switch-context \
    --update-default-kubeconfig \
    --image docker.io/rancher/k3s:v1.18.8-k3s1
fi

kubectl label namespace kube-system certmanager.k8s.io/disable-validation=true --overwrite
wait_for_deployment kube-dns kube-system k8s-app

log "INFO" "Setting up cluster..."
kubectl apply -f deploy/ca-key-pair.yaml
kubectl apply -k deploy/cert-manager
kubectl apply -k deploy/nginx-ingress
kubectl apply -k deploy/sealed-secrets

prometheusUrl="https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/crds/"
kubectl apply -f ${prometheusUrl}crd-alertmanager.yaml
kubectl apply -f ${prometheusUrl}crd-podmonitor.yaml
kubectl apply -f ${prometheusUrl}crd-probe.yaml
kubectl apply -f ${prometheusUrl}crd-prometheus.yaml
kubectl apply -f ${prometheusUrl}crd-prometheusrules.yaml
kubectl apply -f ${prometheusUrl}crd-servicemonitor.yaml
kubectl apply -f ${prometheusUrl}crd-thanosrulers.yaml

wait_for_deployment webhook
sleep 10

log "INFO" "Deploy podinfo..."
kubectl apply -k deploy/podinfo/
kubectl apply -n default -f deploy/ca-key-pair.yaml
wait_for_deployment podinfo default

log "INFO" "Invoking podinfo"
curl -k \
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
log "INFO" "Or be cool and configure dnsmasq 👌"
