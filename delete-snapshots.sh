#!/bin/bash

# WARNING: This script WILL execute 'kubectl linstor snapshot delete'
# for every snapshot found by the 'kubectl linstor snapshot list -m' command.
#
# It now uses the machine-readable output (-m) and 'jq' for reliable parsing.
#

# --- Check for jq ---
if ! command -v jq &> /dev/null
then
    echo "Error: The 'jq' utility is required but not found."
    echo "Please install jq to continue."
    exit 1
fi
# --- End Check ---

echo "Running 'kubectl linstor -m snapshot list' and parsing output..."
echo "The delete commands WILL be executed."
echo "You have 5 seconds to press CTRL+C to abort."
echo ""
sleep 5

# --- Use machine-readable output (-m) and jq ---
# 1. Get the list as machine-readable output (-m)
# 2. Pipe to 'jq' to extract the resource_name and name for each entry.
#    The JSON is structured as [ [ {snapshot1}, {snapshot2} ] ]
#    so we use .[] | .[] to iterate over the inner array.
#    We now also extract '.nodes' and join them with a space.
kubectl linstor -m snapshot list | \
    jq -r '.[] | .[] | "\(.resource_name) \(.name) \(.nodes | join(" "))"' | \
    while IFS=" " read -r resource_name snapshot_name nodes; do
        # Check if names are empty (in case of empty/bad jq parse)
        if [ -z "$resource_name" ] || [ -z "$snapshot_name" ] || [ -z "$nodes" ]; then
            echo "Skipping empty/partial line..."
            continue
        fi

        echo "-----------------------------------------------------"
        
        # Build the command and quote the names for safety
        # Add the -n $nodes flag. $nodes is unquoted to allow for multiple nodes.
        cmd_to_run="kubectl linstor snapshot delete \"$resource_name\" \"$snapshot_name\" -n $nodes"

        echo "Executing: $cmd_to_run"
        
        # Execute the command safely from the shell
        # We must use 'eval' here to correctly handle the quotes.
        # Removed 'yes |' as user confirms it does not ask for y/n.
        # The 'yes |' was causing the hang by holding stdin open.
        #
        # We redirect stdin from /dev/null ('< /dev/null') to prevent
        # the kubectl command from consuming the input stream that the
        # 'while read' loop depends on.
        eval $cmd_to_run < /dev/null
        
        echo "-----------------------------------------------------"
    done

echo ""
echo "Deletion script complete."
