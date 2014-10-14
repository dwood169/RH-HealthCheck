#!/bin/bash

############################################################################
#
#  This script was created for general use. 
#  Created By: David Wood
#  Date: 3-19-14
#  Purpose: This script will search through ALOT of sos reports and preform a health check on each system.  The output will be a csv with relevant details
#  Assumptions: SOS Reports are provided and still compressed
#
############################################################################

SOSDIR="/sosreports"
OUTPUT="/healthcheck.csv"

#Loop around uncompressing stuff, preforming checks, then removing expanded files

cd ${SOSDIR}
SOSCOUNT=$(ls | egrep -c "bz2$|xz$")
COUNTER=1
echo "Reportname,Hostname,OS,Kernel,HW Type,CPU Count,RAM(MB),Cache Ram(MB),HugePages(MB),Wasted Hugepages,Root Login,selinux,Oracle,Local Home,tmp separate,var separate,Nic Bonded,Kdump,Kernel Tainted,NIC Error,sysctl dups,NTP,Uptime,FS full,NFS Share,Syslog Server,Clustered,Cluster Status" > ${OUTPUT}
for SOSREPORT in $(ls | egrep "bz2$|xz$")
do
	#echo -ne "${COUNTER}/${SOSCOUNT} --- ${SOSREPORT}\r"
	echo "${COUNTER}/${SOSCOUNT} --- ${SOSREPORT}"
	REPORTNAME=${SOSREPORT}
	#Uncompress
	TYPE=$(file -b ${SOSREPORT} | awk '{ print $1 }')
	if [ "${TYPE}" = "xz" ]; then
		xz -dk ${SOSREPORT}
		TARNAME=$(echo ${SOSREPORT} | sed 's/.xz//')
	fi
	if [ "${TYPE}" = "bzip2" ]; then
		bunzip2 -k ${SOSREPORT}
		TARNAME=$(echo ${SOSREPORT} | sed 's/.bz2//')
	fi
	tar xvf ${TARNAME} > /dev/null 2>&1
	SOSEXPANDED=$(tar -tf ${TARNAME} | head -1)
	rm -f ${TARNAME}

	#Run some checks on the sos report now
	cd ${SOSEXPANDED}
	HOSTNAME=$(cat hostname)
	#Check if its a VM
	HWMAN=$(grep Manufacturer: dmidecode | head -1 | awk '{ print $2 }')
	#xen messes with us by not actually having dmi info so it shows up as blank
	if [ -z ${HWMAN} ]; then
		HWMAN="Probably XEN"
	fi
	case ${HWMAN} in
		[VMware]*)
			#Use this to get rid of extra comma because I changed my mind on how to parse this and didnt want to update it.
			HARDWARE="VMware"
			;;
		
		*)
			HARDWARE=${HWMAN}
			;;
	esac
#OS Version
	OS=$(cat etc/redhat-release)
	KERNELVERS=$(cat uname | awk '{ print $3 }')
#Check if kdump is enabled
	KDUMP="Disabled"
	KERNELCOUNT=$(grep -c title boot/grub/grub.conf)
	KDUMPCOUNT=$(grep -c crashkernel boot/grub/grub.conf)
	if [ ${KERNELCOUNT} -eq ${KDUMPCOUNT} ]; then
		KDUMP="Enabled"
	fi
#Check if kernel is tainted
	TAINTED="true"
	KT=$(grep kernel.tainted sos_commands/kernel/sysctl_-a | awk '{ print $NF }')
	if [ "${KT}" = "0" ]; then
		TAINTED="false"
	fi
#Check if logs are forwarded to syslog server
	if [ -f etc/rsyslog.conf ]; then
		SYSLOGFILE="etc/rsyslog.conf"
	elif [ -f etc/syslog.conf ]; then
                SYSLOGFILE="etc/syslog.conf"
	fi
	SYSLOG=$(grep -v '^#' ${SYSLOGFILE} | grep -c '@')
	if [ ${SYSLOG} = 0 ]; then
		LOGSERVER="None"
	else
		LOGSERVER=$(grep -v '^#' ${SYSLOGFILE} | grep '@' | awk '{ print $NF }')
	fi
#Check for full FS
	FSFULL="Not Full"
	FSSIZES=$(grep % sos_commands/filesys/df_-al | awk '{ i=NF-1; print $i }' | sed 's/%//g' | grep -v Mounted)
	for FSPERCENT in $( echo ${FSSIZES})
	do
		[ ${FSPERCENT} -gt 90 ] && FSFULL="Full"
	done
