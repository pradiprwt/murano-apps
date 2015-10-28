#!/bin/bash

gcp_nodes="$1"
gcp_ips="$2"
sudo touch /opt/delete_public.txt
sudo echo ${gcp_nodes} >> /opt/delete_public.txt
sudo echo ${gcp_ips} >> /opt/delete_public.txt
sudo echo "Public node deleted succussfully to kubetnetes cluster" >> /opt/delete_public.txt


