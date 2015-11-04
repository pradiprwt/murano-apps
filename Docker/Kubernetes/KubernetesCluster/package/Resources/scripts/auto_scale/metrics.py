#!/usr/bin/python3
import json
import sys
import urllib.request
import time
import numpy
import os
import signal
import configparser
import subprocess
from datetime import datetime

data_file = "/etc/autoscale/autoscale.conf"
# data_file = "tmp.conf"
scale_script = "/opt/bin/autoscale/scale.sh"
MAX_VMS_LIMIT = 0
MIN_VMS_LIMIT = 0
MAX_GCE_VMS_LIMIT = 0
MIN_GCE_VMS_LIMIT = 0
MAX_CPU_LIMIT = 0
MIN_CPU_LIMIT = 0
CUR_NODES_COUNT = 0
NODES_OBJ = {}
# Parsing input parameters from autoscale.conf
def get_params():
    global MAX_VMS_LIMIT, MIN_VMS_LIMIT, MIN_GCE_VMS_LIMIT, MAX_GCE_VMS_LIMIT, MAX_CPU_LIMIT, MIN_CPU_LIMIT, MASTER
    configParser = configparser.ConfigParser()
    configParser.read(data_file)
    MASTER = configParser.get('DEFAULT', 'MASTER')
    MAX_VMS_LIMIT = int(configParser.get('DEFAULT', 'max_vms_limit'))
    MIN_VMS_LIMIT = int(configParser.get('DEFAULT', 'min_vms_limit'))
    MAX_CPU_LIMIT = int(configParser.get('DEFAULT', 'MAX_CPU_LIMIT'))
    MIN_CPU_LIMIT = int(configParser.get('DEFAULT', 'MIN_CPU_LIMIT'))
    MAX_GCE_VMS_LIMIT = int(configParser.get('GCE','gcp_minion_nodes'))

def get_cpu_usage(node_ip):
    api = "http://"+node_ip+":4194/api/v1.3/machine"
    request = urllib.request.Request(api)
    response = urllib.request.urlopen(request)
    decode_response = (response.read().decode('utf-8'))
    string = str(decode_response)
    machine_info = json.loads(string)
    num_cores = machine_info["num_cores"]

    api = "http://"+node_ip+":4194/api/v1.3/containers/"
    request = urllib.request.Request(api)
    response = urllib.request.urlopen(request)
    decode_response = (response.read().decode('utf-8'))
    string = str(decode_response)
    containers_info = json.loads(string)
    len_stats = len(containers_info["stats"])
    len_stats = int(len_stats)
    cur_stats = len_stats - 1
    prev_stats = len_stats - 2
    cur_status = containers_info["stats"][cur_stats]
    prev_status = containers_info["stats"][prev_stats]
    cur_cpu_usage = cur_status["cpu"]["usage"]["total"]
    cur_timestamp = cur_status["timestamp"]
    prev_cpu_usage = prev_status["cpu"]["usage"]["total"]
    prev_timestamp = prev_status["timestamp"]
    cur_time = numpy.datetime64(cur_timestamp).astype(datetime)
    prev_time = numpy.datetime64(prev_timestamp).astype(datetime)
    raw_cpu_usage = cur_cpu_usage - prev_cpu_usage
    try:
        interval_ns = cur_time - prev_time
    except Exception as e:
        return False
    cpu_usage = raw_cpu_usage/interval_ns
    cpu_usage = cpu_usage/num_cores * 100
    cpu_usage = '%.f' % round(cpu_usage, 1)
    cpu_usage = int(cpu_usage)
    return cpu_usage

# retuns True, if cluster is ready.
def get_k8s_status():
    api = "http://"+MASTER+":8080"
    request = urllib.request.Request(api)
    try:
        response = urllib.request.urlopen(request)
        if response.status == 200:
            print("OK")
            return True
    except Exception as e:
        print("not OK")
        print(e)
        return False

