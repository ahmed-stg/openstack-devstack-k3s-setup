#!/bin/bash
set -euo pipefail

# Ensure policy directory and file exist
sudo mkdir -p /etc/containers
echo '{"default": [{"type": "insecureAcceptAnything"}]}' | sudo tee /etc/containers/policy.json >/dev/null

# Import images
IMAGES=$(tar -xOf k3s-airgap-images.tar manifest.json | jq -r '.[].RepoTags[]')
for IMG in $IMAGES; do
    echo "Pushing $IMG to Zot..."
    TARGET_IMG="${REGISTRY_INTERNAL_IP}:5000/${IMG#*/}"
    skopeo copy --dest-tls-verify=false docker-archive:k3s-airgap-images.tar:docker.io/$IMG docker://$TARGET_IMG
done
rm -f k3s-airgap-images.tar
