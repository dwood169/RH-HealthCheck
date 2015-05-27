#!/bin/bash

##############################################################################
#                                                                            #
#  This script was created for general use.                                  #
#  Created By: David Wood                                                    #
#  Created: 2014-03-19                                                       #
#  Purpose: This script will search through ALOT of sos reports and preform  #
#  a health check on each system.  The output will be a csv with relevant    #
#  details                                                                   #
#  Assumptions:                                                              #
#    (1) SOS Reports are provided and still compressed                       #
#    (2) Directory containing compressed SOS Report is in $PWD               #
#                                                                            #
##############################################################################

##############################################################################
#  Rev01:   2015-05-27                                                       #
# - Change "tar xvf" to "tar xf" for the *.xz compressed files               #
# - Added checks for the following:                                          #
#   + /var/log                                                               #
#   + /var/log/audit on separatate partition                                 #
# - Corrected syntax to locate duplicate entries in /etc/sysctl.conf         #
# - Use here text instead of echo-ing long string                            #
# - Add one additional case HWMAN "Red Hat" to the case/esac stanza          #
# - Add sysstat package install and sysstat chkconfig status (2 columns)     #
# - Calculate total memory used from dmedecode output                        #
# - Add default runlevel check                                               #
# - Count number of installed packages                                       #
# - Correct the "NFSSHARE" count to exclude blank lines (^$), and UUID       #
#   mounts (^UUID)                                                           #
#                                                                            #
##############################################################################

# SOSDIR="/svnrepo/users/dwood/accounts/lifepoint/sosreports"
# OUTPUT="/svnrepo/users/dwood/accounts/lifepoint/healthcheck.csv"

WHOAMI=$(whoami)
CWD=$PWD
SOSDIR=${CWD}/sosreport
OUTPUT="${CWD}/healthcheck.csv"

#We need xsos to cheat around the process. Go fetch xsos if you don't have it
CHECK_XSOS=$(which xsos)
if [ -z "${CHECK_XSOS}" ]
then
   echo "xsos commmand is not available. Need to install xsos first"
   echo "Hint: https://github.com/ryran/xsos"
   exit 1
fi

#Loop around uncompressing stuff, preforming checks, then removing expanded files
cd ${SOSDIR}
SOSCOUNT=$(ls | egrep -c "bz2$|xz$")
COUNTER=1

#Print out the csv format entry for system
cat << EOF > ${OUTPUT}
Report Name,Hostname,\
HW Type,RAM(GB),RAM USED(GB),CPU Count,CPU Type,\
Disks,Disk Size(GB),OS,Kernel,\
Cache Ram(MB),HugePages(MB),Wasted Hugepages,\
Runlevel,Installed Packages,Root Login,SELinux,IPTables,\
Oracle,Local Home,tmp separate,var separate,var-log separate,var-log-audit separate,\
Nic Bonded,Grub kdump Enabled,kexec-tools installed,kdump Service Enabled,\
Kernel Tainted,NIC Error,\
sysctl dups,NTP,Uptime,FS full,NFS Share,Syslog Server,\
sysstat package,sysstat service,\
Clustered,Cluster Status
EOF

# Reminders for future revision
#  (1) Need to look for duplicate entries in /etc/security/limits
#  (2) Check /etc/security/limits.d/* for duplicate location

