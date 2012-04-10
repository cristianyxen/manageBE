#!/bin/sh
# Philipp Wuensche
# This script is considered beer ware (http://en.wikipedia.org/wiki/Beerware)
# modifyed with great help of gkontos from http://www.aisecure.net/2011/05/01/root-on-zfs-freebsd-current/ 
# by Olaf Klein - monkeytower internet agency http://www.monkeytower.net
#
# DISCLAIMER: Use at your own risk! Always make backups, don't blame me if this renders your system unusable or you lose any data! 
# 
# This works with FreeBSD 8.1, 8.2 and 9.0 (tested with RELEASE), you have been warned!
#
# For FreeBSD-8, startup the FreeBSD livefs CD. Go into the Fixit console. Create /var/db if you want to use DHCP. Configure your network settings.
# For FreeBSD-9, startup the FreeBSD DVD image or USB stick, select "Shell". Create /tmp/bsdinstall_etc, add nameserver to /etc/resolv.conf, configure your network settings, go to /tmp.
#  Fetch http://anonsvn.h3q.com/s/gpt-zfsroot.sh
#
# Execute the script with the following parameter:
#
# -p sets the geom provider to use, you can use multiple. Add a name for the GPT labels: -p ad4=black -p ad6=white
# -s sets the swap_partition_size to create, you can use m/M for megabyte or g/G for gigabyte
# -S sets the zfs_partition_size to create, you can use m/M for megabyte or g/G for gigabyte, default is all available size
# -n sets the name of the zpool to create
# -f sets the ftp-server used for getting the freebsd packages, default is ftp.freebsd.org
# -m sets the zpool raid-mode, stripe (only single disk), mirror (at least two disks) and raidz (at least three disks)
# -d sets local directory to get distribution packages from
#
# You can use more than one device, creating a mirror. To specify more than one device, use multiple -p options. 
# eg. create-zfsboot-gpt_livecd.sh -p ad0 -p ad1 -s 512m -n tank
#
# $Id$
#

ftphost='ftp.freebsd.org'

usage="Usage: create-zfsboot-gpt_livecd.sh -4k -p <geom_provider> -s <swap_partition_size> -S <zfs_partition_size> -n <zpoolname> -m <zpool-raidmode> -d <distdir> -f <ftphost>"

exerr () { echo -e "$*" >&2 ; exit 1; }

while getopts p:s:S:n:f:m:d:k: arg
do case ${arg} in
  p) provider="$provider ${OPTARG}";;
  s) swap_partition_size=${OPTARG};;
  S) zfs_partition_size=${OPTARG};;
  n) poolname=${OPTARG};;
  f) ftphost=${OPTARG};;
  m) mode=${OPTARG};;
  d) distdir=${OPTARG};;
  k) fourk='true';;
  ?) exerr ${usage};;
esac; done; shift $(( ${OPTIND} - 1 ))

if [ -z "$poolname" ] || [ -z "$provider" ] ; then
  exerr ${usage}
  exit
fi

RELNUM=`uname -r | cut -d '.' -f1`
echo "Running on FreeBSD-$RELNUM"
sleep 2

if [ "$distdir" ]; then
  if [ "$RELNUM" = "8" -a -f "$distdir/base/install.sh" -a -f "$distdir/kernels/install.sh" ]; then
    echo "Found distribution files for FreeBSD-8 in ${distdir}!"
  elif [ "$RELNUM" = "9" -a -f "$distdir/kernel.txz" -a -f "$distdir/base.txz" -a -f "$distdir/lib32.txz" ]; then
    echo "Found distribution files for FreeBSD-9 in ${distdir}!"
  else
    echo "Could not find distribution files for FreeBSD-${RELNUM} in $distdir!"
    exit 1
  fi
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
sleep 1

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
sleep 2

echo "Creating GPT boot partition on disks:"
for disk in $provider; do
  get_disk_labelname
  echo " ->  ${disk}"
  gpart add -b 40 -s 1024 -t freebsd-boot $disk > /dev/null
