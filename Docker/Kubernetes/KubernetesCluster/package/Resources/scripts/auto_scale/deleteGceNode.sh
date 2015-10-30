#!/bin/bash
# Removes the gcp node from k8s cluster

set -e

GCP_FILE="gceIpManager.sh"
NODE_IP=$(bash $GCP_FILE busy_node)
NODE="root@$NODE_IP"
# If you have NODE already,  then NODE_IP=${NODE#*@}

ETCD_BIN="/opt/bin/etcdctl"
TEMP_FILE="/tmp/etcd.list"


# files to remove from node 
function clean-files() {
    ssh $NODE "sudo rm -rf /opt/bin ; sudo rm -rf  ~/kube"
    ssh $NODE "sudo rm /etc/init.d/etcd /etc/init.d/kubelet /etc/init.d/kube-proxy /etc/init.d/flanneld"
 
}

# remove this node from etcd member list
function remove-etcd() {
    sudo $ETCD_BIN member list > $TEMP_FILE
    sudo chmod 0666 $TEMP_FILE
    while read -r line
    do
        name=$line
        if [[ $line == *"$MY_IP"* ]]
        then
            id=`echo $line | cut -d ":"  -f 1`
            echo "Deleting ID:$id from Cluster"
            sudo $ETCD_BIN member remove $id
            break
        fi
    done < $TEMP_FILE
    sudo rm $TEMP_FILE
}

# stop the services
function stop-services() {
    ssh $NODE "sudo service etcd stop"
    ssh $NODE "sudo service kubelet stop"
    ssh $NODE "sudo service kube-proxy stop"
    ssh $NODE "sudo service flanneld stop"
}

# delete this node from kubectl get nodes
sudo kubectl delete nodes $NODE_IP

stop-services
remove-etcd
clean-files
