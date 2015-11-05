#!/bin/bash
# This script adds new node to Murano k8s cluster.

set -e

GCP_FILE="/opt/bin/autoscale/gceIpManager.sh"
NODE_IP=$(bash $GCP_FILE free_node)
NODE="root@$NODE_IP"

if [ $NODE_IP == "0" ] ; then
    echo '{ "error": "No GCE nodes available"}';
    exit 0
fi

# don't afraid to change the ports
PORT_ETCD_ADVERT_PEER=7001
PORT_ETCD_ADVERT_CLIENT=4001
PORT_ETCD_LISTEN_PEER=7001
PORT_ETCD_LISTEN_CLIENT=4001
PORT_KUBELET=10250
PORT_K8S_MASTER=8080

BIN_ETCDCTL=/opt/bin/etcdctl
BIN_KUBECTL=/bin/kubectl


# Retrieve the Master node from config file file
function get-master-ip()
{
    conf_file="/etc/autoscale/autoscale.conf"
    MASTER_IP=$(awk -F "=" '/^MASTER/ {print $2}' $conf_file)
}
# Transfers necessary bins and conf files to Minion
function transer-files() {
    ssh $NODE "sudo mkdir -p /opt/bin ; mkdir -p ~/kube ; mkdir -p ~/kube/initd ; mkdir -p ~/kube/bin"
    scp /opt/bin/autoscale/initd_scripts/* $NODE:~/kube/initd
    scp /opt/bin/etcd /opt/bin/etcdctl /opt/bin/kubelet /opt/bin/kube-proxy /opt/bin/flanneld $NODE:~/kube/bin
    ssh $NODE "sudo cp ~/kube/bin/* /opt/bin ; sudo cp ~/kube/initd/* /etc/init.d"
    ssh $NODE "sudo chmod +x /etc/init.d/etcd /etc/init.d/kubelet /etc/init.d/kube-proxy /etc/init.d/flanneld"
}

function ssh-setup()
{

   if [ ! -f  ~/.ssh/id_rsa ] ; then
       ssh-keygen -f ~/.ssh/id_rsa -t rsa -N ''
   fi
   ssh-keyscan $NODE_IP >> ~/.ssh/known_hosts
   #  TODO copy ssh id to gce node
   sshpass -p "Biarca@123" ssh-copy-id $NODE
}


# generate a etcd member name for new node.
function create-etcd-name() {
    # this func creates etcd names like new0, new1, new2...
    # change name pattern if required. ex: pattern="infra-"
    pattern="gce-"
    count=0
    $BIN_ETCDCTL member list > /tmp/etcd.list
    name="$pattern$count"
    while true
    do
       if grep "$name" /tmp/etcd.list > /dev/null
       then
          ((count=count+1))
          name="$pattern$count"
          continue
       else
          ETCD_NAME=$name
          break
       fi
    done
}


function create-etcd-opts() {
  ini_adv_peer="http://$NODE_IP:$PORT_ETCD_ADVERT_PEER"
  listen_peer_urls="http://$NODE_IP:$PORT_ETCD_LISTEN_PEER"
  listen_client_urls="http://$NODE_IP:$PORT_ETCD_LISTEN_CLIENT"
  adv_client_urls="http://$NODE_IP:$PORT_ETCD_ADVERT_CLIENT"

  OPTS="--name $ETCD_NAME \
  --data-dir /var/lib/etcd \
  --snapshot-count 1000 \
  --initial-advertise-peer-urls  $ini_adv_peer \
  --listen-peer-urls $listen_peer_urls \
  --listen-client-urls $listen_client_urls \
  --advertise-client-urls $adv_client_urls \
  --initial-cluster $ETCD_INITIAL_CLUSTER \
  --initial-cluster-state $ETCD_INITIAL_CLUSTER_STATE"

  ETCD_OPTS=`echo $OPTS | tr -s " "`  # remove extra spaces
}

function create-kube-proxy-opts() {
    OPTS="--logtostderr=false \
          --master=$MASTER_URL \
          --log_dir=$LOG_DIR"
    KUBE_PROXY_OPTS=`echo $OPTS | tr -s " "`  # remove extra spaces
}

function create-kubelet-opts()
{
    OPTS="--address=0.0.0.0 \
          --port=$PORT_KUBELET \
          --hostname_override=$NODE_IP \
          --api_servers=$MASTER_IP:$PORT_K8S_MASTER \
          --log_dir=/var/log/kubernetes \
          --logtostderr=false"
    KUBELET_OPTS=`echo $OPTS | tr -s " "`  # remove extra spaces
}

function create-flanneld-opts()
{
    OPTS="--iface=$NODE_IP"
    FLANNEL_OPTS=`echo $OPTS | tr -s " "`  # remove extra spaces
}

get-master-ip
MASTER_URL="http://$MASTER_IP:8080"

ssh-setup

echo "Transferring files to $NODE:"
transer-files

# decide etcd name and add it to etcdctl member list
if [ -z "$ETCD_NAME" ] ; then
    create-etcd-name
else
    ETCD_NAME=$ETCD_NAME
fi
echo "ETCD name..  $ETCD_NAME"
/opt/bin/etcdctl member add $ETCD_NAME http://$NODE_IP:$PORT_ETCD_LISTEN_PEER |tail -n +2  > /tmp/etcd.tmp

source /tmp/etcd.tmp
if [ -z $ETCD_INITIAL_CLUSTER ] ; then
    echo "ETCD error"
    exit 1
fi

create-etcd-opts
ssh $NODE "sudo echo ETCD_OPTS='\"'$ETCD_OPTS'\"' > /etc/default/etcd"
create-kube-proxy-opts
ssh $NODE "sudo echo KUBE_PROXY_OPTS='\"'$KUBE_PROXY_OPTS'\"' > /etc/default/kube-proxy"
create-kubelet-opts
ssh $NODE "sudo echo KUBELET_OPTS='\"'$KUBELET_OPTS'\"' > /etc/default/kubelet"
create-flanneld-opts
ssh $NODE "sudo echo FLANNEL_OPTS='\"'$FLANNEL_OPTS'\"' > /etc/default/flanneld"


ssh $NODE "sudo service etcd start"
sleep 1
ssh $NODE "sudo service kubelet start"
sleep 1
ssh $NODE "sudo service kube-proxy start"
sleep 1
ssh $NODE "service flanneld restart"

sleep 10
echo "Done"

