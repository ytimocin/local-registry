#!/bin/sh
set -o errexit

# 1. Create registry container unless it already exists

# Define registry name and port
reg_name='kind-registry'
reg_port='5001'
domain='local.radius.registry'

# Generate a self-signed certificate
certs_dir="$(mktemp -d)"
openssl req -newkey rsa:4096 -nodes -sha256 -keyout "${certs_dir}/domain.key" -x509 -days 365 -out "${certs_dir}/domain.crt" -subj "/CN=${domain}"

# Create registry container unless it already exists
if [ "$(docker inspect -f '{{.State.Running}}' "${reg_name}" 2>/dev/null || true)" != 'true' ]; then
  echo "Creating local registry"
  docker run -d \
    --restart=always \
    -p "127.0.0.1:${reg_port}:5000" \
    --name "${reg_name}" \
    -v "${certs_dir}:/certs" \
    -e REGISTRY_HTTP_ADDR="0.0.0.0:5000" \
    -e REGISTRY_HTTP_TLS_CERTIFICATE="/certs/domain.crt" \
    -e REGISTRY_HTTP_TLS_KEY="/certs/domain.key" \
    registry:2
fi

# Update /etc/hosts to point local.radius.registry to 127.0.0.1
if ! grep -q "${domain}" /etc/hosts; then
  echo "127.0.0.1 ${domain}" | sudo tee -a /etc/hosts
fi

# Create the directory structure for containerd registry config
# sudo mkdir -p /etc/containerd/certs.d/${domain}:${reg_port}
# cp "${certs_dir}/domain.crt" /etc/containerd/certs.d/${domain}:${reg_port}/ca.crt

# 2. Create kind cluster with containerd registry config dir enabled
# TODO: kind will eventually enable this by default and this patch will
# be unnecessary.
#
# See:
# https://github.com/kubernetes-sigs/kind/issues/2875
# https://github.com/containerd/containerd/blob/main/docs/cri/config.md#registry-configuration
# See: https://github.com/containerd/containerd/blob/main/docs/hosts.md
cat <<EOF | kind create cluster --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    # This option mounts the host docker registry folder into
    # the control-plane node, allowing containerd to access them. 
    extraMounts:
      - containerPath: /etc/docker/certs.d/${domain}
        hostPath: ${certs_dir}
containerdConfigPatches:
- |-
    [plugins."io.containerd.grpc.v1.cri".registry.configs."${domain}".tls]
      cert_file = "/etc/docker/certs.d/${domain}/domain.crt"
      key_file  = "/etc/docker/certs.d/${domain}/domain.key"
EOF

# 3. Add the registry config to the nodes
#
# This is necessary because localhost resolves to loopback addresses that are
# network-namespace local.
# In other words: localhost in the container is not localhost on the host.
#
# We want a consistent name that works from both ends, so we tell containerd to
# alias localhost:${reg_port} to the registry container when pulling images
REGISTRY_DIR="/etc/containerd/certs.d/localhost:${reg_port}"
for node in $(kind get nodes); do
  docker exec "${node}" mkdir -p "${REGISTRY_DIR}"
  cat <<EOF | docker exec -i "${node}" cp /dev/stdin "${REGISTRY_DIR}/hosts.toml"
[host."http://${reg_name}:5000"]
EOF
done

# 4. Connect the registry to the cluster network if not already connected
# This allows kind to bootstrap the network but ensures they're on the same network
if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "${reg_name}")" = 'null' ]; then
  docker network connect "kind" "${reg_name}"
fi

# 5. Document the local registry
# https://github.com/kubernetes/enhancements/tree/master/keps/sig-cluster-lifecycle/generic/1755-communicating-a-local-registry
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${reg_port}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