#Check for dup sysctl entries
	SYSCTL=$(grep -v ^# etc/sysctl.conf | grep -v "^$" | awk '{ print $1 }' | uniq -d | wc -l)
#CPU COUNT
	CPUCOUNT=$(grep -c processor proc/cpuinfo)
#Get some network details
	NICERROR=$(cat ifconfig | grep error | awk '{ print $3 }' | awk -F: '{ print $2 }' | sort | tail -1 )
#RAM
	RAMKB=$(grep MemTotal: proc/meminfo | awk '{ print $2 }')
	RAMMB=$(echo "${RAMKB}/1024" | bc)
	WASTEDRAMKB=$(grep cache: free | awk '{ print $4 }')
	WASTEDRAMMB=$(echo "${WASTEDRAMKB}/1024" | bc)
#NFS share count
	NFSSHARE=$(egrep -v -c "^/dev|^#|tmpfs|devpts|sysfs|proc|^LABEL" etc/fstab)
#Huge pages
	HUGEPAGESCOUNT=$(grep HugePages_Total: proc/meminfo | awk '{ print $2 }')
	HUGEPAGESSIZE=$(grep Hugepagesize: proc/meminfo | awk '{ print $2 }')
	#HUGEPAGES=$(echo "${HUGEPAGESSIZE}*${HUGEPAGESCOUNT}/1024" | bc)
	HUGEPAGES=${HUGEPAGESCOUNT}
	HPFREECOUNT=$(grep HugePages_Free: proc/meminfo | awk '{ print $2 }')
	#UNUSEDHUEPAGES=$(echo "${HUGEPAGESSIZE}*${HPFREECOUNT}/1024" | bc)
	UNUSEDHUEPAGES=$(echo "${HUGEPAGESCOUNT}-${HPFREECOUNT}" | bc)
#SELINUX
	if [ -f sos_commands/selinux/sestatus_-b ]; then
		SELINUX=$(grep status sos_commands/selinux/sestatus_-b | awk '{ print $NF }')
	fi
	if [ -f sos_commands/selinux/sestatus ]; then
		SELINUXSTAT=$(grep status sos_commands/selinux/sestatus | awk '{ print $NF }')
		if [ "${SELINUXSTAT}" = "enabled" ]; then
			SELINUX=$(grep mode sos_commands/selinux/sestatus | awk '{ print $NF }')
		else
			SELINUX="disabled"
		fi
	fi
#Check if oracle is running
	if [ $(grep -c oracle ps) -eq 0 ]; then 
		ORACLE="False"
	else
		ORACLE="True"
	fi
#Check if /home is being mounted locally
        HOME=$(egrep -m 1 "^/dev" etc/fstab | awk ' $2 =/\/home/ { print "Yes" }')
	[ -z ${HOME} ] && HOME="No"
#Check uptime
	UPTIME=$(awk -F, '{ print $1 }' uptime | awk '{ print $3 }' )
#Check nic bonding
	BOND=$(cat etc/sysconfig/network-scripts/ifcfg* | grep -c bond )
#Check if iptables is set to be enabled at default run level
#	DEFRUNLEVEL=3
#	FIELD=$(echo "2+${DEFRUNLEVEL}" | bc)
#	IPTSTAT=$(grep iptab chkconfig | awk '{ print $5 }' | awk -F: '{ print $2 }'

#Check if the system is in a rhel cluster and get status
	CLUSTER=$([ -f etc/cluster/cluster.conf ] && echo "yes" || echo "no")
	if [ -f etc/cluster/cluster.conf ]; then
		CLUSTAT=$(grep "Member Status" sos_commands/cluster/clustat | awk -F: '{ print $2 }')
	else
		CLUSTAT="NA"
	fi
#Can root login remotely
	ROOTLOGIN=$(grep ^PermitRootLogin etc/ssh/sshd_config || echo "yes")

#Is tmp and var on their own partitions
	TMPCOUNT=$(cat df | grep -c /tmp$)
	TMP="Yes"
	if [ ${TMPCOUNT} -eq 0 ]; then
		TMP="No"
	fi
	VARCOUNT=$(cat df | grep -c /var$)
	VAR="Yes"
	if [ ${VARCOUNT} -eq 0 ]; then
		VAR="No"
	fi

#Is NTP setup and used
	NTP=$(grep correct sos_commands/ntp/ntpstat | awk '{ print $5" "$6 }')
	if [ -z "${NTP}" ]; then
		NTP="Failed"
	fi

#Print out the csv format entry for system
	echo "${REPORTNAME},${HOSTNAME},${OS},${KERNELVERS},${HARDWARE},${CPUCOUNT},${RAMMB},${WASTEDRAMMB},${HUGEPAGES},${UNUSEDHUEPAGES},${ROOTLOGIN},${SELINUX},${ORACLE},${HOME},${TMP},${VAR},${BOND},${KDUMP},${TAINTED},${NICERROR},${SYSCTL},${NTP},${UPTIME},${FSFULL},${NFSSHARE},${LOGSERVER},${CLUSTER},${CLUSTAT}" >> ${OUTPUT}

	#Remove the expanded sos report since we are done with it
	cd ..
	rm -rf ${SOSEXPANDED}
	let COUNTER=COUNTER+1
done
echo ""
