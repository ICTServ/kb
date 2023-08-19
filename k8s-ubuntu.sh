#!/bin/bash

# Define the version of Kubernetes to be installed
KUBERNETES_VERSION="1.27.4-00"

# Define the version of containerd (container runtime) to be installed
CONTAINERD_VERSION="1.7.3"

# Define the version of runc (container runtime dependency) to be installed
RUNC_VERSION="1.1.8"

# Define the version of CNI (Container Network Interface) to be installed
CNI_VERSION="1.3.0"

# Define the Pod network CIDR (Classless Inter-Domain Routing) for Kubernetes cluster
# This defines the IP address range that Pods will use for communication within the cluster.
POD_NETWORK_CIDR="10.10.0.0/16"

# Define the version of Weave Network to be installed
WEAVE_NETWORK_VERSION=2.8.1

CONTAINERD_URL=https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz
CONTAINERD_SERVICE_URL=https://raw.githubusercontent.com/containerd/containerd/main/containerd.service
RUNC_URL=https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.amd64
CNI_URL=https://github.com/containernetworking/plugins/releases/download/v${CNI_VERSION}/cni-plugins-linux-amd64-v${CNI_VERSION}.tgz

# Make sure only root can run our script
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root" 1>&2
  exit 1
fi

check_existence() {
  non_existent_counter=0

  for item in "$@"; do
    if [[ ! -f "$item" && ! $(curl -s --head -w '%{http_code}' "$item" -o /dev/null) =~ ^[23] ]]; then
      echo "Not found: $item"
      ((non_existent_counter++))
    else
      echo "Found: $item"
    fi
  done

  if [ "$non_existent_counter" -gt 0 ]; then
    echo "Missing dependencies. $non_existent_counter item(s) not found."
    exit 1
  fi
}

printf "\n\nChecking dependencies...\n\n"
check_existence $CONTAINERD_URL $CONTAINERD_SERVICE_URL $RUNC_URL $CNI_URL


# ------ NEWTWORK CONFIG BEGIN ------

printf "\n\nStarting network configuration...\n\n"
printf "overlay\nbr_netfilter\n" >>/etc/modules-load.d/containerd.conf
modprobe overlay
modprobe br_netfilter
printf "net.bridge.bridge-nf-call-iptables = 1\nnet.ipv4.ip_forward = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\n" >>/etc/sysctl.d/99-kubernetes-cri.conf
sysctl --system > /dev/null
printf "\n\nNetwork configuration is done! If you want to use a multi node setup make sure hostnames are resolved to IP addresses.\nThis can be achieved by editing /etc/hosts\n\n"

# ------ NEWTWORK CONFIG END ------


# ------ INSTALL CONTAINERD BEGIN ------

# CONTAINERD
printf "\n\nInstalling containerd...\n\n"
rm /tmp/"${CONTAINERD_URL##*/}"
 wget --quiet --show-progress $CONTAINERD_URL -P /tmp/
tar Cxzf /usr/local /tmp/"${CONTAINERD_URL##*/}"

# CONTAINERD DAEMON
 wget --quiet --show-progress $CONTAINERD_SERVICE_URL -P /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now containerd

# dependencies >>

# RUNC
 wget --quiet --show-progress $RUNC_URL -P /tmp/
install -m 755 /tmp/runc.amd64 /usr/local/sbin/runc

# CNI
rm /tmp/"${CNI_URL##*/}"
 wget --quiet --show-progress $CNI_URL -P /tmp/
mkdir -p /opt/cni/bin
tar Cxzf /opt/cni/bin /tmp/"${CNI_URL##*/}"

# dependencies <<

# configuration >>

mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml > /dev/null
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd

# configuration <<

# ------ INSTALL CONTAINERD END ------


# ------ INSTALL KUBERNETES BEGIN ------
printf "\n\nInstalling kubernetes...\n\n"
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
apt-get update
apt-get install -y apt-transport-https ca-certificates curl
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /etc/apt/keyrings/kubernetes-archive-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
apt-get update
apt-get install -y kubelet=${KUBERNETES_VERSION} kubeadm=${KUBERNETES_VERSION} kubectl=${KUBERNETES_VERSION}
apt-mark hold kubelet kubeadm kubectl

# ------ INSTALL KUBERNETES END ------


# ------ INIT CONTROL PLANE BEGIN ------

# Prompt the user for control plane information
read -p "Do you want to init a control plane on this node? (y/n): " answer

# Convert the user's answer to lowercase for case-insensitive comparison
answer_lowercase="${answer,,}"

if [[ $answer_lowercase == "yes" || $answer_lowercase == "y" ]]; then

  kubeadm init --pod-network-cidr ${POD_NETWORK_CIDR} --kubernetes-version ${KUBERNETES_VERSION%%-[0-9]*}
  
  ufw allow 6783 > /dev/null
  ufw allow 6784 > /dev/null

  printf "\n\nIf You don't have a preferred network use the one below.\n\n"
  echo -e "kubectl apply -f https://github.com/weaveworks/weave/releases/download/v${WEAVE_NETWORK_VERSION}/weave-daemonset-k8s.yaml\n"
  
  printf "\n\nUse the below command to generate the token for your worker nodes.\n\n"
  echo -e "kubeadm token create --print-join-command\n"
  
  printf "\n\nUse the below command to run workloads on the control plane.\n\n"
  echo -e "kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule-\n"

fi

# ------ INIT CONTROL PLANE END ------
