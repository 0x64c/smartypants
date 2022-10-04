#!/bin/bash
#run as root
#required packages:
#smartmontools bc expect jq screen openssh core coreutils

RED='\033[0;91m'
GREEN='\033[0;32m'
BLUE='\033[0;94m'
YELLOW='\033[0;93m'
NC='\033[0m'

TARGET_DRIVE=$1
TARGET_BLOCKDEV=
SMART_DATA=
POLLING_SHORT=
POLLING_LONG=
SHORT_TESTED=FALSE
LONG_TESTED=FALSE
SHREDDED=FALSE

#populate a list of drives and wait until the drive we want shows up
#also exclude any drive that's mounted as the root fs
function find_drives {
	EXCLUDE=$(mount|grep "on / "|cut -d' ' -f1|sed 's/[0-9]//g'|cut -d'/' -f3)
	mapfile -t ALL_DRIVES < <(find /dev -type b -regex '/dev/sd[a-z]+' ! -name "$(echo $EXCLUDE)*")
	while [ $TARGET_DRIVE -ge ${#ALL_DRIVES[@]} ]; do
		clear
		echo "Waiting for drive..."
		sleep 10
		mapfile -t ALL_DRIVES < <(find /dev -type b -regex '/dev/sd[a-z]+' ! -name "$(echo $EXCLUDE)*")
	done
	echo "Found $(echo ${ALL_DRIVES[$TARGET_DRIVE]})"
	TARGET_BLOCKDEV="${ALL_DRIVES[$TARGET_DRIVE]}"
}

function grab_smart_json {
	SMART_DATA=$(smartctl -aj $TARGET_BLOCKDEV)
}

function print_stats {
	clear

	#extract data from json
	#info
	FAMILY=$(jq -r '.model_family' <<< ${SMART_DATA})
	MODEL=$(jq -r '.model_name' <<< ${SMART_DATA})
	SERIAL=$(jq -r '.serial_number' <<< ${SMART_DATA})
	CAPACITY=$(jq -r '.user_capacity.bytes' <<< ${SMART_DATA})
	SECTOR=$(jq -r '.physical_block_size' <<< ${SMART_DATA})

	#selftest
	STATUS_TEXT=$(jq -r '.ata_smart_data.self_test.status.string' <<< ${SMART_DATA})
	STATUS_PASSED=$(jq -r '.ata_smart_data.self_test.status.passed' <<< ${SMART_DATA})

	#polling times (minutes)
	POLLING_SHORT=$(jq -r '.ata_smart_data.self_test.polling_minutes.short' <<< ${SMART_DATA})
	POLLING_LONG=$(jq -r '.ata_smart_data.self_test.polling_minutes.extended' <<< ${SMART_DATA})

	#attributes
	REALLOC_SECTOR=$(jq -r '.ata_smart_attributes.table[] | select(.id==5) .raw.string' <<< ${SMART_DATA} |cut -d' ' -f1|bc)
	PENDING_SECTOR=$(jq -r '.ata_smart_attributes.table[] | select(.id==197) .raw.string' <<< ${SMART_DATA} |cut -d' ' -f1|bc)
	POWER_ON_TIME=$(jq -r '.ata_smart_attributes.table[] | select(.id==9) .raw.value' <<< ${SMART_DATA})
	POWER_ON_TIME_UNIT=$(jq -r '.ata_smart_attributes.table[] | select(.id==9) .name' <<< ${SMART_DATA} |cut -d'_' -f3,4)
	
	#logs

	#for debugging edge cases, uncomment this
	#echo $POWER_ON_TIME_UNIT
	#convert to hours from seconds if necessary
	if [ "${POWER_ON_TIME_UNIT,,}" = "seconds" ]; then
		POWER_ON_TIME=$( echo $POWER_ON_TIME/3600 |bc )
	fi
	#convert from half-minutes to hours
	if [ "${POWER_ON_TIME_UNIT,,}" = "half_minutes" ]; then
		POWER_ON_TIME=$( echo $POWER_ON_TIME/120 |bc )
	fi 
	#human-readible disk capacity
	CAPACITY_STRING=$(numfmt --to=si --suffix=B --round=down $CAPACITY)

	#print the information with colour
	echo -e "Family: ${BLUE}$FAMILY${NC}"
	echo -e "Model: ${BLUE}$MODEL${NC}"
	echo -e "Serial: ${BLUE}$SERIAL${NC}"
	echo -e "Capacity: ${BLUE}$CAPACITY_STRING${NC}"
		#Sector Size: ${BLUE}$SECTOR"${NC}
	TEST_RESULT_COLOUR=
	if [[ $STATUS_PASSED == "true" ]]; then
		TEST_RESULT_COLOUR=$GREEN
	elif [[ $STATUS_PASSED == "false" ]]; then
		TEST_RESULT_COLOUR=$RED
	else
		TEST_RESULT_COLOUR=$YELLOW
	fi
	echo -e "Test Results: ${TEST_RESULT_COLOUR}$STATUS_TEXT${NC}"

	REALLOC_COLOUR=
	PENDING_COLOUR=
	POWER_COLOUR=
	[[ $REALLOC_SECTOR -eq 0 ]] && REALLOC_COLOUR=$GREEN || REALLOC_COLOUR=$RED
	[[ $PENDING_SECTOR -eq 0 ]] && PENDING_COLOUR=$GREEN || PENDING_COLOUR=$RED
	if [[ $POWER_ON_TIME -gt 20000 ]]; then
		POWER_COLOUR=$RED
	elif [[ $POWER_ON_TIME -gt 10000 ]]; then
		POWER_COLOUR=$YELLOW 
	else
		POWER_COLOUR=$GREEN
	fi
	
	echo -e "Realloc: ${REALLOC_COLOUR}$REALLOC_SECTOR${NC} Pending: ${PENDING_COLOUR}$PENDING_SECTOR${NC} Hours: ${POWER_COLOUR}$POWER_ON_TIME${NC}"
	echo -e "Short:${YELLOW}$SHORT_TESTED${NC} Long:${YELLOW}$LONG_TESTED${NC} Erased:${YELLOW}$SHREDDED${NC}"
	printf "\n"

	#print the test logs
	echo "Time  Status"
	jq '.ata_smart_self_test_log.standard.table|sort_by(.lifetime_hours)|reverse|.[]|[.lifetime_hours,.status.string,.status.passed]|join(",")' <<<${SMART_DATA}|head -n 6|while read line; do
		C1=$(echo ${line//\"}|cut -d',' -f1)
		LEN=`expr length "$C1"`
		C2=$(echo ${line//\"}|cut -d',' -f2)
		C3=$(echo ${line//\"}|cut -d',' -f3)
		STATUS_COLOUR=
		if [[ $C3 = "true" ]]; then
			STATUS_COLOUR=$GREEN
		elif [[ $C3 = "false" ]]; then
			STATUS_COLOUR=$RED
		else
			STATUS_COLOUR=$YELLOW
		fi
		printf "%-5s " $C1
		echo -e ${STATUS_COLOUR}$C2${NC}
	done

}

#run a short self-test
function smart_short {
	smartctl -q silent -X $TARGET_BLOCKDEV
	smartctl -q silent -t short $TARGET_BLOCKDEV
	echo "Waiting $POLLING_SHORT Minutes for test to complete."
	RUNTIME=0
	while [[ $RUNTIME -lt $POLLING_SHORT ]] ; do
		grab_smart_json
		print_stats
		printf "\n"
		echo "Conducting short self-test..."
		sleep 60
		RUNTIME=$((RUNTIME+1))
	done
	SHORT_TESTED=TRUE
}

#run an extended self-test
function smart_long {
	smartctl -q silent -X $TARGET_BLOCKDEV
	smartctl -q silent -t long $TARGET_BLOCKDEV
	echo "Waiting $POLLING_LONG Minutes for test to complete."
	RUNTIME=0
	while [[ $RUNTIME -lt $POLLING_LONG ]] ; do
		grab_smart_json
		print_stats
		printf "\n"
		echo "Conducting long self-test..."
		sleep 60
		RUNTIME=$((RUNTIME+1))
	done
	LONG_TESTED=TRUE
}

function shred_disk {
	echo "Erase all data on disk? y\n"
	while : ; do
		read -s -n 1 k <&1
		if [[ $k = y ]] ; then
			echo "You asked for it!"
			unbuffer shred -n 0 -vz $TARGET_BLOCKDEV|sed 's/^shred: //g;s/pass 1\/1 (000000)...//g'
			SHREDDED=TRUE
			break
		elif [[ $k = n ]] ; then
			break
		fi
	done
}

function print_data {
	clear
	smartctl -a $TARGET_BLOCKDEV|less -S
}

function main {
	QUIT=
	while [[ QUIT -lt 1 ]]; do
		grab_smart_json
		print_stats
		#beep!
		printf '\a'
		#print input prompt
		echo "Command? Short: t  Long: l  Refresh: r"
		echo "         Exit:  e  Wipe: z  Data:    i"
		while : ; do
			read -s -n 1 k <&1
			if [[ $k = t ]]; then
				echo "Running short test..."
				smart_short
				break
			elif [[ $k = l ]]; then
				echo "Running long test..."
				smart_long
				break
			elif [[ $k = i ]]; then
				print_data
				break
			elif [[ $k = r ]]; then
				break
			elif [[ $k = z ]]; then
				shred_disk
				break
			elif [[ $k = e ]]; then
				echo "cya!"
				QUIT=1
				break
			fi
		done
	done
}

if [ ! -z "$2" ]; then
	echo "This is the part where we log in to another machine"
	sshpass -p${3} ssh -o 'StrictHostKeyChecking no' -t $2 "${4} ${1}"
else

find_drives
main

fi
exit

	
