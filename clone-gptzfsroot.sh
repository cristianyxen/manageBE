#!/bin/sh
# Philipp Wuensche
# This script is considered beer ware (http://en.wikipedia.org/wiki/Beerware)
#
# DISCLAIMER: Use at your own risk! Always make backups, don't blame me if this renders your system unusable or you lose any data! 
# 
# This only works with FreeBSD 8.0 (tested with 8.0-RELEASE), you have been warned!
#
# Fetch http://anonsvn.h3q.com/s/clone-gptzfsroot.sh
#
# Execute the script with the following parameter:
#
# -p sets the geom provider to use, you can use multiple. Add a name for the GPT labels: -p ad4=black -p ad6=white
# -s sets the swap_partition_size to create, you can use m/M for megabyte or g/G for gigabyte
# -S sets the zfs_partition_size to create, you can use m/M for megabyte or g/G for gigabyte, default is all available size
# -n sets the name of the zpool to create
# -m sets the zpool raid-mode, stripe (only single disk), mirror (at least two disks) and raidz (at least three disks)
# -o sets the zpool to use as source
#
# You can use more than one device, creating a mirror. To specify more than one device, use multiple -p options. 
# eg. clone-gptzfsboot.sh -p ad0 -p ad1 -s 512m -S20g -n tank -o newtank

usage="Usage: create-zfsboot-gpt_livecd.sh -p <geom_provider> -s <swap_partition_size> -S <zfs_partition_size> -n <zpoolname> -m <zpool-raidmode> -d <distdir> -f <ftphost>"

exerr () { echo -e "$*" >&2 ; exit 1; }

while getopts p:s:S:n:m:o: arg
do case ${arg} in
  p) provider="$provider ${OPTARG}";;
  s) swap_partition_size=${OPTARG};;
  S) zfs_partition_size=${OPTARG};;
  n) poolname=${OPTARG};;
  m) mode=${OPTARG};;
  o) src_poolname=${OPTARG};;
  ?) exerr ${usage};;
esac; done; shift $(( ${OPTIND} - 1 ))

if [ -z "$poolname" ] || [ -z "$provider" ] ; then
  exerr ${usage}
  exit
fi

# count the number of providers
devcount=`echo ${provider} |wc -w`

# set our default zpool mirror-mode
if [ -z "$mode" ]; then
    if [ "$devcount" -gt "1" ]; then
        mode='mirror'
    else
        mode='stripe'
    fi
fi

# check the settings for the users that want to set the mode on their own
if [ "$devcount" -eq "1" -a "$mode" = "mirror" ]; then
    echo "A mirror needs at least two disks!"
    exit
fi
if [ "$devcount" -lt "3" -a "$mode" = "raidz" ]; then
    echo "Sorry, you need at least three disks for a zfs raidz!"
    exit
fi

check_size () {
  ref_disk_size=`gpart list $ref_disk | grep 'Mediasize' | awk '{print $2}'`
  if [ "${zfs_partition_size}" ]; then
    _zfs_partition_size=`echo "${zfs_partition_size}"|tr GMKBWX gmkbwx|sed -Ees:g:km:g -es:m:kk:g -es:k:"*2b":g -es:b:"*128w":g -es:w:"*4 ":g -e"s:(^|[^0-9])0x:\1\0X:g" -ey:x:"*":|bc |sed "s:\.[0-9]*$::g"`
  fi
  if [ "${swap_partition_size}" ]; then
    _swap_partition_size=`echo "${swap_partition_size}"|tr GMKBWX gmkbwx|sed -Ees:g:km:g -es:m:kk:g -es:k:"*2b":g -es:b:"*128w":g -es:w:"*4 ":g -e"s:(^|[^0-9])0x:\1\0X:g" -ey:x:"*":|bc |sed "s:\.[0-9]*$::g"`
  fi
  total_size=$((${_zfs_partition_size}+${_swap_partition_size}+162))
  if [ "${total_size}" -gt "${ref_disk_size}" ]; then
    echo "ERROR: The current settings for the partitions sizes will not fit onto your disk."
    exit
  else
  fi
}

