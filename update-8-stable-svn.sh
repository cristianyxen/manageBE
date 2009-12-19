#!/bin/sh
# Philipp Wuensche
# Beerware
#
# One-click upgrade of RELENG_8 via svn

cd /usr/src
old_rev=`svn info |grep Revision |cut -d ' ' -f2`
svn update
new_rev=`svn info |grep Revision |cut -d ' ' -f2`
work_rev=`manageBE list | awk '{print $1,$2}' | grep yes | awk '{print $1}' |sed s:8-STABLE-r::`

if [ "$new_rev" -gt "$old_rev" -o "$new_rev" -gt "$work_rev" ]; then
  make -s -j4 buildworld
  make -s -j4 buildkernel
  manageBE create -s 8-STABLE-r${work_rev} -n 8-STABLE-r${new_rev} -p testbox
  manageBE upgrade -n 8-STABLE-r${new_rev} -p testbox
  manageBE activate -n 8-STABLE-r${new_rev} -p testbox
fi