done

echo
sleep 2

if [ "$swap_partition_size" ]; then
  echo "Creating GPT swap partition on with size ${swap_partition_size} on disks: "
  for disk in $provider; do
    get_disk_labelname
    echo " ->  ${disk} (Label: ${label})"
    gpart add -b 2048 -s $swap_partition_size -t freebsd-swap -l swap-${label} ${disk} > /dev/null
  done
fi

echo
sleep 2

offset=`gpart show $ref_disk | grep '\- free \-' | tail -n1 |awk '{print $1}'`
if [ -z "${zfs_partition_size}" ]; then
  size=`gpart show $ref_disk | grep '\- free \-' | tail -n1 |awk '{print $2}'`
else
  size=${zfs_partition_size}
fi

echo "Creating GPT ZFS partition on with size ${size} on disks: "
for disk in $provider; do
  get_disk_labelname
  echo " ->  ${disk} (Label: ${label})"
  gpart add -t freebsd-zfs -b $offset -s $size -l system-${label} ${disk} > /dev/null
  if [ "$fourk" ]; then
   echo "Forcing 4k sectorsize for $disk"
   gnop create -S 4096 /dev/gpt/system-${label}
   label="${label}.nop"
   fourk=''
  fi
  labellist="${labellist} gpt/system-${label}"
done

echo
sleep 2

# Make first partition active so the BIOS boots from it
for disk in $provider; do
  get_disk_labelname
#  echo 'a 1' | fdisk -f - $disk > /dev/null 2>&1
done

echo
sleep 2

if [ "$RELNUM" = "8" ]; then
 kldload /mnt2/boot/kernel/opensolaris.ko
 kldload /mnt2/boot/kernel/zfs.ko
elif [ "$RELNUM" = "9" ]; then
 kldload /boot/kernel/opensolaris.ko
 kldload /boot/kernel/zfs.ko
fi

# we need to create /boot/zfs so zpool.cache can be written.
if [ "$RELNUM" = "8" ]; then
 mkdir /boot/zfs
fi

# Create the pool and the rootfs

if [ "$mode" = "raidz" ]; then
  zpool create -m /tmp/$poolname -f $poolname raidz ${labellist}
fi
if [ "$mode" = "mirror" ]; then
  zpool create -m /tmp/$poolname -f $poolname mirror ${labellist}
fi
if [ "$mode" = "stripe" ]; then
  zpool create -m /tmp/$poolname -f $poolname ${labellist}
fi

if [ `zpool list -H -o name $poolname` != "$poolname" ]; then
  echo "ERROR: Could not create zpool $poolname"
  exit
fi

sleep 2

zpool export $poolname
zpool import -o cachefile=/tmp/zpool.cache $poolname

echo "Setting checksum to fletcher4"
zfs set checksum=fletcher4 ${poolname}

rootzfs="$poolname/ROOT/$poolname"

zfs create -p $rootzfs
zfs set freebsd:boot-environment=1 $rootzfs

# Now we create some stuff we also would like to have in seperate filesystems
for filesystem in usr-src usr-obj usr-local tmp; do
   echo "Creating $poolname/$filesystem"
   zfs create $poolname/$filesystem
   if [ "$filesystem" = "tmp" ]; then
     chmod 1777 /tmp/$poolname/tmp
   fi
   zfs umount $poolname/$filesystem
   _filesystem=`echo $filesystem | sed s:-:\/:g`
   zfs set mountpoint=/${_filesystem} $poolname/${filesystem}
done

mkdir /tmp/$rootzfs/usr

zfs mount -o mountpoint=/tmp/$rootzfs/usr/src $poolname/usr-src

zfs mount -o mountpoint=/tmp/$rootzfs/usr/obj $poolname/usr-obj

if [ "$RELNUM" = "8" ]; then
 packages='base kernels'
elif [ "$RELNUM" = "9" ]; then
 packages='base.txz kernel.txz lib32.txz'
fi