get_disk_labelname () {
  label=${disk##*=}
  disk=${disk%%=*}
}

echo "Creating GPT label on disks:"
for disk in $provider; do
  get_disk_labelname
  if [ ! -e "/dev/$disk" ]; then
    echo " -> ERROR: $disk does not exist"
    exit
  fi
  echo " -> $disk"
  dd if=/dev/zero of=/dev/$disk bs=512 count=79 > /dev/null 2>&1
  gpart create -s gpt $disk > /dev/null
done

echo

smallest_disk_size='0'
echo "Checking disks for size:"
for disk in $provider; do
  get_disk_labelname
  disk_size=`gpart show $disk | grep '\- free \-' | awk '{print $2}'`
  echo " -> $disk - total size $disk_size"
  if [ "$smallest_disk_size" -gt "$disk_size" ] || [ "$smallest_disk_size" -eq "0" ]; then
    smallest_disk_size=$disk_size
    ref_disk=$disk
  fi
done

# check if the size fits
check_size

echo
echo "NOTICE: Using $ref_disk (smallest or only disk) as reference disk for calculation offsets"
echo

echo "Creating GPT boot partition on disks:"
for disk in $provider; do
  get_disk_labelname
  echo " ->  ${disk}"
  gpart add -s 128 -t freebsd-boot $disk > /dev/null
done

echo

if [ "$swap_partition_size" ]; then
  echo "Creating GPT swap partition on with size ${swap_partition_size} on disks: "
  for disk in $provider; do
    get_disk_labelname
    echo " ->  ${disk} (Label: ${label})"
    gpart add -s $swap_partition_size -t freebsd-swap -l swap-${label} ${disk} > /dev/null
  done
fi

echo

offset=`gpart show $ref_disk | grep '\- free \-' | awk '{print $1}'`
if [ -z "${zfs_partition_size}" ]; then
  size=`gpart show $ref_disk | grep '\- free \-' | awk '{print $2}'`
else
  size=${zfs_partition_size}
fi

echo "Creating GPT ZFS partition on with size ${size} on disks: "
for disk in $provider; do
  get_disk_labelname
  echo " ->  ${disk} (Label: ${label})"
  gpart add -b $offset -s $size -t freebsd-zfs -l system-${label} ${disk} > /dev/null
  labellist="${labellist} gpt/system-${label}"
done

echo

# Make first partition active so the BIOS boots from it
for disk in $provider; do
  get_disk_labelname
  echo 'a 1' | fdisk -f - $disk > /dev/null 2>&1
done

# Create the pool and the rootfs

if [ "$mode" = "raidz" ]; then
  zpool create -f $poolname raidz ${labellist}
fi
if [ "$mode" = "mirror" ]; then
  zpool create -f $poolname mirror ${labellist}
fi
if [ "$mode" = "stripe" ]; then
  zpool create -f $poolname ${labellist}
fi

if [ `zpool list -H -o name $poolname` != "$poolname" ]; then
  echo "ERROR: Could not create zpool $poolname"
  exit
fi

echo "Setting checksum to fletcher4"
zfs set checksum=fletcher4 ${poolname}

echo
echo "Installing new bootcode on disks: "
for disk in $provider; do
  get_disk_labelname
  echo " ->  ${disk}"
  gpart bootcode -b /boot/pmbr -p /boot/gptzfsboot -i 1 $disk > /dev/null
done
echo

if [ -z ${src_poolname} -o -z ${poolname} ]; then
  echo "Missing source or destrination ZFS!" && exit
fi

zfs snapshot -r ${src_poolname}@_clone

for zfs in `zfs list -H -o name -t filesystem -r ${src_poolname} | sort`; do
  dest_zfs=`echo ${zfs} |sed s:${src_poolname}:${poolname}:`
  oldest_snap=`zfs list -H -o name -t snapshot -S creation -r ${zfs} | grep ${zfs}@ |tail -n1 | sed s:${zfs}@::`
  echo "Copying ${zfs} to ${dest_zfs}.."
  if [ -z "${oldest_snap}" -o "${oldest_snap}" = "_clone" ]; then
    zfs send ${zfs}@_clone | zfs recv -F ${dest_zfs}
  else
    zfs send ${zfs}@${oldest_snap}| zfs recv -F ${dest_zfs}
    zfs send -I @${oldest_snap} ${zfs}@_clone | zfs recv -F ${dest_zfs}
  fi
done

zfs destroy -r ${src_poolname}@_clone
zfs destroy -r ${poolname}@_clone

for source_zfs in `zfs list -H -o name -r ${src_poolname} |grep -v ^${src_poolname}/ROOT |grep -v "^${src_poolname}$"`; do
  dest_zfs=`echo ${source_zfs} |sed s:${src_poolname}:${poolname}:`
  mountpoint=`zfs list -H -o mountpoint ${source_zfs}`
  zfs unmount ${dest_zfs}
  echo "Correcting mountpoint of ${dest_zfs} to ${mountpoint}"
  zfs set mountpoint=${mountpoint} ${dest_zfs}
done

src_rootzfs=`zpool list -H -o bootfs ${src_poolname}`

if [ ! "-" = "${src_bootfs}" ]; then
  rootzfs="${poolname}/${src_rootzfs#*/}"
  echo "Setting ${rootzfs} as bootfs on ${poolname}"
  zpool set bootfs=${rootzfs} ${poolname}
  cat /boot/loader.conf | sed s:${src_poolname}/ROOT:${poolname}/ROOT:g > /${rootzfs}/boot/loader.conf
  echo "Fixing new fstab."
  cat /etc/fstab | sed s:${src_poolname}/ROOT:${poolname}/ROOT:g > /${rootzfs}/etc/fstab
fi

echo "Please reboot the system from the new harddisk(s) without exporting ${poolname}!"