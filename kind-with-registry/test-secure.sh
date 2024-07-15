docker kill kind-registry
docker system prune -f

kind delete cluster

./kind-with-secure-registry.sh

docker pull gcr.io/google-samples/hello-app:1.0
docker tag gcr.io/google-samples/hello-app:1.0 localhost:5001/hello-app:1.0
docker push localhost:5001/hello-app:1.0

# kubectl create deployment hello-server --image=localhost:5001/hello-app:1.0

kubectl create deployment hello-server --image=kind-registry:5000/hello-app:1.0

# docker exec -it kind-control-plane cat /etc/containerd/config.toml
