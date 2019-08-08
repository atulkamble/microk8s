#!/usr/bin/env bash

set -e

export PATH="$SNAP/usr/sbin:$SNAP/usr/bin:$SNAP/sbin:$SNAP/bin:$PATH"

source $SNAP/actions/common/utils.sh

echo "Enabling Fluentd-Elasticsearch"

KUBECTL="$SNAP/kubectl --kubeconfig=${SNAP_DATA}/credentials/client.config"
echo "Labeling nodes"
NODENAME="$($KUBECTL get no -o yaml | grep " name:"| awk '{print $2}')"
$KUBECTL label nodes "$NODENAME" beta.kubernetes.io/fluentd-ds-ready=true || true


"$SNAP/microk8s-enable.wrapper" dns
sleep 5

refresh_opt_in_config "allow-privileged" "true" kube-apiserver
sudo systemctl restart snap.${SNAP_NAME}.daemon-apiserver

sleep 5

$KUBECTL apply -f "${SNAP}/actions/fluentd"

echo "Fluentd-Elasticsearch is enabled"
