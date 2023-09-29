#!/bin/bash 
CONFIG_FILE="locations.cfg"
BACKUP_LOG="backup_log.txt"
BACKUP_LOCAL="/home/vagrant/backups"
ALIEN_LOG="/home/vagrant/alien_logs"
LOG_FOLDER="/logs"

# Check if the config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: $CONFIG_FILE not found."
    exit 1
fi

display_locations() {
    echo "Backup Locations:"
    cat "$CONFIG_FILE"
}

extract_port() {
    local location="$1"
    echo "$location" | awk -F ':' '{print $2}'
}

extract_ip() {
    local location="$1"
    echo "$location" | awk -F '@|:' '{print $2}'
}

verify_files() {
    local source_folder="/home/vagrant/backups"
    local current_access_time
    local current_modify_time
    local current_change_time
    local recorded_access_time
    local recorded_modify_time
    local recorded_change_time
    
    for port_dir in "$source_folder"/*/; do
        for timestamp_dir in "$port_dir"*/; do
            local metadata_file="${timestamp_dir}${LOG_FOLDER}/time_metadata.cfg"
            if [[ -f "$metadata_file" ]]; then
                echo "Verifying files..."
                while IFS= read -r line; do
                    filename=$(echo "$line" | awk -F ' - ' '{print $1}')
                    echo "Checking for file: ${timestamp_dir}${filename}"

                    access_info=$(echo "$line" | awk -F 'Access: |, Modify:' '{print $2}')
                    modify_info=$(echo "$line" | awk -F ', Modify: |, Change:' '{print $2}')
                    change_info=$(echo "$line" | awk -F ', Change: ' '{print $2}')

                    recorded_access_time=$(date -d "$access_info" +%s)
                    recorded_modify_time=$(date -d "$modify_info" +%s)
                    recorded_change_time=$(date -d "$change_info" +%s)
                    echo "Recorded timestamps:"
                    echo "Access: $(date -d "@$recorded_access_time" "+%Y-%m-%d %H:%M:%S")"
                    echo "Modify: $(date -d "@$recorded_modify_time" "+%Y-%m-%d %H:%M:%S")"
                    echo "Change: $(date -d "@$recorded_change_time" "+%Y-%m-%d %H:%M:%S")"

                    if [[ "${filename##*.}" == "xyzar" ]]; then
                        filename="${filename}.gz"
                    fi

                    if [[ -f "${timestamp_dir}${filename}" ]]; then
                        current_access_time=$(stat -c %X "${timestamp_dir}${filename}")
                        current_modify_time=$(stat -c %Y "${timestamp_dir}${filename}")
                        current_change_time=$(stat -c %Z "${timestamp_dir}${filename}")
                        echo "Current timestamps:"
                        echo "Access: $(date -d "@$current_access_time" "+%Y-%m-%d %H:%M:%S")"
                        echo "Modify: $(date -d "@$current_modify_time" "+%Y-%m-%d %H:%M:%S")"
                        echo "Change: $(date -d "@$current_change_time" "+%Y-%m-%d %H:%M:%S")"

                        for type in access modify change; do
                            eval "difference=\$(( current_${type}_time - recorded_${type}_time ))"
                            if (( difference > 259200 || difference < -259200 )); then
                                echo "Timewarp detected"
                                [[ "${filename##*.}" != "timewarp" ]] && mv "${timestamp_dir}${filename}" "${timestamp_dir}${filename}.timewarp"
                                echo "${filename} - ${type^}: Recorded: $(date -d "@$(eval echo \${recorded_${type}_time})" "+%Y-%m-%d %H:%M:%S"), Current: $(date -d "@$(eval echo \${current_${type}_time})" "+%Y-%m-%d %H:%M:%S"), Difference: $(( difference / 3600 )) hours" >> "${timestamp_dir}${LOG_FOLDER}/timewarp.cfg"
                            fi
                        done
                    else
                        echo "File ${timestamp_dir}${filename} does not exist or cannot be accessed"
                    fi
                done < "$metadata_file"
            fi
        done
    done
    echo Verification complete.
}

