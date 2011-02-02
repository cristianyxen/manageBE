#!/bin/sh

source_disk=$1
dest_disk=$2
identifier=$3

if [ -z "${source_disk}" -o -z "${dest_disk}" -o -z "${identifier}" ]; then
  echo "Usage: `basename $0` <source_disk> <destination_dist> <destination_disk_identifier>"
  exit
fi

echo "gpart create -s GPT ${dest_disk}"

for p_id in `gpart show ${source_disk} | grep -v GPT | awk '{print $3}'`; do
 name=`gpart show -l ${source_disk} | grep -v GPT | awk -v id=$p_id '{if($3 == id) {print $4}}' |cut -d '-' -f1`
 start=`gpart show ${source_disk} | grep -v GPT | awk -v id=$p_id '{if($3 == id) {print $1}}'`
 size=`gpart show ${source_disk} | grep -v GPT | awk -v id=$p_id '{if($3 == id) {print $2}}'`
 type=`gpart show ${source_disk} | grep -v GPT | awk -v id=$p_id '{if($3 == id) {print $4}}'`
 if [ "$p_id" -eq "1" ]; then
  echo "gpart add -b $start -s $size -t $type -i ${p_id} ${dest_disk}"
 else
  echo "gpart add -b $start -s $size -t $type -l ${name}-${identifier} -i ${p_id} ${dest_disk}"
 fi
done

echo "gpart bootcode -b /boot/pmbr -p /boot/gptzfsboot -i 1 ${dest_disk}"

