#!/bin/bash
# import_images.sh — mirror the K3s airgap image tarball into Zot.
# Runs ON the master VM; the tarball is expected at ./k3s-airgap-images.tar.
set -euo pipefail

# Ensure policy directory and file exist
sudo mkdir -p /etc/containers
echo '{"default": [{"type": "insecureAcceptAnything"}]}' | sudo tee /etc/containers/policy.json >/dev/null

# Import images
IMAGES=$(tar -xOf k3s-airgap-images.tar manifest.json | jq -r '.[].RepoTags[]')
for IMG in $IMAGES; do
    # The archive tags are e.g. "rancher/mirrored-pause:3.6". Containerd asks
    # the mirror for that exact repository path, so it must be preserved:
    # stripping the first component ("rancher/") would push mirrored-pause
    # under a path nothing ever requests, and pulls would silently fall back
    # to docker.io over the internet.
    REF="${IMG#docker.io/}"
    TARGET_IMG="${REGISTRY_INTERNAL_IP}:5000/${REF}"
    echo "Pushing $REF to $TARGET_IMG ..."
    skopeo copy --dest-tls-verify=false \
        "docker-archive:k3s-airgap-images.tar:${IMG}" \
        "docker://${TARGET_IMG}"
done
rm -f k3s-airgap-images.tar
