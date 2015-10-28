#!/bin/bash

gcp_nodes="$1"
gcp_ips="$2"
sudo touch /opt/add_public.txt
sudo echo ${gcp_nodes} >> /opt/add_public.txt
sudo echo ${gcp_ips} >> /opt/add_public.txt
sudo echo "Public node added succussfully to kubetnetes cluster" >> /opt/add_public.txt


