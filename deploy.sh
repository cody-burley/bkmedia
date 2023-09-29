#!/bin/bash

# Define the server and path
SERVER="server"
SERVER_IP="172.16.82.147:2222"  # Replace with actual IP if it changes
TARGET_PATH="/home/vagrant"

# Copy script to server
vagrant scp bkmedia.sh server:$TARGET_PATH

# Generate the command to run on the VM
CMD="bash ${TARGET_PATH}/bkmedia.sh"
for arg in "$@"; do
    CMD="$CMD \"$arg\""
done

# Run script on server VM
vagrant ssh server -c "$CMD"