def get_total_nodes():
    global NODES_OBJ
    api = "http://"+MASTER+":8080/api/v1/nodes"
    request = urllib.request.Request(api)
    response = urllib.request.urlopen(request)
    decode_response = (response.read().decode('utf-8'))
    string = str(decode_response)
    nodes_info = json.loads(string)
    NODES_OBJ = nodes_info
    try:
        number_minions = len(nodes_info["items"])
        return number_minions
    except Exception as e:
        return -1

def get_private_nodes(total):
    return total-get_gcp_nodes()

def get_gcp_nodes():
    #gce_nodes=os.system("sudo ./gceIpManger.sh busy_count")
    #print(gce_nodes)
    output = subprocess.check_output("sudo bash gceIpManager.sh busy_count", shell=True)
    return int(output)

def print_limits():
    print ("Max VMs in Cluster: ", MAX_VMS_LIMIT)
    print ("Min VMs in Cluster: ", MIN_VMS_LIMIT)
    print ("Max GCE VMs Limit: ", MAX_GCE_VMS_LIMIT)
    print ("Min GCE VMs Limit: ", MIN_GCE_VMS_LIMIT)
    print ("Max CPU Usage Limit: ", MAX_CPU_LIMIT)
    print ("Min CPU Usage Limit: ", MIN_CPU_LIMIT, "\n")

def is_node_ready(minion):
    try:
        if NODES_OBJ["items"][minion]["status"]["conditions"][0]["status"] != "True":
            return False
    except Exception as e:
        return False
    return True

def scaleUpNodes():
    if (private_nodes < MAX_VMS_LIMIT):
        # Private Scale up
        print("Scaling up private ")
        #subprocess.check_output("sudo ./scale.sh up", shell=True)
        os.system(scale_script + ' up')
        return
    elif (get_gcp_nodes() < MAX_GCE_VMS_LIMIT):
        # GCE Scale UP
        print("private nodes limit has been reached")
        print("Scaling up GCE")
        #subprocess.check_output("sudo ./scale.sh up gce", shell=True)
        os.system(scale_script + ' up gce')
        return
    else:
        # Max reached
        print("Max nodes have been reached")
        return

def scaleDownNodes():
    if (get_gcp_nodes() > MIN_GCE_VMS_LIMIT):
        # GCE Scale Down
        print("GCE Scale Down")
        #subprocess.check_output("sudo ./scale.sh down gce", shell=True)
        #subprocess.check_output("sudo ./sleep.sh", shell=True)
        os.system(scale_script + ' down gce')
        return
    elif (private_nodes > MIN_VMS_LIMIT):
        # Private Scale down
        print("Private Scale down ")
        #subprocess.check_output("sudo ./scale.sh down", shell=True)
        os.system(scale_script + 'down')
        #subprocess.check_output("sudo ./sleep.sh", shell=True)
        return
    else:
        # Already Min
        print("Min nodes have been reached")
        return

get_params()
print("Waiting for Cluster")
while ( get_k8s_status() != True ):
    time.sleep(1)
print("cluster is up")
# time.sleep(20)
print_limits()

while 1:
    total_minions=get_total_nodes()
    if ( total_minions == -1):
        continue
    minion=0
    while minion < total_minions:
        node_ip = NODES_OBJ["items"][minion]["metadata"]["name"]

        if (is_node_ready(minion) == False):
            minion += 1
            continue
        print("monitoring minion: ", node_ip)
        minion += 1

        cpu_usage=get_cpu_usage(node_ip)
        if( cpu_usage == False):
             continue
        print ("CPU usage :", cpu_usage)

        private_nodes=get_private_nodes(total_minions)
        if (cpu_usage > MAX_CPU_LIMIT):
            scaleUpNodes()
        elif (cpu_usage < MIN_CPU_LIMIT):
            scaleDownNodes()
        time.sleep(1)
    time.sleep(2)

