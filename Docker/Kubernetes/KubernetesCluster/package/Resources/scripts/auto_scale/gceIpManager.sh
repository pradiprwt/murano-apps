#!/bin/bash
# $1 - free_node | busy_node | details
#

function usage()
{
    echo ""
    echo "Usage: $0 [free_node|busy_node|details]"
    echo "Options: "
    echo ""
    echo "    free_node:   returns first available GCP node IP, 0 if all nodes busy "
    echo ""
    echo "    busy_node:   returns the last used GCP node IP, 0 if all nodes free"
    echo ""
    echo "    details:      returns detail json format"
    echo ""
    echo "Returns -1 if GCP nodes not specified in conf file"
    echo ""

}


if [ $# -eq 0 ] ; then
    usage
    exit 1
fi

option=$1

OPTIONS=(free_node busy_node busy_count add_node del_node details auto_busy_node)
if [[ " ${OPTIONS[@]} " =~ " ${1} " ]]; then
    option=$1
else
    echo "Unknow option: $1"
    exit 1
fi

conf_file="/etc/autoscale/autoscale.conf"
if [ ! -f $conf_file ] ; then
    echo "-1"
    exit 0
fi

gcp_nodes=$(awk -F "=" '/^gcp_ip/ {print $2}' $conf_file)

# if gcp_nodes are not available
if [ -z $gcp_nodes ] ; then
    echo "-1"
    exit 0
fi

AUTO_FLAG_FILE="/tmp/autoscale"
if [ ! -f $AUTO_FLAG_FILE ] ; then 
    AUTO_FLAG=0
else 
    AUTO_FLAG=`cat $AUTO_FLAG_FILE`
fi
LIST_STATIC_NODES="/etc/autoscale/static_nodes.list"
LIST_AUTO_NODES="/etc/autoscale/auto_nodes.list"

#json=$(cat tmp)
json=`curl -s localhost:8080/api/v1/nodes`
total_nodes=$(echo $json | jq --raw-output ".items | length")

GCP_ARRAY=()
count=0

function create_gcp_array()
{
    while IFS=',' read -ra ADDR; do
        for i in "${ADDR[@]}"; do
            GCP_ARRAY+=("$i")
        done
    done <<< "$gcp_nodes"
}

function print_gcp_array()
{
    for each in "${GCP_ARRAY[@]}"
    do
        echo "$each"
    done
}

# return 0 - if available, otherwise -1
function is_node_available()
{
    gcp_node=$1
    count=0
    while [ $count -lt $total_nodes ] ; do
        node_name=$(echo $json | jq --raw-output ".items[$count].metadata.name")
        if [ $node_name == $gcp_node ] ; then
            echo "-1"
            return;
        fi
        let count=count+1
    done
    count=0
    echo "0"
}

function get_free_node()
{
    for node in "${GCP_ARRAY[@]}"
    do
        ret=$(is_node_available $node)
        if [ $ret == "0" ] ; then
            echo $node
            return;
        fi
    done
    echo "0"
}

# returns last busy node
function get_busy_node()
{
    if [ $AUTO_FLAG == "1" ] ; then
      if [ -f $LIST_AUTO_NODES ]; then
        busyNode=`tail -n1 $LIST_AUTO_NODES` 
      fi
    else
      if [ -f $LIST_STATIC_NODES ]; then
        busyNode=`tail -n1 $LIST_STATIC_NODES`
      fi
    fi
    if [ $busyNode ] ; then
        echo $busyNode
    else
        echo 0
    fi
}


function details() 
{
    create_gcp_array
    gce_nodes_count=${#GCP_ARRAY[@]}
    if [ ! -f $LIST_AUTO_NODES ] ; then
        auto_nodes_cnt=0
    else
        auto_nodes_cnt=`wc -l $LIST_AUTO_NODES | awk '{print $1;}'`
    fi
    if [ ! -f $LIST_STATIC_NODES ] ; then
        static_nodes_cnt=0
    else
        static_nodes_cnt=`wc -l $LIST_STATIC_NODES | awk '{print $1;}'`
    fi
    
    ((gce_busy_count=auto_nodes_cnt+static_nodes_cnt))
    echo "{"
    echo "\"gce_nodes\":  \"$gcp_nodes\","
    echo "\"gce_nodes_count\": \"$gce_nodes_count\","
    echo "\"busy_nodes_count\": \"$gce_busy_count\""
    echo "}"
}

function add-node-conf()
{
    new_node=$1
    if [ $AUTO_FLAG == "1" ] ; then
        echo $new_node >> $LIST_AUTO_NODES
    else
        echo $new_node >> $LIST_STATIC_NODES
    fi
}

function del-node-conf()
{
    del_node=$1
    if [ $AUTO_FLAG == "1" ] ; then
        head -n -1 $LIST_AUTO_NODES > "$LIST_AUTO_NODES.tmp"
        mv "$LIST_AUTO_NODES.tmp" $LIST_AUTO_NODES
    else 
        head -n -1 $LIST_STATIC_NODES > $LIST_STATIC_NODES.tmp
        mv $LIST_STATIC_NODES.tmp $LIST_STATIC_NODES
    fi
}


case $option in
    add_node)
        if [ $2 ]; then
            add-node-conf $2
        fi
        ;;
    del_node)
        del-node-conf
        ;;
    details)
        details
        ;;
    auto_busy_node)
        AUTO_FLAG=1
        get_busy_node
        ;;
esac
if [ $option == "free_node" ] ; then
   create_gcp_array
   get_free_node
   exit 0
fi
if [ $option == "busy_node" ] ; then
   get_busy_node
   exit 0
fi
if [ $option == "busy_count" ] ; then
  json=`details`
  echo $json | jq --raw-output ".busy_nodes_count"
  exit 0
fi

