#!/bin/bash

if [ "$#" -lt 3 ]; then
    echo "usage: $0 <backup-name> <vm-id> <disk-id>..."
    exit 1
fi

# The folling variables are exported in the main script
# for security purpose with GitHub. The main script is here:
#
#   /usr/local/backup/ovirtbackup.sh
#
# If you want test or use this script in standalone mode, uncomment
# the following lines and redefine variables.
#username='admin@internal'
#password='<xxxxxxxxxxxxx>'
#baseurl='https://...../api'


# Fill in the UUID of the virtual machine running this script:
# [ this machine will run the dd commands (in this case is the local machine) ]
ovbackup='215c6557-7357-4cd9-ba69-9fcb6cb061bc'

mydate="$(date '+%Y%m%d%H%M')"
description="backup-$mydate"

# default arguments to curl command
defargs=('-k' '-u' "$username:$password" '-H' 'Content-type: application/xml')

# backup alias
bckname="$1"

# virtual machine identifier
vmid="$2"

# array of disks to include in the snapshot
disks=()
for ((j=0, i=3; i<=$#; ++j, ++i)); do
    # warning!!! see bash "indirection" if you don't understand this line 
    disks[j]="${!i}" 
done

# backup directory
bckdir="/mnt/ovirt-backup/$bckname"

###############################################################################
# Helper functions
###############################################################################

# errorexit <message>
function errorexit() 
{
    echo "$bckname: ERROR: ${1}" >&2
    exit 1    
}

# errorexit <message>
function warning() 
{
    echo "$bckname: WARNING: ${1}" >&2    
}

# checkcurl <rval>
function checkcurl()
{
    # check curl error
    if [ $1 -ne 0 ]; then
        errorexit "curl exit value: $1"
    fi

    # check if there are present errors in the XML response
    local error=$(xpath "$tmpfile" '//fault/detail/text()' 2> /dev/null)
    if [ ! -z "$error" ]; then
        errorexit "$(echo "$error" | tr -d '[]')"
    fi
}

# ovirt-get <url>
function ovirt-get () 
{    
    curl "${defargs[@]}" "${baseurl}${1}" -X 'GET' 2> /dev/null
    checkcurl $?
}

# ovirt-post <url> <data>
function ovirt-post () 
{
    curl "${defargs[@]}" "${baseurl}${1}" -d "${2}" 2> /dev/null
    checkcurl $?
}

# ovirt-delete <url> <data>
function ovirt-delete () 
{
    curl "${defargs[@]}" "${baseurl}${1}" -X 'DELETE' -d "${2}" 2> /dev/null
    checkcurl $?
}

# rotatebck <n> 
function rotatebck() 
{
    #local n=$1
    local n=3 
    local list=( $(ls -1 "${bckdir}") )
    local m

    let "m = ${#list[@]} - $n-1"

    for (( n=0; n<=m; ++n )); do 
		rm -rf "${bckdir}/${list[$n]}"    	
	done
}

#elapsedtime <seconds>
function timerstart() 
{
    _MYTIMER="$(date +%s)"
}

#elapsedtime <seconds>
function elapsedtime() 
{
    local dt="$(( $(date +%s) - _MYTIMER ))"
    local ds=$(( dt%60 ))
    local dm=$(( (dt/60)%60 ))
    local dh=$(( dt/3600 ))

    if [ "$dh" -eq 0 ]; then 
        printf '%02d:%02d' $dm $ds
    else 
        printf '%02d:%02d:%02d' $dh $dm $ds
    fi
}


###############################################################################
## STEP1. Take a snapshot of the virtual machine to be backed up.
###############################################################################

echo "Backup started: '$bckname' ($vmid)"

# create a temporary file, use it for XML responses
# and create a trap to remove it
tmpfile="$(mktemp)"
trap "rm '$tmpfile'" EXIT

# check the status of the virtual machine, exit if its state isn't up
ovirt-get "/vms/$vmid" > "$tmpfile"

# check if snapshot is present
state=$(xpath "$tmpfile" '//vm/status/state/node()' 2> /dev/null)
if [ "$state" != 'up' ]; then
    warning "virtual machine state is '$state', backup skipped"
    exit
fi

# generate xml code to create snapshot
xml="<snapshot><description>$description</description><disks>"
for diskid in "${disks[@]}"; do 
    xml="$xml <disk id=\"${diskid}\"/>"
done
xml="$xml </disks></snapshot>"

# post xml 
ovirt-post "/vms/$vmid/snapshots" "$xml" > "$tmpfile"

# retrieve the id of the snapshot
snapshotid=$(xpath "$tmpfile" '//snapshot/@id' 2> /dev/null | sed -ne 's/.*id="\(.*\).*"/\1/p')

# check snapshotid
if [ -z "$snapshotid" ]; then
    errorexit "cannot retrieve the snapshot id"
fi

# wait snapshot status ok
echo -n "Creating snapshot '$description'"
for (( i=1; i<=10; ++i )); do
    sleep 20
    ovirt-get "/vms/$vmid/snapshots/$snapshotid" > "$tmpfile"
    snapshotstatus=$(xpath "$tmpfile" '//snapshot/snapshot_status/text()' 2> /dev/null)
    if [ "$snapshotstatus" != 'locked' ]; then
        break
    fi
done

if [ "$snapshotstatus" = 'locked' ]; then
    echo ' [FAIL]'
    errorexit "timeout snapshot"
else 
    echo ' [OK]'
fi


###############################################################################
## STEP2. Back up the virtual machine configuration at the time of the snapshot.
###############################################################################
echo -n 'Saving VM configuration'

# create backup directory if it doen't exist
mkdir -p "${bckdir}/${mydate}"

# retrieve the vm configuration 
curl "${defargs[@]}" "${baseurl}/vms/$vmid/snapshots/$snapshotid" \
-H 'All-Content: true' -X 'GET' > "${bckdir}/${mydate}/config_${vmid}" 2> /dev/null
checkcurl $? 

echo ' [OK]'

###############################################################################
## STEP3. Attach the disk snapshots that were created in (1) to the virtual 
## appliance for data backup.
###############################################################################
echo -n 'Attaching snapshot disks'

for (( i=0; i<${#disks[@]}; i++ )); do
    xml="<disk id=\"${disks[$i]}\"><snapshot id=\"$snapshotid\"/><active>true</active></disk>"
    ovirt-post "/vms/$ovbackup/disks" "$xml" > "$tmpfile"
    sleep 2
done

echo ' [OK]'

###############################################################################
## STEP4. Back up the virtual machine disk at the time of the snapshot.
###############################################################################

# create an associative array with device serial as key
declare -A devicemap
for file in `ls -1 /sys/block/*/serial`; do
    key="$(cat $file)"
    devicemap[$key]="$(echo $file | cut -d/ -f4)"
done

# transfer disk snapshots
transferfailed=false # error flag
for (( i=0; i<${#disks[@]}; i++ )); do
    echo -n "Transfering disk '${disks[$i]}'"
    
    timerstart
        
    key="$(expr substr ${disks[$i]} 1 20)"
    devfile="/dev/${devicemap[$key]}"
    dd if="$devfile" of="${bckdir}/${mydate}/${disks[$i]}" 2> /dev/null       
    
    if [ "$?" -ne 0 ]; then
        echo " [FAIL]" 
        echo "data transfer failed: ${disks[$i]}" >&2
        transferfailed=true
        break
    else         
        echo " [OK: $(elapsedtime)]"
    fi
done


###############################################################################
## STEP5. Detach the disk snapshots that were attached in (4) from the 
## virtual appliance.
###############################################################################
echo -n 'Detaching snapshot disks'

xml='<action><detach>true</detach></action>'

for (( i=0; i<${#disks[@]}; i++ )); do
    ovirt-delete "/vms/$ovbackup/disks/${disks[$i]}" "$xml" > "$tmpfile"
    sleep 1
done

echo ' [OK]'


###############################################################################
## STEP6. Shutdown virtual machine, remove its snapshot and power up it again!
###############################################################################
echo -n 'Shutting down VM'

# shutdown the virtual machine
ovirt-post "/vms/$vmid/shutdown" "<action/>" > "$tmpfile"

# wait down state
for (( i=1; i<=10; ++i )); do
    # wait some seconds for the next iteration
    sleep 30
    ovirt-get "/vms/$vmid" > "$tmpfile"
    state=$(xpath "$tmpfile" '//vm/status/state/node()' 2> /dev/null)
    if [ "$state" = 'down' ]; then 
        break
    fi
done

# after the loop if state is down, something went wrong
if [ "$state" != 'down' ]; then
    echo ' [FAIL]'
    errorexit "cannot shutdown virtual machine. Please, manually remove snapshot '$description'"
else 
    echo ' [OK]'
fi

echo -n 'Removing VM snapshot'

# delete the snapshot
ovirt-delete "/vms/$vmid/snapshots/$snapshotid" > "$tmpfile"

# wait until the snapshot is deleted of a time out is occured
for (( i=1; i<=20; ++i )); do 
    sleep 30
    ovirt-get "/vms/$vmid/snapshots" > "$tmpfile"

    # check if snapshot is present
    snapshotid=$(xpath "$tmpfile" '//snapshot/@id' 2> /dev/null | sed -ne 's/.*id="\(.*\).*"/\1/p' | grep "$snapshotid")
    if [ -z "$snapshotid" ]; then 
        break
    fi
done 

# after the loop if snapshotid exists, something went wrong
if [ ! -z "$snapshotid" ]; then
    echo ' [FAIL]'
    errorexit "cannot remove snapshot '$snapshotid'"
else 
    echo ' [OK]'
fi 

echo -n 'Powering up VM'

# power up the virtual machine
ovirt-post "/vms/$vmid/start" '<action/>' > "$tmpfile"

if ( ! ${transferfailed} ); then 
    # remove old backup
    rotatebck
else 
    rm -rf "${bckdir}/${mydate}"
fi

# wait up state
state='down'
for (( i=1; i<=10; ++i )); do
    sleep 30
    # check status
    ovirt-get "/vms/$vmid" > "$tmpfile"

    state=$(xpath "$tmpfile" '//vm/status/state/node()' 2> /dev/null)
    if [ "$state" = 'up' ]; then
        break
    fi
done


# after the loop if state is down, something went wrong
if [ "$state" != 'up' ]; then
    echo ' [FAIL]'
    errorexit "cannot power up the virtual machine"
else 
    echo ' [OK]'
fi

if ( ${transferfailed} ); then 
    echo "Backup failed"
    exit 1
else 
    echo "Backup completed"
fi
