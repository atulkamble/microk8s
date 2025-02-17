#!/usr/bin/env bash

set -e

source $SNAP/actions/common/utils.sh

ARCH=$(arch)
if ! [ "${ARCH}" = "amd64" ]; then
  echo "Cilium is not available for ${ARCH}" >&2
  exit 1
fi

"$SNAP/microk8s-enable.wrapper" helm

echo "Restarting kube-apiserver"
refresh_opt_in_config "allow-privileged" "true" kube-apiserver
sudo systemctl restart snap.${SNAP_NAME}.daemon-apiserver

# Reconfigure kubelet/containerd to pick up the new CNI config and binary.
echo "Restarting kubelet"
refresh_opt_in_config "network-plugin" "cni" kubelet
refresh_opt_in_config "cni-bin-dir" "\${SNAP_DATA}/opt/cni/bin/" kubelet
sudo systemctl restart snap.${SNAP_NAME}.daemon-kubelet

if grep -qE "bin_dir.*SNAP}\/" $SNAP_DATA/args/containerd-template.toml; then
  echo "Restarting containerd"
  sudo "${SNAP}/bin/sed" -i 's;bin_dir = "${SNAP}/opt;bin_dir = "${SNAP_DATA}/opt;g' "$SNAP_DATA/args/containerd-template.toml"
  sudo systemctl restart snap.${SNAP_NAME}.daemon-containerd
fi

echo "Enabling Cilium"

read -ra CILIUM_VERSION <<< "$1"
if [ -z "$CILIUM_VERSION" ]; then
  CILIUM_VERSION="v1.6"
fi
CILIUM_ERSION=$(echo $CILIUM_VERSION | sed 's/v//g')

if [ -f "${SNAP_DATA}/bin/cilium-$CILIUM_ERSION" ]
then
  echo "Cilium version $CILIUM_VERSION is already installed."
else
  CILIUM_DIR="cilium-$CILIUM_ERSION"
  SOURCE_URI="https://github.com/cilium/cilium/archive"
  CILIUM_CNI_CONF="plugins/cilium-cni/05-cilium-cni.conf"
  CILIUM_LABELS="k8s-app=cilium"
  NAMESPACE=kube-system

  echo "Fetching cilium version $CILIUM_VERSION."
  sudo mkdir -p "${SNAP_DATA}/tmp/cilium"
  (cd "${SNAP_DATA}/tmp/cilium"
  sudo "${SNAP}/usr/bin/curl" -L $SOURCE_URI/$CILIUM_VERSION.tar.gz -o "$SNAP_DATA/tmp/cilium/cilium.tar.gz"
  if ! sudo gzip -f -d "$SNAP_DATA/tmp/cilium/cilium.tar.gz"; then
    echo "Invalid version \"$CILIUM_VERSION\". Must be a branch on https://github.com/cilium/cilium."
    exit 1
  fi
  sudo tar -xf "$SNAP_DATA/tmp/cilium/cilium.tar" "$CILIUM_DIR/install" "$CILIUM_DIR/$CILIUM_CNI_CONF")

  sudo mv "$SNAP_DATA/args/cni-network/cni.conf" "$SNAP_DATA/args/cni-network/10-kubenet.conf" 2>/dev/null || true
  sudo cp "$SNAP_DATA/tmp/cilium/$CILIUM_DIR/$CILIUM_CNI_CONF" "$SNAP_DATA/args/cni-network/05-cilium-cni.conf"

  # Generate the YAMLs for Cilium and apply them
  (cd "${SNAP_DATA}/tmp/cilium/$CILIUM_DIR/install/kubernetes"
  ${SNAP_DATA}/bin/helm template cilium \
      --namespace $NAMESPACE \
      --set global.cni.confPath="$SNAP_DATA/args/cni-network" \
      --set global.cni.binPath="$SNAP_DATA/opt/cni/bin" \
      --set global.cni.customConf=true \
      --set global.containerRuntime.integration="containerd" \
      --set global.containerRuntime.socketPath="$SNAP_COMMON/run/containerd.sock" \
      | sudo tee cilium.yaml >/dev/null)

  sudo mkdir -p "$SNAP_DATA/actions/cilium/"
  sudo cp "$SNAP_DATA/tmp/cilium/$CILIUM_DIR/install/kubernetes/cilium.yaml" "$SNAP_DATA/actions/cilium.yaml"
  sudo sed -i 's;path: \(/var/run/cilium\);path: '"$SNAP_DATA"'\1;g' "$SNAP_DATA/actions/cilium.yaml"

  ${SNAP}/microk8s-status.wrapper --wait-ready >/dev/null
  echo "Deploying $SNAP_DATA/actions/cilium.yaml. This may take several minutes."
  "$SNAP/kubectl" "--kubeconfig=$SNAP_DATA/credentials/client.config" apply -f "$SNAP_DATA/actions/cilium.yaml"
  "$SNAP/kubectl" "--kubeconfig=$SNAP_DATA/credentials/client.config" -n $NAMESPACE rollout status ds/cilium

  # Fetch the Cilium CLI binary and install
  CILIUM_POD=$("$SNAP/kubectl" "--kubeconfig=$SNAP_DATA/credentials/client.config" -n $NAMESPACE get pod -l $CILIUM_LABELS -o jsonpath="{.items[0].metadata.name}")
  CILIUM_BIN=$(mktemp)
  "$SNAP/kubectl" "--kubeconfig=$SNAP_DATA/credentials/client.config" -n $NAMESPACE cp $CILIUM_POD:/usr/bin/cilium $CILIUM_BIN >/dev/null
  sudo mkdir -p "$SNAP_DATA/bin/"
  sudo mv $CILIUM_BIN "$SNAP_DATA/bin/cilium-$CILIUM_ERSION"
  sudo chmod +x "$SNAP_DATA/bin/"
  sudo chmod +x "$SNAP_DATA/bin/cilium-$CILIUM_ERSION"
  sudo ln -s $SNAP_DATA/bin/cilium-$CILIUM_ERSION $SNAP_DATA/bin/cilium

  sudo rm -rf "$SNAP_DATA/tmp/cilium"
fi

echo "Cilium is enabled"
