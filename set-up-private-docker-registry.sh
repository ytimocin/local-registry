# This sh file is a script to set up a private Docker registry.

# Create localhub directory
# Create registry directory in localhub

docker run -d -p 5005:5000 -v $HOME/dev/localhub/registry:/var/lib/registry --restart=always --name hub.local registry

# http://localhost:5005/v2/_catalog will give you the list of images

# Pull the image from the public registry
docker pull alpine

# Tag and push the image
docker tag alpine localhost:5005/my-alpine
docker push localhost:5005/my-alpine

# Remove the images from the local machine
docker rmi localhost:5005/my-alpine
docker rmi alpine

# Pull the image from the local registry
docker pull localhost:5005/my-alpine