restore_backup_to_vm() {
    local backup_directory="$1"
    local ip="$2"
    local use_timestamps="$3"

    # Create a timestamped directory on the VM for restoration    
    local timestamp=$(date +"%Y-%m-%d_%H-%M-%S")
    local vm_restore_directory="/home/vagrant/restored/${timestamp}_backup"

    # Create the directory on the VM
    if ! ssh "$ip" "mkdir -p \"$vm_restore_directory\""; then
        echo "Error: Failed to create directory on client machine."
        exit 1
    fi

    # Copy each file from the backup directory to the VM using rsync
    if ! rsync -av --exclude="*.swp" --exclude="${LOG_FOLDER}" --exclude="time_metadata.cfg" -e "ssh" "$backup_directory/" "$ip:$vm_restore_directory"; then
        echo "Error: Failed to restore backup to client."
        exit 1
    fi

    # Restore the timestamps if $use_timestamps is true
    if [ "$use_timestamps" = "timewarp" ]; then
        while IFS= read -r -u 3 line; do
            original_filename=$(awk -F ' - ' '{print $1}' <<< "$line")
            echo "$original_filename"
            # Check if the restored file has a ".timewarp" extension on the VM
            if ssh "$ip" "[[ -f \"$vm_restore_directory/${original_filename}.timewarp\" ]]"; then
                restore_filename="${original_filename}.timewarp"
            else
                restore_filename="$original_filename"
            fi
            echo "Restoring timestamps for $restore_filename"
            access_time=$(awk -F 'Access: |, Modify:' '{print $2}' <<< "$line")
            modify_time=$(awk -F ', Modify: |, Change:' '{print $2}' <<< "$line")

            ssh "$ip" "touch -a -d \"$access_time\" \"$vm_restore_directory/$restore_filename\""
            ssh "$ip" "touch -m -d \"$modify_time\" \"$vm_restore_directory/$restore_filename\""
        done 3< "$backup_directory${LOG_FOLDER}/time_metadata.cfg"
    fi

    echo "Restore completed"
}

restore_recent_to_nth_location() {
    local line_number="$1"
    local use_timestamp="$2"
    
    # Extract the nth location
    local selected_location=$(sed -n "${line_number}p" "$CONFIG_FILE")
    if [ -z "$selected_location" ]; then
        echo "Error: Line number $line_number is out of range."
        exit 1
    fi

    local ip=$(extract_ip "$selected_location")
    
    # Get the most recent backup directory for this IP
    local recent_backup=$(grep "$ip" "$BACKUP_LOG" | head -1 | awk '{print $1}')
    
    # If we didn't find a backup for this location, exit
    if [ -z "$recent_backup" ]; then
        echo "Error: No backups found for client $ip."
        exit 1
    fi

    # Restore this backup to the VM
    echo "Restoring backup $recent_backup to client $ip..."
    restore_backup_to_vm "$recent_backup" "$ip" "$use_timestamp"
}

restore_n_recent() {
    local nth_recent="$1"
    local use_timestamp="$2"

    # Extract information from the nth_recent line of the BACKUP_LOG
    local log_line=$(sed -n "${nth_recent}p" "$BACKUP_LOG")
    local backup_directory=$(echo "$log_line" | awk '{print $1}')
    local ip=$(echo "$log_line" | awk '{print $2}')
    
    # Check if backup_directory exists
    if [ ! -d "$backup_directory" ]; then
        echo "Error: Backup directory $backup_directory not found."
        exit 1
    fi

    # Restore the backup to the VM
    echo "Restoring $backup_directory"
    restore_backup_to_vm "$backup_directory" "$ip" "$use_timestamp"
}

