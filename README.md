# Local kubernetes environment

```
$ ./setup.sh

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
(no more port-forwarding and NodePort 🎉).

The script will install and configure ingress-nginx, sealed-secrets,
cert-manager and an example application called podinfo.

Usage:
    ./setup.sh [[-n name] | [-h]]

Options:
    -n value        Name of the cluster (default: k3s-default)
    -h              Display this message

Remeber to stop other running k3d clusters before starting/creating
a new one, as the cluster is binding port 80 and 443 to the
host-machine using docker bridge network.

    k3d cluster list
    k3d cluster stop [NAME] (defaults to k3s-default if no name argument)
```

## How to setup on k3d

[k3d](https://github.com/rancher/k3d) is a wrapper for running k3s in docker. k3s is a lightweight Kubernetes distribution by [Rancher](https://github.com/rancher/k3s).

k3d only requires docker to run. To install k3d run the following:

```
curl -s https://raw.githubusercontent.com/rancher/k3d/main/install.sh | TAG=v4.0.0 bash
```

Or via [Homebrew](https://brew.sh/) `brew install k3d`

The `setup.sh` script will create a new k3d cluster with 1 master and 2 worker nodes, it it doesn't already exists.

The cluster will be configured with a [local-path-provisioner](https://github.com/rancher/local-path-provisioner), to be able to use HostPath for persistent local storage within Kubernetes.

The cluster will also bind port 80 and 443 to your host machine, such that you can deploy a nginx ingress controller with a LoadBalancer service type making it possible to use Ingress resources the same way as in a real cloud environment (no more port-forwarding og NodePort 🎉).

The script will install and configure ingress-nginx, sealed-secrets, cert-manager, a cluster-wide tiller instance and an example application called `podinfo`.

```
./setup.sh
```

To verify that everything was setup correctly access the podinfo example application:

```
open https://podinfo.test
```

You're now ready to use your cluster for local development! 🎉

Couple of things to notice:

- The secret `ca-key-pair` needs to be in the same namespace as the Issuer.
- Run `docker stats` to show the cluster resource usage from the docker daemon.
- To import local images to the cluster for development, you can use the `k3d image import some-image:latest` or `k3d image import some-image:latest -c k3s-default`
- The `setup.sh` can be runned as many times you want, if a cluster exists it will not recreate it, only re-apply the kubernetes manifests.
- `docker-for-mac` default memory is set to 2GB, this may not be enough. In the [Advanced tab in Docker settings](https://docs.docker.com/docker-for-mac/#resources) you can change the resource limits.

## `.test` certificate

To be able to use a local `.test` domain a certificate is required to be able to use tools like `curl` etc...

For Mac:

```
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ca.crt
```

For Linux:

```
sudo cp ca.crt /usr/local/share/ca-certificates/
sudo update-ca-certificates
```

For web browser the certificate needs to be imported manually.
Example for Google Chrome:

- Go to Chrome Settings
- Click on "advanced settings"
- Under HTTPS/SSL click to "Manage Certificates"
- Go to "Trusted Root Certificate Authorities"
- Click to "Import"

### How to setup dnsmasq on Ubuntu

#### Enable dnsmasq in NetworkManager

Edit the file /etc/NetworkManager/NetworkManager.conf, and add the line dns=dnsmasq to the [main] section, it will look like this :

```
[main]
plugins=ifupdown,keyfile
dns=dnsmasq

[ifupdown]
managed=false

[device]
wifi.scan-rand-mac-address=no
```

#### Let NetworkManager manage /etc/resolv.conf

```
sudo rm /etc/resolv.conf ; sudo ln -s /var/run/NetworkManager/resolv.conf /etc/resolv.conf
```

#### Configure .test

```
echo 'address=/.test/127.0.0.1' | sudo tee /etc/NetworkManager/dnsmasq.d/test-wildcard.conf
```

#### Reload NetworkManager and testing

NetworkManager should be reloaded for the changes to take effect.

```
sudo systemctl reload NetworkManager
```

Then we can verify that we can reach some usual site :

```
dig google.com +short
172.217.21.174
```

And lastly verify that the .test and subdomains are resolved as 127.0.0.1:

```
dig podinfo.test some.sub.domain.test portal.sandbox.test +short
127.0.0.1
127.0.0.1
127.0.0.1
```

## How to setup on minikube

First create a minikube cluster:

```
minikube start --cpus 4 --memory 8000 --disk-size 10g --kubernetes-version v1.20.2
```

### Alternative 1: Only cluster internal services

```
kubectl apply -k deploy/sealed-secrets
```

### Alternative 2: Ingress and LoadBalancer support

```
kubectl apply -k deploy
kubectl apply -k deploy/metallb
```

If your minikube cluster is running with a different ip range (`minikube ip`) than `192.168.99.100-192.168.99.250` use the following command to update the metallb layer2 configmap:

```
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: metallb-system
  name: config
data:
  config: |
    address-pools:
    - name: custom-ip-space
      protocol: layer2
      addresses:
      - $(minikube ip)/28
EOF
```

To verify that the LoadBalancer is no longer in pending state:

```
kubectl get svc -n kube-system -l app.kubernetes.io/name=ingress-nginx
```

Update the necessary dns config with the LoadBalancer IP (dnsmasq or `/etc/hosts`)
