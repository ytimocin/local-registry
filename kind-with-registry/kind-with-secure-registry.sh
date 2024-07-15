#!/bin/sh
set -o errexit

kind delete cluster --name kind

# Create a self-signed certificate
reg_name='kind-registry'
reg_port='5001'

# Generate a self-signed certificate with SAN
certs_dir="$(mktemp -d)"
cat <<EOF >"${certs_dir}/domain.ext"
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${reg_name}
EOF

openssl req -newkey rsa:4096 -nodes -sha256 -keyout "${certs_dir}/domain.key" -subj "/CN=${reg_name}" -out "${certs_dir}/domain.csr"
openssl x509 -req -in "${certs_dir}/domain.csr" -signkey "${certs_dir}/domain.key" -out "${certs_dir}/domain.crt" -days 365 -extfile "${certs_dir}/domain.ext"

# 1. Create registry container unless it already exists
if [ "$(docker inspect -f '{{.State.Running}}' "${reg_name}" 2>/dev/null || true)" != 'true' ]; then
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
      - containerPath: "/etc/containerd/certs.d/${reg_name}"
        hostPath: "${certs_dir}"
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."${domain}:${reg_port}"]
      endpoint = ["https://${domain}:${reg_port}"]
    [plugins."io.containerd.grpc.v1.cri".registry.configs."${domain}:${reg_port}".tls]
      ca_file = "/etc/containerd/certs.d/${reg_name}/domain.crt"
    # [plugins."io.containerd.grpc.v1.cri".registry.configs."${reg_name}:${reg_port}".tls]
    #   cert_file = "/etc/containerd/certs.d/${reg_name}/domain.crt"
    #   key_file  = "/etc/containerd/certs.d/${reg_name}/domain.key"
EOF

# 3. Add the registry config to the nodes
#
# This is necessary because localhost resolves to loopback addresses that are
# network-namespace local.
# In other words: localhost in the container is not localhost on the host.
#
# We want a consistent name that works from both ends, so we tell containerd to
# alias localhost:${reg_port} to the registry container when pulling images
# REGISTRY_DIR="/etc/containerd/certs.d/${reg_name}"
# for node in $(kind get nodes); do
#   docker exec "${node}" mkdir -p "${REGISTRY_DIR}"
#   docker cp "${certs_dir}/domain.crt" "${node}:${REGISTRY_DIR}/domain.crt"
#   # skip_verify = true
#   # Can we add insecure something flag?
#   cat <<EOF | docker exec -i "${node}" cp /dev/stdin "${REGISTRY_DIR}/hosts.toml"
# [host."http://${reg_name}:5000"]
#   ca = "${REGISTRY_DIR}/domain.crt"
#   capabilities = ["pull", "resolve"]
# EOF
#   # docker exec "${node}" systemctl restart containerd
# done

# 4. Connect the registry to the cluster network if not already connected
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
