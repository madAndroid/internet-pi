#!/usr/bin/env bash

if [ $UID != 0 ]; then
    echo "run this as root"
    exit 1
fi

if [ -f /home/andrew/int-stangl-co-za.pem ]; then
    cp /home/andrew/int-stangl-co-za.pem /etc/ssl/private/int.stangl.co.za.pem
    systemctl restart haproxy
fi
