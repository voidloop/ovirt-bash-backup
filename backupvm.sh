#!/bin/bash

if [ "$#" -lt 3 ]; then
    echo "usage: $0 <backup-name> <vm-id> <disk-id>..."
    exit 1
fi

# These two variables are exported in the main script
# for security purpose with GitHub. The main script is here:
#
#   /usr/local/backup/ovirtbackup.sh
#
# If you wart test or use standalone the script remove 
# comments and define the variables here.
#username='admin@internal'
#password='<xxxxxxxxxxxxx>'
#baseurl='https://.....'


# machine for the dd commands (local machine)
ovbackup='215c6557-7357-4cd9-ba69-9fcb6cb061bc'

mydate="$(date '+%Y%m%d%H%M')"
description="backup-$mydate"

# default arguments to curl command
defargs=('-k' '-u' "$username:$password" '-H' 'Content-type: application/xml')

# backup name or alias
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


###############################################################################
## STEP1. Take a snapshot of the virtual machine to be backed up.
###############################################################################

echo "Backup started: '$bckname' ($vmid)"

# create a temporary file, use it for XML responses
# and create a trap to remove it
tmpfile="$(mktemp)"
trap "rm '$tmpfile'" EXIT

# check the status of the virtual machine, exit if its state isn't up
ovirt-get "/api/vms/$vmid" > "$tmpfile"

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
ovirt-post "/api/vms/$vmid/snapshots" "$xml" > "$tmpfile"

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
    ovirt-get "/api/vms/$vmid/snapshots/$snapshotid" > "$tmpfile"
    snapshotstatus=$(xpath "$tmpfile" '//snapshot/snapshot_status/text()' 2> /dev/null)
    if [ "$snapshotstatus" != 'locked' ]; then
        break
    fi
    
    # print a dot every minute
    [ $(expr "$i" '%' '3') -eq 0 ] && echo -n '.'
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
curl "${defargs[@]}" "${baseurl}/api/vms/$vmid/snapshots/$snapshotid" \
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
    ovirt-post "/api/vms/$ovbackup/disks" "$xml" > "$tmpfile"
    sleep 2
done

echo ' [OK]'

###############################################################################
## STEP4. Back up the virtual machine disk at the time of the snapshot.
###############################################################################
echo "Data transfer:"

# create an associative array with device serial as key
declare -A devicemap
for file in `ls -1 /sys/block/*/serial`; do
    key="$(cat $file)"
    devicemap[$key]="$(echo $file | cut -d/ -f4)"
done

# transfer disk snapshots
for (( i=0; i<${#disks[@]}; i++ )); do
    key="$(expr substr ${disks[$i]} 1 20)"
    devfile="/dev/${devicemap[$key]}"
    #dd if="$diskdev" of="${bckdir}/${mydate}/${disks[$i]}"
    devsize=$(/sbin/blockdev --getsize64 "$devfile")
    dd if="$devfile" 2> /dev/null | pv -N "${disks[$i]}" -s "$devsize" | \
    dd of="${bckdir}/${mydate}/${disks[$i]}" 2> /dev/null
    if [ "${PIPESTATUS[0]}" -ne 0 ]; then
        errorexit "data transfer failed"
    fi
done


###############################################################################
## STEP5. Detach the disk snapshots that were attached in (4) from the 
## virtual appliance.
###############################################################################
echo -n 'Detaching snapshot disks'

xml='<action><detach>true</detach></action>'

for (( i=0; i<${#disks[@]}; i++ )); do
    ovirt-delete "/api/vms/$ovbackup/disks/${disks[$i]}" "$xml" > "$tmpfile"
    sleep 1
done


echo ' [OK]'


###############################################################################
## STEP6. Shutdown virtual machine, remove its snapshot and power up it again!
###############################################################################
echo -n 'Shutting down VM'

# shutdown the virtual machine
ovirt-post "/api/vms/$vmid/shutdown" "<action/>" > "$tmpfile"

# wait down state
for (( i=1; i<=10; ++i )); do
    # wait some seconds for the next iteration
    sleep 30
    ovirt-get "/api/vms/$vmid" > "$tmpfile"
    state=$(xpath "$tmpfile" '//vm/status/state/node()' 2> /dev/null)
    if [ "$state" = 'down' ]; then 
        break
    fi

    # print a dot every minute
    [ $(expr "$i" '%' '2') -eq 0 ] && echo -n '.'
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
ovirt-delete "/api/vms/$vmid/snapshots/$snapshotid" > "$tmpfile"

# wait until the snapshot is deleted of a time out is occured
for (( i=1; i<=20; ++i )); do 
    sleep 30
    ovirt-get "/api/vms/$vmid/snapshots" > "$tmpfile"

    # check if snapshot is present
    snapshotid=$(xpath "$tmpfile" '//snapshot/@id' 2> /dev/null | sed -ne 's/.*id="\(.*\).*"/\1/p' | grep "$snapshotid")
    if [ -z "$snapshotid" ]; then 
        break
    fi

    # print a dot every minute
    [ $(expr "$i" '%' '2') -eq 0 ] && echo -n '.'
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
ovirt-post "/api/vms/$vmid/start" '<action/>' > "$tmpfile"

# remove old backup
rotatebck

# wait up state
state='down'
for (( i=1; i<=10; ++i )); do
    sleep 30
    # check status
    ovirt-get "/api/vms/$vmid" > "$tmpfile"

    state=$(xpath "$tmpfile" '//vm/status/state/node()' 2> /dev/null)
    if [ "$state" = 'up' ]; then
        break
    fi

    # print a dot every minute
    [ $(expr "$i" '%' '2') -eq 0 ] && echo -n '.'
done


# after the loop if state is down, something went wrong
if [ "$state" != 'up' ]; then
    echo ' [FAIL]'
    errorexit "cannot power up the virtual machine"
else 
    echo ' [OK]'
fi
