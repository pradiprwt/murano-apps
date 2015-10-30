#!/usr/bin/python3
import json
import sys
import urllib.request
import time
import numpy
import os
import signal
import configparser
from datetime import datetime

data_file = "/etc/autoscale/autoscale.conf"
scale_script = "/opt/bin/autoscale/scale.sh"


def signal_handler(signal, frame):
    sys.exit(0)

signal.signal(signal.SIGINT, signal_handler)


total_num_vms = 0
total_num_gcevms = 0
min_gcevms_limit = 0

# Parsing input parameters from autoscale.conf
configParser = configparser.ConfigParser()
configParser.read(data_file)
MASTER = configParser.get('DEFAULT', 'MASTER')
max_vms_limit = int(configParser.get('DEFAULT', 'max_vms_limit'))
min_vms_limit = int(configParser.get('DEFAULT', 'min_vms_limit'))
MAX_CPU_LIMIT = int(configParser.get('DEFAULT', 'MAX_CPU_LIMIT'))
MIN_CPU_LIMIT = int(configParser.get('DEFAULT', 'MIN_CPU_LIMIT'))
max_gcevms_limit = int(configParser.get('GCE','gcp_minion_nodes'))

# Checking cluster is configured or not
count = 0
condition = True
while condition:
    try:
        api = "http://"+MASTER+":8080"
        request = urllib.request.Request(api)
        response = urllib.request.urlopen(request)
        if response.status == 200:
            print("cluster is up")
            condition = False
    except Exception as e:
        if count == 0:
            print("Please setup a cluster...!!!")
        count += 1
        time.sleep(1)

time.sleep(20)


def print_limits():
    print ("Max VMs in Cluster: ", max_vms_limit)
    print ("Min VMs in Cluster: ", min_vms_limit)
    print ("Max CPU Usage Limit: ", MAX_CPU_LIMIT)
    print ("Min CPU Usage Limit: ", MIN_CPU_LIMIT, "\n")


# Converting bytes to Giga bytes
def sizeof_fmt(num, suffix='B'):
    for unit in ['', 'Ki', 'Mi', 'Gi', 'Ti', 'Pi', 'Ei', 'Zi']:
        if abs(num) < 1024.0:
            return "%3.1f%s%s" % (num, unit, suffix)
        num /= 1024.0
    return "%.1f%s%s" % (num, 'Yi', suffix)
print_limits()
while 1:
    # Retrieving number of nodes in k8s cluster
    api = "http://"+MASTER+":8080/api/v1/nodes"
    request = urllib.request.Request(api)
    response = urllib.request.urlopen(request)
    decode_response = (response.read().decode('utf-8'))
    string = str(decode_response)
    nodes_info = json.loads(string)
    try:
        number_minions = len(nodes_info["items"])
        total_num_vms = number_minions
    except Exception as e:
        continue
    # Checking minon is ready or not
    minion = 0
    while minion < number_minions:
        node_ip = nodes_info["items"][minion]["metadata"]["name"]
        try:
            if nodes_info["items"][minion]["status"]["conditions"][0]["status"] != "True":
                minion += 1
                print("Not ready: ", node_ip + "\n")
                continue
        except Exception as e:
            minion += 1
            continue
        print("monitoring minion: ", node_ip)
        minion += 1

        # Retrieving number of cores in a node
        api = "http://"+node_ip+":4194/api/v1.3/machine"
        request = urllib.request.Request(api)
        response = urllib.request.urlopen(request)
        decode_response = (response.read().decode('utf-8'))
        string = str(decode_response)
        machine_info = json.loads(string)
        num_cores = machine_info["num_cores"]

        # Calculating CPU usage
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
            continue
        cpu_usage = raw_cpu_usage/interval_ns
        cpu_usage = cpu_usage/num_cores * 100
        cpu_usage = '%.f' % round(cpu_usage, 1)
        cpu_usage = int(cpu_usage)
        print ("CPU usage :", cpu_usage)

        if cpu_usage > MAX_CPU_LIMIT:
            if total_num_vms < max_vms_limit:
                print (" ................. Scaling UP ....................")
                os.system(scale_script + ' up')
                total_num_vms += 1
            else:
                print("..The maximum number of nodes has been reached on private cloud ..")
                if total_num_gcevms < max_gcevms_limit:
                    print(".......Scaling up to GCE......")
                    os.system(os.system(scale_script + ' up gce'))
                    total_num_gcevms += 1
                else:
                    print("...The maximum number of nodes has been reached on GCE...")
        if cpu_usage < MIN_CPU_LIMIT:
            if total_num_gcevms > min_gcevms_limit:
                print("...Scaling Down on GCE...")
                os.system(os.system(scale_script + ' down gce'))
                total_num_gcevms -= 1
            elif total_num_vms > min_vms_limit:
                print (" ................. Scaling Down on private ....................")
                os.system(scale_script + ' down')
                total_num_vms -= 1
        print ("\n")
        time.sleep(3)