backup_all_files() {
    local source_folder="/home/vagrant/backups"
    local port="$1"
    local ip="$2"
    local backup_location="$BACKUP_LOCAL/$port"

    mkdir -p "$backup_location"
    
    local timestamp=$(date +"%Y-%m-%d_%H-%M-%S")
    local new_directory_name="${backup_location}/${timestamp}"
    mkdir -p "$new_directory_name"

    # Set up the log and metadata file locations and structures
    local log_file="$(date +"%Y-%m-%d").log"
    local log_location="${ALIEN_LOG}/${log_file}"

    local metadata_file="${new_directory_name}${LOG_FOLDER}/time_metadata.cfg"
    mkdir -p "$(dirname "$metadata_file")"
    touch "$metadata_file"

    echo "Preparing files for client $ip in $source_folder for backup..."

    # Retrieve a list of .xyzar files in the source folder
    local xyzar_files=$(ssh "$ip" "ls ${source_folder}/*.xyzar 2>/dev/null")

    # Iterate through .xyzar files in the source folder for compression
    for file in $xyzar_files; do
        echo "File type is .xyzar, compressing $file..."

        # Getting file size before compression
        local original_size=$(ssh "$ip" "du -sh $file | cut -f1")

        # SSH into the VM and create a compressed copy without altering the original file
        ssh "$ip" "gzip -c $file > ${file}.gz"
        
        # Getting file size after compression
        local compressed_size=$(ssh "$ip" "du -sh ${file}.gz | cut -f1")

        # Log details into the ALIEN_LOG directory with daily log files
        echo "Timestamp: ${timestamp}, Source: ${ip}, File: ${file}, Original Size: ${original_size}, Compressed Size: ${compressed_size}" >> "$log_location"
    done

    # Sync the files to the backup location
    rsync -av --exclude="*.xyzar" --exclude="*.swp" -e ssh "$ip:${source_folder}/" "${new_directory_name}/"

    for file in "$new_directory_name"/*; do
        if [[ "$file" != "$new_directory_name/logs" ]]; then
            local access_time=$(stat -c %x "$file")
            local modify_time=$(stat -c %y "$file")
            local change_time=$(stat -c %z "$file")
            local relative_path="${file#$new_directory_name/}"

            echo "$relative_path - Access: $access_time, Modify: $modify_time, Change: $change_time" >> "$metadata_file"
        fi
    done

    # Remove the compressed files from the VM
    ssh "$ip" "rm ${source_folder}/*.xyzar.gz"

    # Update the BACKUP_LOG
    local existing_content=$(<"$BACKUP_LOG")
    local updated_content="$new_directory_name $ip\n$existing_content"
    echo -e "$updated_content" > "$BACKUP_LOG"

    echo "Backup completed"
    verify_files
}

# Main Script Execution

case "$1" in
    "")
        display_locations
        ;;

    "-L")
        if ! [[ "$2" =~ ^[0-9]+$ ]]; then
            echo "Error: The argument following -L must be a number."
            exit 1
        fi

        if [[ "$3" == "-R" ]]; then
            if [[ "$4" == "-T" ]]; then
                restore_recent_to_nth_location "$2" "timewarp"
            else
                restore_recent_to_nth_location "$2"
            fi
        elif [[ "$3" == "-B" ]]; then
            port=$(extract_port "$(sed -n "${2}p" "$CONFIG_FILE")")
            ip=$(extract_ip "$(sed -n "${2}p" "$CONFIG_FILE")")
            [[ -z "$port" || -z "$ip" ]] && echo "Error: Line number $2 is out of range." && exit 1
            backup_all_files "$port" "$ip"
        else
            echo "Invalid option for -L"
        fi
        ;;

    "-R")
        if ! [[ "$2" =~ ^[0-9]+$ ]]; then
            echo "Error: The argument following -R must be a number."
            exit 1
        elif [[ "$3" == "-T" ]]; then
            restore_n_recent "$2" "timewarp"
        else
            restore_n_recent "$2"
        fi
        ;;

    "-B")
        while IFS= read -r -u 3 line; do
            port=$(extract_port "$line")
            ip=$(extract_ip "$line")
            backup_all_files "$port" "$ip"
        done 3< "$CONFIG_FILE"
        ;;

    "-V")
        verify_files
        ;;

    *)
        echo "Invalid argument"
        echo "Usage:"
        echo "-V          | Verify all client backups"        
        echo "-B          | Backup all client locations"
        echo "-L n -B     | Backup the nth located client"
        echo "-R n        | Restore the nth most recent backup"
        echo "-R n -T     | Restore the nth most recent backup with original timestamp"
        echo "-L n -R     | Restore all files to nth located client"
        echo "-L n -R -T  | Restore all files to nth located client with original timestamp"
        ;;
esac