echo ####################################
if [ -z "$distdir" ]; then
    echo "Now installing ${packages} via $ftphost. This may take a while, depending on your network connection."
    zfs create $poolname/installdata
    cd /tmp/$poolname/installdata
    
    if [ `pwd` != "/tmp/$poolname/installdata" ]; then
        echo "ERROR: Could not change directoy to /$poolname/installdata. Aborting."
        exit
    fi
    
    sleep 2
    arch=`uname -p`
    release=`uname -r`
    echo
    echo "Fetching FreeBSD ${release}-${arch}:"
    for pkg in $packages; do
        echo " -> $pkg"
        if [ "$RELNUM" = "8" ]; then
         mkdir /tmp/$poolname/installdata/${pkg}
         cd /tmp/$poolname/installdata/${pkg}
         ftp -V "$ftphost:pub/FreeBSD/releases/${arch}/${release}/${pkg}/*"
        elif [ "$RELNUM" = "9" ]; then
         cd /tmp/$poolname/installdata/
         ftp -V "$ftphost:pub/FreeBSD/releases/${arch}/${release}/${pkg}"
        fi
    done
    distdir="/tmp/$poolname/installdata"
else
    echo "Using distribution packages from $distdir"
fi

export DESTDIR=/tmp/$rootzfs/

echo
if [ "$RELNUM" = "8" ]; then
 echo "Extracting base into $DESTDIR"
 cd /$distdir/base ; cat base.?? | tar --unlink -xpzf - -C ${DESTDIR:-/}
 echo "Extracting kernel into ${DESTDIR}boot"
 cd /$distdir/kernels ; sh ./install.sh generic
 cd /tmp/$rootzfs/boot ; cp -rp GENERIC/* /tmp/$rootzfs/boot/kernel/; cd -
fi

if [ "$RELNUM" = "9" ]; then
 echo "Installing following packages: $packages"
 for file in ${packages}; do
  echo "Extracting $file into $DESTDIR"
  cat $distdir/$file | tar --unlink -xpJf - -C ${DESTDIR:-/}
 done
fi

if [ -z "$distdir" ]; then
    zfs destroy $poolname/installdata
fi

echo
echo "Installing new bootcode on disks: "
for disk in $provider; do
  get_disk_labelname
  echo " ->  ${disk}"
  gpart bootcode -b /tmp/$rootzfs/boot/pmbr -p /tmp/$rootzfs/boot/gptzfsboot -i 1 $disk > /dev/null
done
echo

# We need to fix /usr/src so it is mounted correct when booting from ZFS
zfs umount $poolname/usr-src
zfs set mountpoint=/usr/src $poolname/usr-src

# We need to fix /usr/obj so it is mounted correct when booting from ZFS
zfs umount $poolname/usr-obj
zfs set mountpoint=/usr/obj $poolname/usr-obj

# Enable the new filesystem as zpool bootfs
zpool set bootfs=$rootzfs $poolname

# We still need to tell the kernel from where to mount its root-filesystem
echo 'zfs_load="YES"' >> /tmp/$rootzfs/boot/loader.conf
echo "vfs.root.mountfrom=\"zfs:$rootzfs\"" >> /tmp/$rootzfs/boot/loader.conf
echo 'zfs_enable="YES"' >> /tmp/$rootzfs/etc/rc.conf
touch /tmp/$rootzfs/etc/fstab

if [ "$swap_partition_size" ]; then
  echo "Adding swap partitions in fstab:"
  for disk in $provider; do
    get_disk_labelname
    echo " ->  /dev/gpt/swap-${label}"
    echo "/dev/gpt/swap-${label} none swap sw 0 0" >> /tmp/$rootzfs/etc/fstab
  done
fi
echo

# Copy the zpool.cache to the new filesystem
cp /tmp/zpool.cache /tmp/$rootzfs/boot/zfs/zpool.cache

zfs umount -a
zfs set mountpoint=/$poolname $poolname

sleep 5

echo "Please reboot the system from the harddisk(s), remove the FreeBSD CD from you cdrom!"