for SOSREPORT in $(ls | egrep "bz2$|xz$")
do
   echo "${COUNTER}/${SOSCOUNT} --- ${SOSREPORT}"
   REPORTNAME=${SOSREPORT}
   #Uncompress
      TYPE=$(file -b ${SOSREPORT} | awk '{ print $1 }')
      if [ "${TYPE}" = "XZ" ]
      then
         xz -dk ${SOSREPORT}
         TARNAME=$(echo ${SOSREPORT} | sed 's/.xz//')
      fi
      if [ "${TYPE}" = "bzip2" ]
      then
         bunzip2 -k ${SOSREPORT}
         TARNAME=$(echo ${SOSREPORT} | sed 's/.bz2//')
      fi
      tar xf ${TARNAME} > /dev/null 2>&1
      SOSEXPANDED=$(tar -tf ${TARNAME} | head -1)
      rm -f ${TARNAME}
   #Run some checks on the sos report now
      cd ${SOSEXPANDED}
      HOSTNAME=$(cat hostname) 
   #Check if its a VM
      HWMAN=$(grep Manufacturer: dmidecode | head -1 | awk '{ print $2 }')
      # Done
   #xen messes with us by not actually having dmi info so it shows up as blank
      if [ -z ${HWMAN} ]
      then
         HWMAN="Probably XEN"
      fi
      case ${HWMAN} in
         [VMware]*)
            #Use this to get rid of extra comma because I changed my mind on how to
            #parse this and didnt want to update it.
            HARDWARE="VMware"
            ;;
         [Red]*)
            HARDWARE="Red Hat"
            ;;
         *)
            HARDWARE=${HWMAN}
            ;;
      esac
   #OS Version
      RELEASE=$(awk '{ print $7 }' etc/redhat-release)
      OS=$(echo RHEL ${RELEASE})
      KERNELVERS=$(cat uname | awk '{ print $3 }')
   #Check if kdump is enabled
      #kdump settings: See https://access.redhat.com/solutions/6038
      GRUBKDUMP="Disabled"
      KERNELCOUNT=$(grep -c title boot/grub/grub.conf)
      KDUMPCOUNT=$(grep -c crashkernel boot/grub/grub.conf)
      if [ ${KERNELCOUNT} -eq ${KDUMPCOUNT} ]
      then
         GRUBKDUMP="Enabled"
      fi
   #kexec-tools installed
      KEXECTOOLS="Yes"
      myvar=$(grep kexec-tools installed-rpms)
      if [ -z "${myvar}" ]
      then
         KEXECTOOLS="No"
      fi
   #kdump service starting on reboot
      KDUMPSERVICE="Yes"
      myvar=$(grep kdump chkconfig | egrep '3:on|4:on|5:on')
      if [ -z "${myvar}" ]
      then
         KDUMPSERVICE="No"
      fi
   #Check if kernel is tainted
      TAINTED="true"
      KT=$(grep kernel.tainted sos_commands/kernel/sysctl_-a | awk '{ print $NF }')
      if [ "${KT}" = "0" ]
      then
         TAINTED="false"
      fi
   #Check if logs are forwarded to syslog server
      if [ -f etc/rsyslog.conf ]
      then
         SYSLOGFILE="etc/rsyslog.conf"
      else
         SYSLOGFILE="etc/syslog.conf"
      fi
      SYSLOG=$(grep -v '^#' ${SYSLOGFILE} | grep -c '@')
      if [ ${SYSLOG} = 0 ]
      then
         LOGSERVER="None"
      else
         LOGSERVER=$(grep -v '^#' ${SYSLOGFILE} | grep '@' | awk '{ print $NF }')
      fi
   #Check for full FS
      FSFULL="Not Full"
      FSSIZES=$(grep % sos_commands/filesys/df_-al | \awk '{ i=NF-1; print $i }' | sed 's/%//g' | grep -v Mounted)
      for FSPERCENT in $( echo ${FSSIZES})
      do
         [ ${FSPERCENT} -gt 90 ] && FSFULL="Full"
      done
   #Check for duplicate sysctl entries
      FILE="etc/sysctl.conf"
      SYSCTL=$(egrep -v '^#|^$' ${FILE} | awk '{ print $1 }' | sort | uniq -d | wc -l)
      COUNT=$(egrep -v '^#|^$' ${FILE} | awk '{ print $1 }' | sort | uniq -d | wc | awk '{print $2}')
      if [[ ${SYSCTL} > 1 ]]; then
         DUPL=$(egrep -v '^#|^$' ${FILE} | awk '{ print $1 }' | sort | uniq -d)
         echo ""; echo "${HOSTNAME} etc/sysctl.conf file:"
         for i in ${DUPL}; do
            grep --color=auto ${i} ${FILE}
         done
         echo "=========================="
         echo "Press a key to continue..."; read aok
      fi
      # Check Completed
   #CPU COUNT
      CPUCOUNT=$(grep -c processor proc/cpuinfo)
      # Count completed
   #CPU Info
      CPUTYPE=$(awk -F: '/^model name/{print $2; exit}' proc/cpuinfo)
      # Done
   #Get some network details
      NICERROR=$(cat ifconfig | grep error | awk '{ print $3 }' | awk -F: '{ print $2 }' | sort | tail -1 )
      # Done
   #RAM
      RAMMB=$(awk 'BEGIN { RS="\nHandle" } /Physical Memory Array|Memory Device/' dmidecode | \
          awk -vH3="${c[H3]}" -vH2="${c[H2]}" -vH0="${c[0]}" -vH_IMP="${c[Imp]}" ' \
          /Size:/ { if ($2 ~ /^[0-9]/) { SumRam+=$2 } } /Maximum Capacity:/ { MaxRam = $3" "$4 } END { print SumRam }')
      if [[ ${RAMMB} -gt "0" ]]
      then
         RAMGB=$(echo "${RAMMB}/1024" | bc )
      else
         RAMGB="unknown"
      fi
      WASTEDRAMKB=$(grep cache: free | awk '{ print $4 }')
      if [[ ${WASTEDRAMKB} -gt "0" ]]
      then
         WASTEDRAMMB=$(echo "${WASTEDRAMKB}/1024" | bc )
      else 
         WASTEDRAMMB="unknown"
      fi
   #NFS share count
      NFSSHARE=$(egrep -v -c "^/dev|^UUID|^#|^$|tmpfs|devpts|sysfs|proc|^LABEL" etc/fstab)
      # Done
   #Hugepages
      HUGEPAGESCOUNT=$(grep HugePages_Total: proc/meminfo | awk '{ print $2 }')
      HUGEPAGESSIZE=$(grep Hugepagesize: proc/meminfo | awk '{ print $2 }')
      HUGEPAGES=${HUGEPAGESCOUNT}
      HPFREECOUNT=$(grep HugePages_Free: proc/meminfo | awk '{ print $2 }')
      UNUSEDHUEPAGES=$(echo "${HUGEPAGESCOUNT}-${HPFREECOUNT}" | bc )
   #SELINUX
      if [ -f sos_commands/selinux/sestatus_-b ]
      then
         SELINUX=$(grep status sos_commands/selinux/sestatus_-b | awk '{ print $NF }')
      fi
      if [ -f sos_commands/selinux/sestatus ]
      then
         SELINUXSTAT=$(grep status sos_commands/selinux/sestatus | awk '{ print $NF }')
         if [ "${SELINUXSTAT}" = "enabled" ]
         then
            SELINUX=$(grep mode sos_commands/selinux/sestatus | awk '{ print $NF }')
         else
            SELINUX="disabled"
         fi
      fi
   #Check if oracle is running
      if [ $(grep -c oracle ps) -eq 0 ]
      then 
         ORACLE="False"
      else
         ORACLE="True"
      fi
   #Check if /home is being mounted locally
      HOME=$(egrep -m 1 "^/dev" etc/fstab | awk ' $2 =/\/home/ { print "Yes" }')
      [ -z ${HOME} ] && HOME="No"
   #Check uptime
      UPTIME=$(awk -F, '{ print $1 }' uptime | awk '{ print $3 }' )
      # Done
   #Check nic bonding
      BOND=$(cat etc/sysconfig/network-scripts/ifcfg* | grep -c bond )
      # Done
   #Check for iptables to start on runlevel 2,3,4,5
      IPTABLES_CHKCONFIG="On"
      myvar=$(grep iptables chkconfig | egrep '2:on|3:on|4:on|5:on')
      if [ -z "${myvar}" ]
      then
         IPTABLES_CHKCONFIG="Off"
      fi
   #Check if the system is in a rhel cluster and get status
      CLUSTER=$([ -f etc/cluster/cluster.conf ] && echo "yes" || echo "no")
      if [ -f etc/cluster/cluster.conf ]
      then
         CLUSTAT=$(grep "Member Status" sos_commands/cluster/clustat | awk -F: '{ print $2 }')
      else
         CLUSTAT="NA"
      fi
   #Can root login remotely
      ROOTLOGIN=$(grep ^PermitRootLogin etc/ssh/sshd_config || echo "yes")
      # Done
   #Filesystems on their own partitions
      #/tmp
      TMPCOUNT=$(cat df | grep -c /tmp$)
      TMP="Yes"
      if [ ${TMPCOUNT} -eq 0 ]
      then
         TMP="No"
      fi

      #/var
      VARCOUNT=$(cat df | grep -c /var$)
      VAR="Yes"
      if [ ${VARCOUNT} -eq 0 ]
      then
         VAR="No"
      fi
      #/var/log
      VAR_LOG_COUNT=$(grep -c /var/log$ df)        
      VAR_LOG="Yes"
      if [ ${VAR_LOG_COUNT} -eq 0 ]
      then
         VAR_LOG="No"
      fi
      #/var/log/audit
      VAR_LOG_AUDIT_COUNT=$(grep -c /var/log/audit$ df)
      VAR_LOG_AUDIT="Yes"
         if [ ${VAR_LOG_AUDIT_COUNT} -eq 0 ]
         then
            VAR_LOG_AUDIT="No"
         fi
   #Is NTP setup and used
      NTP=$(grep correct sos_commands/ntp/ntpstat | awk '{ print $5" "$6 }')
      if [ -z "${NTP}" ]
      then
         NTP="Failed"
      fi
   #Is sysstat package install?
      SYSSTATPKG="Installed"
      PKG=$(grep sysstat installed-rpms)
      if [ -z "${PKG}" ]
      then
         SYSSTATPKG="None"
      fi
   #Is sysstat chkconfig set?
      SYSSTATSERVICE="Yes"
      myvar=$(grep sysstat chkconfig | egrep '3:on|4:on|5:on')
      if [ -z "${myvar}" ]
      then
         SYSSTATSERVICE="No"
      fi
   #Get current runlevel value
      RUNLEVEL=$(awk '{ print $2 }' sos_commands/startup/runlevel)
      # Done
   #Count number of installed packages
      INSTALLEDPKGS=$(cat installed-rpms | wc -l)
      # Done
   #Use xsos to check for the number of attach disks
      NUMDISKS=$(xsos -xd ${SOSDIR}/${SOSEXPANDED}/ | grep totaling | awk '{print $1}')
      # Done
   #Get Disk sizes from xsos
      MYVALUE=$(xsos -xd ${SOSDIR}/${SOSEXPANDED}/ | grep sd | awk '{print $2}')
      DISK_SIZE=$(echo ${MYVALUE} | sed 's/ /;/g')  
   #Get RAM USED from xsos
      MYVALUE=$(xsos -xm ${SOSDIR}/${SOSEXPANDED} | grep "used excluding")
      RAM_USED=$(echo ${MYVALUE} | awk '{print $1}')
#Send a data row
cat << END >> ${OUTPUT}
${REPORTNAME},${HOSTNAME},\
${HARDWARE},${RAMGB},${RAM_USED},${CPUCOUNT},${CPUTYPE},\
${NUMDISKS},${DISK_SIZE},${OS},${KERNELVERS},\
${WASTEDRAMMB},${HUGEPAGES},${UNUSEDHUEPAGES},\
${RUNLEVEL},${INSTALLEDPKGS},${ROOTLOGIN},${SELINUX},${IPTABLES_CHKCONFIG},\
${ORACLE},${HOME},${TMP},${VAR},${VAR_LOG},${VAR_LOG_AUDIT},\
${BOND},${GRUBKDUMP},${KEXECTOOLS},${KDUMPSERVICE},\
${TAINTED},${NICERROR},\
${SYSCTL},${NTP},${UPTIME},${FSFULL},${NFSSHARE},${LOGSERVER},\
${SYSSTATPKG},${SYSSTATSERVICE},\
${CLUSTER},${CLUSTAT}
END

#Remove the expanded sos report since we are done with it
   cd ..
   sudo rm -rf ${SOSEXPANDED}
   let COUNTER=COUNTER+1

done
echo ""
echo "Completed."

