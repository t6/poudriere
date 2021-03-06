#!/bin/sh
#
# Copyright (c) 2015 Baptiste Daroussin <bapt@FreeBSD.org>
# All rights reserved.
# Copyright (c) 2020 Allan Jude <allanjude@FreeBSD.org>
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.

usage() {
	[ $# -gt 0 ] && echo "Missing: $@" >&2
	cat << EOF
poudriere image [parameters] [options]

Parameters:
    -A post-script  -- Source this script after populating the \$WRKDIR/world
                       directory to apply customizations before exporting the
                       final image.
    -b              -- Place the swap partition before the primary partition(s)
    -B pre-script   -- Source this script instead of using the defaults to setup
                       the disk image and mount it to \$WRKDIR/world before
                       installing the contents to the image
    -c overlaydir   -- The content of the overlay directory will be copied into
                       the image
    -f packagelist  -- List of packages to install
    -h hostname     -- The image hostname
    -i originimage  -- Origin image name
    -j jail         -- Jail
    -m overlaydir   -- Build a miniroot image as well (for tar type images), and
                       overlay this directory into the miniroot image
    -n imagename    -- The name of the generated image
    -o outputdir    -- Image destination directory
    -p portstree    -- Ports tree
    -P pkgbase      -- List of pkgbase packages to install
    -s size         -- Set the image size
    -S snapshotname -- Snapshot name
    -t type         -- Type of image can be one of (default iso+zmfs):
                    -- iso, iso+mfs, iso+zmfs, usb, usb+mfs, usb+zmfs,
                       rawdisk, zrawdisk, tar, firmware, rawfirmware,
                       dump, zsnapshot
    -w size         -- Set the size of the swap partition
    -X excludefile  -- File containing the list in cpdup format
    -z set          -- Set
EOF
	exit 1
}

delete_image() {
	[ ! -f "${excludelist}" ] || rm -f ${excludelist}
	[ -z "${zroot}" ] || zpool destroy -f ${zroot}
	[ -z "${md}" ] || /sbin/mdconfig -d -u ${md#md}
	[ -z "${zfs_zsnapshot}" ] || zfs destroy -r ${zfs_zsnapshot}

	TMPFS_ALL=0 destroyfs ${WRKDIR} image || :
}

cleanup_image() {
	msg "Error while create image. cleaning up." >&2
	delete_image
}

recursecopylib() {
	path=$1
	case $1 in
	*/*) ;;
	lib*)
		if [ -e "${WRKDIR}/world/lib/$1" ]; then
			cp ${WRKDIR}/world/lib/$1 ${mroot}/lib
			path=lib/$1
		elif [ -e "${WRKDIR}/world/usr/lib/$1" ]; then
			cp ${WRKDIR}/world/usr/lib/$1 ${mroot}/usr/lib
			path=usr/lib/$1
		fi
		;;
	esac
	for i in $( (readelf -d ${mroot}/$path 2>/dev/null || :) | awk '$2 == "NEEDED" { gsub(/\[/,"", $NF ); gsub(/\]/,"",$NF) ; print $NF }'); do
		[ -f ${mroot}/lib/$i ] || recursecopylib $i
	done
}

mkminiroot() {
	msg "Making miniroot"
	[ -z "${MINIROOT}" ] && err 1 "MINIROOT not defined"
	mroot=${WRKDIR}/miniroot
	dirs="etc dev boot bin usr/bin libexec lib usr/lib sbin"
	files="bin/kenv"
	files="${files} bin/ls"
	files="${files} bin/mkdir"
	files="${files} bin/sh"
	files="${files} bin/sleep"
	files="${files} etc/pwd.db"
	files="${files} etc/spwd.db"
	files="${files} libexec/ld-elf.so.1"
	files="${files} sbin/fasthalt"
	files="${files} sbin/fastboot"
	files="${files} sbin/halt"
	files="${files} sbin/ifconfig"
	files="${files} sbin/init"
	files="${files} sbin/mdconfig"
	files="${files} sbin/mount"
	files="${files} sbin/newfs"
	files="${files} sbin/ping"
	files="${files} sbin/reboot"
	files="${files} sbin/route"
	files="${files} sbin/umount"
	files="${files} usr/bin/bsdtar"
	files="${files} usr/bin/fetch"
	files="${files} usr/bin/sed"

	for d in ${dirs}; do
		mkdir -p ${mroot}/${d}
	done

	for f in ${files}; do
		cp -p ${WRKDIR}/world/${f} ${mroot}/${f}
		recursecopylib ${f}
	done
	cp -fRPp ${MINIROOT}/ ${mroot}/

	makefs "${OUTPUTDIR}/${IMAGENAME}-miniroot" ${mroot}
	[ -f "${OUTPUTDIR}/${IMAGENAME}-miniroot.gz" ] && rm "${OUTPUTDIR}/${IMAGENAME}-miniroot.gz"
	gzip -9 "${OUTPUTDIR}/${IMAGENAME}-miniroot"
}

get_pkg_abi() {
	case ${arch} in
		amd64) echo amd64 ;;
		arm64.aarch64) echo aarch64 ;;
		i386) echo i386 ;;
		arm.armv7) echo armv7 ;;
	esac
}

get_uefi_bootname() {

    case ${arch} in
        amd64) echo bootx64 ;;
        arm64.aarch64) echo bootaa64 ;;
        i386) echo bootia32 ;;
        arm.armv7) echo bootarm ;;
        *) echo boot ;;
    esac
}

make_esp_file() {
    local file sizekb loader device stagedir fatbits efibootname

    file=$1
    size=$2
    loader=$3
    fat32min=33
    fat16min=2

    if [ "$size" -ge "$fat32min" ]; then
        fatbits=32
    elif [ "$size" -ge "$fat16min" ]; then
        fatbits=16
    else
        fatbits=12
    fi

    stagedir=$(mktemp -d /tmp/stand-test.XXXXXX)
    mkdir -p "${stagedir}/EFI/BOOT"
    efibootname=$(get_uefi_bootname)
    cp "${loader}" "${stagedir}/EFI/BOOT/${efibootname}.efi"
    makefs -t msdos \
	-o fat_type=${fatbits} \
	-o sectors_per_cluster=1 \
	-o volume_label=EFISYS \
	-s ${size}m \
	"${file}" "${stagedir}"
    rm -rf "${stagedir}"
}

. ${SCRIPTPREFIX}/common.sh
HOSTNAME=poudriere-image

: ${PRE_BUILD_SCRIPT:=""}
: ${POST_BUILD_SCRIPT:=""}

while getopts "A:bB:c:f:h:i:j:m:n:o:p:P:s:S:t:w:X:z:" FLAG; do
	case "${FLAG}" in
		A)
			[ -f "${OPTARG}" ] || err 1 "No such post-build-script: ${OPTARG}"
			POST_BUILD_SCRIPT="$(realpath ${OPTARG})"
			;;
		b)
			SWAPBEFORE=1
			;;
		B)
			[ "${OPTARG#/}" = "${OPTARG}" ] && \
			    OPTARG="${SAVED_PWD}/${OPTARG}"
			[ -f "${OPTARG}" ] || err 1 "No such pre-build-script: ${OPTARG}"
			PRE_BUILD_SCRIPT="$(realpath ${OPTARG})"
			;;
		c)
			[ "${OPTARG#/}" = "${OPTARG}" ] && \
			    OPTARG="${SAVED_PWD}/${OPTARG}"
			[ -d "${OPTARG}" ] || err 1 "No such extract directory: ${OPTARG}"
			EXTRADIR=$(realpath "${OPTARG}")
			;;
		f)
			# If this is a relative path, add in ${PWD} as
			# a cd / was done.
			[ "${OPTARG#/}" = "${OPTARG}" ] && \
			    OPTARG="${SAVED_PWD}/${OPTARG}"
			[ -r "${OPTARG}" ] || err 1 "No such package list: ${OPTARG}"
			PACKAGELIST=${OPTARG}
			;;
		h)
			HOSTNAME=${OPTARG}
			;;
		i)
			ORIGIN_IMAGE=${OPTARG}
			;;
		j)
			JAILNAME=${OPTARG}
			;;
		m)
			[ "${OPTARG#/}" = "${OPTARG}" ] && \
			    OPTARG="${SAVED_PWD}/${OPTARG}"
			[ -d "${OPTARG}" ] || err 1 "No such miniroot overlay directory: ${OPTARG}"
			MINIROOT=$(realpath ${OPTARG})
			;;
		n)
			IMAGENAME=${OPTARG}
			;;
		o)
			# If this is a relative path, add in ${PWD} as
			# a cd / was done.
			[ "${OPTARG#/}" = "${OPTARG}" ] && \
			    OPTARG="${SAVED_PWD}/${OPTARG}"
			OUTPUTDIR=${OPTARG}
			;;
		p)
			PTNAME=${OPTARG}
			;;
		P)
			# If this is a relative path, add in ${PWD} as
			# a cd / was done.
			[ "${OPTARG#/}" = "${OPTARG}" ] && \
			    OPTARG="${SAVED_PWD}/${OPTARG}"
			[ -r "${OPTARG}" ] || err 1 "No such package list: ${OPTARG}"
			PKGBASELIST=${OPTARG}
			;;
		s)
			IMAGESIZE="${OPTARG}"
			;;
		S)
			SNAPSHOT_NAME="${OPTARG}"
			;;
		t)
			MEDIATYPE=${OPTARG}
			case ${MEDIATYPE} in
			iso|iso+mfs|iso+zmfs|usb|usb+mfs|usb+zmfs) ;;
			rawdisk|zrawdisk|tar|firmware|rawfirmware) ;;
			dump|zsnapshot) ;;
			*) err 1 "invalid mediatype: ${MEDIATYPE}"
			esac
			;;
		w)
			SWAPSIZE="${OPTARG}"
			;;
		X)
			[ -r "${OPTARG}" ] || err 1 "No such exclude list ${OPTARG}"
			EXCLUDELIST=$(realpath ${OPTARG})
			;;
		z)
			[ -n "${OPTARG}" ] || err 1 "Empty set name"
			SETNAME="${OPTARG}"
			;;
		*)
			echo "Unknown flag '${FLAG}'"
			usage
			;;
	esac
done

saved_argv="$@"
shift $((OPTIND-1))
post_getopts

: ${MEDIATYPE:=none}
: ${SWAPBEFORE:=0}
: ${SWAPSIZE:=0}
: ${PTNAME:=default}

[ -n "${JAILNAME}" ] || usage

: ${OUTPUTDIR:=${POUDRIERE_DATA}/images/}
: ${IMAGENAME:=poudriereimage}
MASTERNAME=${JAILNAME}-${PTNAME}${SETNAME:+-${SETNAME}}

# CFG_SIZE set /etc and /var ramdisk size and /cfg partition size
# DATA_SIZE set /data partition size
CFG_SIZE='32m'
DATA_SIZE='32m'

case "${MEDIATYPE}" in
*iso*)
	# Limitation on isos
	case "${IMAGENAME}" in
	''|*[!A-Za-z0-9]*)
		err 1 "Name can only contain alphanumeric characters"
		;;
	esac
	;;
zsnapshot)
	[ ! -z "${SNAPSHOT_NAME}" ] || \
		err 1 "zsnapshot type requires a snapshot name (-S option)"
	;;
none)
	err 1 "Missing -t option"
	;;
esac

mkdir -p "${OUTPUTDIR}"

jail_exists ${JAILNAME} || err 1 "The jail ${JAILNAME} does not exist"
_jget arch ${JAILNAME} arch || err 1 "Missing arch metadata for jail"
get_host_arch host_arch
case "${MEDIATYPE}" in
usb|*firmware|*rawdisk|dump)
	[ -n "${IMAGESIZE}" ] || err 1 "Please specify the imagesize"
	_jget mnt ${JAILNAME} mnt || err 1 "Missing mnt metadata for jail"
	[ -f "${mnt}/boot/kernel/kernel" ] || \
	    err 1 "The ${MEDIATYPE} media type requires a jail with a kernel"
	;;
iso*|usb*|raw*)
	_jget mnt ${JAILNAME} mnt || err 1 "Missing mnt metadata for jail"
	[ -f "${mnt}/boot/kernel/kernel" ] || \
	    err 1 "The ${MEDIATYPE} media type requires a jail with a kernel"
	;;
esac

msg "Preparing the image '${IMAGENAME}'"
md=""
CLEANUP_HOOK=cleanup_image
[ -d "${POUDRIERE_DATA}/images" ] || \
    mkdir "${POUDRIERE_DATA}/images"
WRKDIR=$(mktemp -d ${POUDRIERE_DATA}/images/${IMAGENAME}-XXXX)
_jget mnt ${JAILNAME} mnt || err 1 "Missing mnt metadata for jail"
excludelist=$(mktemp -t excludelist)
mkdir -p ${WRKDIR}/world
mkdir -p ${WRKDIR}/out
WORLDDIR="${WRKDIR}/world"
[ -z "${EXCLUDELIST}" ] || cat ${EXCLUDELIST} > ${excludelist}
cat >> ${excludelist} << EOF
usr/src
var/db/freebsd-update
var/db/etcupdate
boot/kernel.old
nxb-bin
EOF

# Need to convert IMAGESIZE from bytes to bibytes
# This conversion is needed to be compliant with marketing 'unit'
# without this, a 2GiB image will not fit into a 2GB flash disk (=1862MiB)

if [ -n "${IMAGESIZE}" ]; then
	IMAGESIZE_UNIT=$(printf ${IMAGESIZE} | tail -c 1)
	IMAGESIZE_VALUE=${IMAGESIZE%?}
	NEW_IMAGESIZE_UNIT=""
	NEW_IMAGESIZE_SIZE=""
	case "${IMAGESIZE_UNIT}" in
		k|K)
			DIVIDER=$(echo "scale=3; 1024 / 1000" | bc)
			;;
		m|M)
			DIVIDER=$(echo "scale=6; 1024 * 1024 / 1000000" | bc)
			NEW_IMAGESIZE_UNIT="k"
			;;
		g|G)
			DIVIDER=$(echo "scale=9; 1024 * 1024 * 1024 / 1000000000" | bc)
			NEW_IMAGESIZE_UNIT="m"
			;;
		t|T)
			DIVIDER=$(echo "scale=12; 1024 * 1024 * 1024 * 1024 / 1000000000000" | bc)
			NEW_IMAGESIZE_UNIT="g"
			;;
		*)
			NEW_IMAGESIZE_UNIT=""
			NEW_IMAGESIZE_SIZE=${IMAGESIZE}
	esac
	# truncate accept only integer value, and bc needs a divide per 1 for refreshing scale
	[ -z "${NEW_IMAGESIZE_SIZE}" ] && NEW_IMAGESIZE_SIZE=$(echo "scale=9;var=${IMAGESIZE_VALUE} / ${DIVIDER}; scale=0; ( var * 1000 ) /1" | bc)
	IMAGESIZE="${NEW_IMAGESIZE_SIZE}${NEW_IMAGESIZE_UNIT}"
fi

if [ -n "${SWAPSIZE}" ]; then
	SWAPSIZE_UNIT=$(printf ${SWAPSIZE} | tail -c 1)
	SWAPSIZE_VALUE=${SWAPSIZE%?}
	NEW_SWAPSIZE_UNIT=""
	NEW_SWAPSIZE_SIZE=""
	case "${SWAPSIZE_UNIT}" in
		k|K)
			DIVIDER=$(echo "scale=3; 1024 / 1000" | bc)
			;;
		m|M)
			DIVIDER=$(echo "scale=6; 1024 * 1024 / 1000000" | bc)
			NEW_SWAPSIZE_UNIT="k"
			;;
		g|G)
			DIVIDER=$(echo "scale=9; 1024 * 1024 * 1024 / 1000000000" | bc)
			NEW_SWAPSIZE_UNIT="m"
			;;
		t|T)
			DIVIDER=$(echo "scale=12; 1024 * 1024 * 1024 * 1024 / 1000000000000" | bc)
			NEW_SWAPSIZE_UNIT="g"
			;;
		*)
			NEW_SWAPSIZE_UNIT=""
			NEW_SWAPSIZE_SIZE=${SWAPSIZE}
	esac
	# truncate accept only integer value, and bc needs a divide per 1 for refreshing scale
	[ -z "${NEW_SWAPSIZE_SIZE}" ] && NEW_SWAPSIZE_SIZE=$(echo "scale=9;var=${SWAPSIZE_VALUE} / ${DIVIDER}; scale=0; ( var * 1000 ) /1" | bc)
	SWAPSIZE="${NEW_SWAPSIZE_SIZE}${NEW_SWAPSIZE_UNIT}"
fi

if [ -n "${PRE_BUILD_SCRIPT}" ]; then
	. "${PRE_BUILD_SCRIPT}"
	REAL_MEDIATYPE="${MEDIATYPE}"
	MEDIATYPE="skip"
fi
case "${MEDIATYPE}" in
rawdisk|dump)
	truncate -s ${IMAGESIZE} ${WRKDIR}/raw.img
	md=$(/sbin/mdconfig ${WRKDIR}/raw.img)
	newfs -j -L ${IMAGENAME} /dev/${md}
	mount /dev/${md} ${WRKDIR}/world
	;;
zrawdisk)
	truncate -s ${IMAGESIZE} ${WRKDIR}/raw.img
	md=$(/sbin/mdconfig ${WRKDIR}/raw.img)
	zroot=${IMAGENAME}root
	zpool create \
		-O mountpoint=none \
		-O compression=lz4 \
		-O atime=off \
		-R ${WRKDIR}/world ${zroot} /dev/${md}
	zfs create -o mountpoint=none ${zroot}/ROOT
	zfs create -o mountpoint=/ ${zroot}/ROOT/default
	zfs create -o mountpoint=/var ${zroot}/var
	zfs create -o mountpoint=/var/tmp -o setuid=off ${zroot}/var/tmp
	zfs create -o mountpoint=/tmp -o setuid=off ${zroot}/tmp
	zfs create -o mountpoint=/home ${zroot}/home
	chmod 1777 ${WRKDIR}/world/tmp ${WRKDIR}/world/var/tmp
	zfs create -o mountpoint=/var/crash \
		-o exec=off -o setuid=off \
		${zroot}/var/crash
	zfs create -o mountpoint=/var/log \
		-o exec=off -o setuid=off \
		${zroot}/var/log
	zfs create -o mountpoint=/var/run \
		-o exec=off -o setuid=off \
		${zroot}/var/run
	zfs create -o mountpoint=/var/db \
		-o exec=off -o setuid=off \
		${zroot}/var/db
	zfs create -o mountpoint=/var/mail \
		-o exec=off -o setuid=off \
		${zroot}/var/mail
	zfs create -o mountpoint=/var/cache \
		-o compression=off \
		-o exec=off -o setuid=off \
		${zroot}/var/cache
	zfs create -o mountpoint=/var/empty ${zroot}/var/empty
	;;
zsnapshot)
	zfs list ${ZPOOL}${ZROOTFS}/images >/dev/null 2>/dev/null || \
		zfs create -o compression=lz4 ${ZPOOL}${ZROOTFS}/images
	zfs list ${ZPOOL}${ZROOTFS}/images/work >/dev/null 2>/dev/null || \
		zfs create ${ZPOOL}${ZROOTFS}/images/work
	mkdir -p ${WRKDIR}/mnt
	if [ ! -z "${ORIGIN_IMAGE}" ]; then
		gzip -d < "${ORIGIN_IMAGE}" | \
			zfs recv ${ZPOOL}${ZROOTFS}/images/work/${JAILNAME}@previous
		zfs unmount ${ZPOOL}${ZROOTFS}/images/work/${JAILNAME}
	else
		zfs create ${ZPOOL}${ZROOTFS}/images/work/${JAILNAME}
		zfs unmount ${ZPOOL}${ZROOTFS}/images/work/${JAILNAME}
	fi
	zfs_zsnapshot=${ZPOOL}${ZROOTFS}/images/work/${JAILNAME}
	zfs set mountpoint=${WRKDIR}/mnt \
	       	${ZPOOL}${ZROOTFS}/images/work/${JAILNAME}
	zfs mount \
	       	${ZPOOL}${ZROOTFS}/images/work/${JAILNAME}
	if [ ! -z "${ORIGIN_IMAGE}" -a -f ${WRKDIR}/mnt/.version ]; then
		PREVIOUS_SNAPSHOT_VERSION=$(cat ${WRKDIR}/mnt/.version)
	fi
	;;
skip)
	MEDIATYPE="${REAL_MEDIATYPE}"
	;;
esac


if [ -f "${PKGBASELIST}" ]; then
	OSVERSION=$(awk -F '"' '/REVISION=/ { print $2 }' ${mnt}/usr/src/sys/conf/newvers.sh | cut -d '.' -f 1)
	mkdir -p ${WRKDIR}/world/etc/pkg/
	pkg_abi=$(get_pkg_abi)
	cat << -EOF > ${WRKDIR}/world/etc/pkg/FreeBSD-base.conf
	local: {
               url: file://${POUDRIERE_DATA}/images/${JAILNAME}-repo/FreeBSD:${OSVERSION}:${pkg_abi}/latest,
               enabled: true
	       }
-EOF
	pkg -o ABI_FILE="${mnt}/usr/lib/crt1.o" -o REPOS_DIR=${WRKDIR}/world/etc/pkg/ -o ASSUME_ALWAYS_YES=yes -r ${WRKDIR}/world update
	while read line; do
		pkg -o ABI_FILE="${mnt}/usr/lib/crt1.o" -o REPOS_DIR=${WRKDIR}/world/etc/pkg/ -o ASSUME_ALWAYS_YES=yes -r ${WRKDIR}/world install -y ${line}
	done < ${PKGBASELIST}
	rm ${WRKDIR}/world/etc/pkg/FreeBSD-base.conf
else
	# Use of tar given cpdup has a pretty useless -X option for this case
	tar -C ${mnt} -X ${excludelist} -cf - . | tar -xf - -C ${WRKDIR}/world
	touch ${WRKDIR}/src.conf
	[ ! -f ${POUDRIERED}/src.conf ] || cat ${POUDRIERED}/src.conf > ${WRKDIR}/src.conf
	[ ! -f ${POUDRIERED}/${JAILNAME}-src.conf ] || cat ${POUDRIERED}/${JAILNAME}-src.conf >> ${WRKDIR}/src.conf
	[ ! -f ${POUDRIERED}/image-${JAILNAME}-src.conf ] || cat ${POUDRIERED}/image-${JAILNAME}-src.conf >> ${WRKDIR}/src.conf
	[ ! -f ${POUDRIERED}/image-${JAILNAME}-${SETNAME}-src.conf ] || cat ${POUDRIERED}/image-${JAILNAME}-${SETNAME}-src.conf >> ${WRKDIR}/src.conf
	make -C ${mnt}/usr/src DESTDIR=${WRKDIR}/world BATCH_DELETE_OLD_FILES=yes SRCCONF=${WRKDIR}/src.conf delete-old delete-old-libs
fi

[ ! -d "${EXTRADIR}" ] || cp -fRPp "${EXTRADIR}/" ${WRKDIR}/world/
if [ -f "${WRKDIR}/world/etc/login.conf.orig" ]; then
	mv -f "${WRKDIR}/world/etc/login.conf.orig" \
	    "${WRKDIR}/world/etc/login.conf"
fi
cap_mkdb ${WRKDIR}/world/etc/login.conf

# Set hostname
if [ -n "${HOSTNAME}" ]; then
	echo "hostname=${HOSTNAME}" >> ${WRKDIR}/world/etc/rc.conf
fi

# Convert @flavor from package list to a unique entry of pkgname, otherwise it
# spits out origin if no flavor.
convert_package_list() {
	local PACKAGELIST="$1"
	local PKG_DBDIR=$(mktemp -dt poudriere_pkgdb)
	local REPOS_DIR=$(mktemp -dt poudriere_repo)
	local ABI_FILE

	# This pkg rquery is always ran in host so we need a host-centric
	# repo.conf always.
	cat > "${REPOS_DIR}/repo.conf" <<-EOF
	FreeBSD: { enabled: false }
	local: { url: file:///${WRKDIR}/world/tmp/packages }
	EOF

	export REPOS_DIR PKG_DBDIR
	# Always need this from host.
	export ABI_FILE="${WRKDIR}/world/usr/lib/crt1.o"
	pkg update >/dev/null || :
	pkg rquery '%At %o@%Av %n-%v' | \
	    awk -v pkglist="${PACKAGELIST}" \
	    -f "${AWKPREFIX}/unique_pkgnames_from_flavored_origins.awk"
	rm -rf "${PKG_DBDIR}" "${REPOS_DIR}"
}

# install packages if any is needed
if [ -n "${PACKAGELIST}" ]; then
	mkdir -p ${WRKDIR}/world/tmp/packages
	${NULLMOUNT} ${POUDRIERE_DATA}/packages/${MASTERNAME} ${WRKDIR}/world/tmp/packages
	if [ "${arch}" == "${host_arch}" ]; then
		cat > "${WRKDIR}/world/tmp/repo.conf" <<-EOF
		FreeBSD: { enabled: false }
		local: { url: file:///tmp/packages }
		EOF
		mount -t devfs devfs ${WRKDIR}/world/dev
		convert_package_list "${PACKAGELIST}" | \
		    xargs chroot "${WRKDIR}/world" env \
		    REPOS_DIR=/tmp ASSUME_ALWAYS_YES=yes \
		    pkg install
		umount ${WRKDIR}/world/dev
	else
		cat > "${WRKDIR}/world/tmp/repo.conf" <<-EOF
		FreeBSD: { enabled: false }
		local: { url: file:///${WRKDIR}/world/tmp/packages }
		EOF
		(
			export ASSUME_ALWAYS_YES=yes SYSLOG=no \
			    REPOS_DIR="${WRKDIR}/world/tmp/" \
			    ABI_FILE="${WRKDIR}/world/usr/lib/crt1.o"
			pkg -r "${WRKDIR}/world/" install pkg
			convert_package_list "${PACKAGELIST}" | \
			    xargs pkg -r "${WRKDIR}/world/" install
		)
	fi
	rm -rf ${WRKDIR}/world/var/cache/pkg
	umount ${WRKDIR}/world/tmp/packages
	rmdir ${WRKDIR}/world/tmp/packages
	rm ${WRKDIR}/world/var/db/pkg/repo-* 2>/dev/null || :
fi

case ${MEDIATYPE} in
*mfs)
	cat >> ${WRKDIR}/world/etc/fstab <<-EOF
	/dev/ufs/${IMAGENAME} / ufs rw 0 0
	tmpfs /tmp tmpfs rw,mode=1777 0 0
	EOF
	makefs -B little ${IMAGESIZE:+-s ${IMAGESIZE}} -o label=${IMAGENAME} ${WRKDIR}/out/mfsroot ${WRKDIR}/world
	if command -v pigz >/dev/null; then
		GZCMD=pigz
	fi
	case "${MEDIATYPE}" in
	*zmfs) ${GZCMD:-gzip} -9 ${WRKDIR}/out/mfsroot ;;
	esac
	MFSROOTSIZE=$(ls -l ${WRKDIR}/out/mfsroot* | head -n 1 | awk '{print $5}')
	if [ ${MFSROOTSIZE} -ge 268435456 ]; then echo WARNING: MFSROOT too large, boot failure likely ; fi
	do_clone -r ${WRKDIR}/world/boot ${WRKDIR}/out/boot
	cat >> ${WRKDIR}/out/boot/loader.conf <<-EOF
	tmpfs_load="YES"
	mfs_load="YES"
	mfs_type="mfs_root"
	mfs_name="/mfsroot"
	vfs.root.mountfrom="ufs:/dev/ufs/${IMAGENAME}"
	EOF
	;;
iso)
	imageupper=$(echo ${IMAGENAME} | tr '[:lower:]' '[:upper:]')
	cat >> ${WRKDIR}/world/etc/fstab <<-EOF
	/dev/iso9660/${imageupper} / cd9660 ro 0 0
	tmpfs /tmp tmpfs rw,mode=1777 0 0
	EOF
	do_clone -r ${WRKDIR}/world/boot ${WRKDIR}/out/boot
	;;
rawdisk|dump)
	cat >> ${WRKDIR}/world/etc/fstab <<-EOF
	/dev/ufs/${IMAGENAME} / ufs rw 1 1
	EOF
	;;
usb)
	cat >> ${WRKDIR}/world/etc/fstab <<-EOF
	/dev/ufs/${IMAGENAME} / ufs rw 1 1
	EOF
	if [ -n "${SWAPSIZE}" -a "${SWAPSIZE}" != "0" ]; then
		cat >> ${WRKDIR}/world/etc/fstab <<-EOSWAP
		/dev/gpt/swapspace none swap sw 0 0
		EOSWAP
	fi
	# Figure out Partition sizes
	OS_SIZE=
	calculate_ospart_size "1" "${NEW_IMAGESIZE_SIZE}" "0" "0" "${SWAPSIZE}"
	# Prune off a bit to fit the extra partitions and loaders
	OS_SIZE=$(( $OS_SIZE - 1 ))
	WORLD_SIZE=$(du -ms ${WRKDIR}/world | awk '{print $1}')
	if [ ${WORLD_SIZE} -gt ${OS_SIZE} ]; then
		err 2 "Installed OS Partition needs: ${WORLD_SIZE}m, but the OS Partitions are only: ${OS_SIZE}m.  Increase -s"
	fi
	makefs -B little ${OS_SIZE:+-s ${OS_SIZE}}m -o label=${IMAGENAME} \
	       -o version=2 ${WRKDIR}/raw.img ${WRKDIR}/world
	;;
*firmware)
	# Configuring nanobsd-like mode
	# It re-use diskless(8) framework but using a /cfg configuration partition
	# It needs a "config save" script too, like the nanobsd example:
	#  /usr/src/tools/tools/nanobsd/Files/root/save_cfg
	# Or the BSDRP config script:
	#  https://github.com/ocochard/BSDRP/blob/master/BSDRP/Files/usr/local/sbin/config
	# Because rootfs is readonly, it create ramdisks for /etc and /var
	# Then we need to replace /tmp by a symlink to /var/tmp
	# For more information, read /etc/rc.initdiskless
	echo "/dev/gpt/${IMAGENAME}1 / ufs ro 1 1" >> ${WRKDIR}/world/etc/fstab
	echo '/dev/gpt/cfg  /cfg  ufs rw,noatime,noauto        2 2' >> ${WRKDIR}/world/etc/fstab
	echo '/dev/gpt/data /data ufs rw,noatime,noauto,failok 2 2' >> ${WRKDIR}/world/etc/fstab
	if [ -n "${SWAPSIZE}" -a "${SWAPSIZE}" != "0" ]; then
		echo '/dev/gpt/swapspace none swap sw 0 0' >> ${WRKDIR}/world/etc/fstab
	fi

	# Enable diskless(8) mode
	touch ${WRKDIR}/world/etc/diskless
	for d in cfg data; do
		mkdir -p ${WRKDIR}/world/$d
	done
	# Declare system name into /etc/nanobsd.conf: Allow to re-use nanobsd script
	echo "NANO_DRIVE=gpt/${IMAGENAME}" > ${WRKDIR}/world/etc/nanobsd.conf
	# Move /usr/local/etc to /etc/local (Only /etc will be backuped)
	if [ -d ${WRKDIR}/world/usr/local/etc ] ; then
		mkdir -p ${WRKDIR}/world/etc/local
		tar -C ${WRKDIR}/world -X ${excludelist} -cf - usr/local/etc/ | \
		    tar -xf - -C ${WRKDIR}/world/etc/local --strip-components=3
		rm -rf ${WRKDIR}/world/usr/local/etc
		ln -s /etc/local ${WRKDIR}/world/usr/local/etc
	fi
	# Copy /etc and /var to /conf/base as "reference"
	for d in var etc; do
		mkdir -p ${WRKDIR}/world/conf/base/$d ${WRKDIR}/world/conf/default/$d
		tar -C ${WRKDIR}/world -X ${excludelist} -cf - $d | tar -xf - -C ${WRKDIR}/world/conf/base
	done
	# Set ram disks size
	echo "$CFG_SIZE" > ${WRKDIR}/world/conf/base/etc/md_size
	echo "$CFG_SIZE" > ${WRKDIR}/world/conf/base/var/md_size
	echo "mount -o ro /dev/gpt/cfg" > ${WRKDIR}/world/conf/default/etc/remount
	# replace /tmp by a symlink to /var/tmp
	rm -rf ${WRKDIR}/world/tmp
	ln -s /var/tmp ${WRKDIR}/world/tmp

	# Copy save_cfg to /etc
	install ${mnt}/usr/src/tools/tools/nanobsd/Files/root/save_cfg ${WRKDIR}/world/conf/base/etc/

	# Figure out Partition sizes
	OS_SIZE=
	calculate_ospart_size "2" "${IMAGESIZE}" "${CFG_SIZE}" "${DATA_SIZE}" "${SWAPSIZE}"
	# Prune off a bit to fit the extra partitions and loaders
	OS_SIZE=$(( $OS_SIZE - 1 ))
	WORLD_SIZE=$(du -ms ${WRKDIR}/world | awk '{print $1}')
	if [ ${WORLD_SIZE} -gt ${OS_SIZE} ]; then
		err 2 "Installed OS Partition needs: ${WORLD_SIZE}m, but the OS Partitions are only: ${OS_SIZE}m.  Increase -s"
	fi

	# For correct booting it needs ufs formatted /cfg and /data partitions
	FTMPDIR=`mktemp -d -t poudriere-firmware` || exit 1
	# Set proper permissions to this empty directory: /cfg (so /etc) and /data once mounted will inherit them
	chmod -R 755 ${FTMPDIR}
	makefs -B little -s ${CFG_SIZE} ${WRKDIR}/cfg.img ${FTMPDIR}
	makefs -B little -s ${DATA_SIZE} ${WRKDIR}/data.img ${FTMPDIR}
	rm -rf ${FTMPDIR}
	makefs -B little -s ${OS_SIZE}m -o label=${IMAGENAME} \
		-o version=2 ${WRKDIR}/raw.img ${WRKDIR}/world
	;;
zrawdisk)
	cat >> ${WRKDIR}/world/boot/loader.conf <<-EOF
	zfs_load="YES"
	EOF
	cat >> ${WRKDIR}/world/etc/rc.conf <<-EOF
	zfs_enable="YES"
	EOF
	;;
tar)
	if [ -n "${MINIROOT}" ]; then
		mkminiroot
	fi
	;;
zsnapshot)
	do_clone -r ${WRKDIR}/world ${WRKDIR}/mnt
	;;
esac

if [ -f "${POST_BUILD_SCRIPT}" ]; then
	# Source the post-build-script.
	. "${POST_BUILD_SCRIPT}"
fi

case ${MEDIATYPE} in
iso)
	FINALIMAGE=${IMAGENAME}.iso
	espfilename=$(mktemp /tmp/efiboot.XXXXXX)
	make_esp_file ${espfilename} 10 ${WRKDIR}/world/boot/loader.efi
	makefs -t cd9660 -o rockridge -o label=${IMAGENAME} \
		-o publisher="poudriere" \
		-o bootimage="i386;${WRKDIR}/out/boot/cdboot" \
		-o bootimage="i386;${espfilename}" \
		-o platformid=efi \
		-o no-emul-boot "${OUTPUTDIR}/${FINALIMAGE}" ${WRKDIR}/world
	;;
iso+*mfs)
	FINALIMAGE=${IMAGENAME}.iso
	espfilename=$(mktemp /tmp/efiboot.XXXXXX)
	make_esp_file ${espfilename} 10 ${WRKDIR}/out/boot/loader.efi
	makefs -t cd9660 -o rockridge -o label=${IMAGENAME} \
		-o publisher="poudriere" \
		-o bootimage="i386;${WRKDIR}/out/boot/cdboot" \
		-o bootimage="i386;${espfilename}" \
		-o platformid=efi \
		-o no-emul-boot "${OUTPUTDIR}/${FINALIMAGE}" ${WRKDIR}/out
	rm -rf ${espfilename}
	;;
usb+*mfs)
	FINALIMAGE=${IMAGENAME}.img
	espfilename=$(mktemp /tmp/efiboot.XXXXXX)
	make_esp_file ${espfilename} 10 ${WRKDIR}/world/boot/loader.efi
	makefs -B little ${WRKDIR}/img.part ${WRKDIR}/out
	if [ "${arch}" == "amd64" ] || [ "${arch}" == "i386" ]; then
		pmbr="-b ${mnt}/boot/pmbr"
		gptboot="-p freebsd-boot:=${mnt}/boot/gptboot"
	fi
	mkimg -s gpt ${pmbr} \
	      -p efi:=${espfilename} \
	      ${gptboot}
	      -p freebsd-ufs:=${WRKDIR}/img.part \
	      -o "${OUTPUTDIR}/${FINALIMAGE}"
	rm -rf ${espfilename}
	;;
usb)
	FINALIMAGE=${IMAGENAME}.img
	if [ ${SWAPSIZE} != "0" ]; then
		SWAPCMD="-p freebsd-swap/swapspace::${SWAPSIZE}"
		if [ $SWAPBEFORE -eq 1 ]; then
			SWAPFIRST="$SWAPCMD"
		else
			SWAPLAST="$SWAPCMD"
		fi
	fi
	espfilename=$(mktemp /tmp/efiboot.XXXXXX)
	make_esp_file ${espfilename} 10 ${WRKDIR}/world/boot/loader.efi
	if [ "${arch}" == "amd64" ] || [ "${arch}" == "i386" ]; then
		pmbr="-b ${mnt}/boot/pmbr"
		gptboot="-p freebsd-boot:=${mnt}/boot/gptboot"
	fi
	mkimg -s gpt ${pmbr} \
		-p efi:=${espfilename} \
		${gptboot} \
		${SWAPFIRST} \
		-p freebsd-ufs:=${WRKDIR}/raw.img \
		${SWAPLAST} \
		-o "${OUTPUTDIR}/${FINALIMAGE}"
	rm -rf ${espfilename}
	;;
tar)
	FINALIMAGE=${IMAGENAME}.txz
	tar -f - -c -C ${WRKDIR}/world . | xz -T0 -c > "${OUTPUTDIR}/${FINALIMAGE}"
	;;
firmware)
	FINALIMAGE=${IMAGENAME}.img
	SWAPCMD="-p freebsd-swap/swapspace::${SWAPSIZE}"
	if [ $SWAPBEFORE -eq 1 ]; then
		SWAPFIRST="$SWAPCMD"
	else
		SWAPLAST="$SWAPCMD"
	fi
	espfilename=$(mktemp /tmp/efiboot.XXXXXX)
	make_esp_file ${espfilename} 10 ${WRKDIR}/world/boot/loader.efi
	mkimg -s gpt -C ${IMAGESIZE} -b ${mnt}/boot/pmbr \
		-p efi:=${espfilename} \
		-p freebsd-boot:=${mnt}/boot/gptboot \
		-p freebsd-ufs/${IMAGENAME}1:=${WRKDIR}/raw.img \
		-p freebsd-ufs/${IMAGENAME}2:=${WRKDIR}/raw.img \
		-p freebsd-ufs/cfg:=${WRKDIR}/cfg.img \
		${SWAPFIRST} \
		-p freebsd-ufs/data:=${WRKDIR}/data.img \
		${SWAPLAST} \
		-o "${OUTPUTDIR}/${FINALIMAGE}"
	rm -rf ${espfilename}
	;;
rawfirmware)
	FINALIMAGE=${IMAGENAME}.raw
	mv ${WRKDIR}/raw.img "${OUTPUTDIR}/${FINALIMAGE}"
	;;
rawdisk)
	FINALIMAGE=${IMAGENAME}.img
	umount ${WRKDIR}/world
	/sbin/mdconfig -d -u ${md#md}
	md=
	mv ${WRKDIR}/raw.img "${OUTPUTDIR}/${FINALIMAGE}"
	;;
dump)
	FINALIMAGE=${IMAGENAME}.dump
	umount ${WRKDIR}/world
	dump -0Raf ${WRKDIR}/raw.dump /dev/${md}
	/sbin/mdconfig -d -u ${md#md}
	md=
	mv ${WRKDIR}/raw.dump "${OUTPUTDIR}/${FINALIMAGE}"
	;;
zrawdisk)
	FINALIMAGE=${IMAGENAME}.img
	zfs umount -f ${zroot}/ROOT/default
	zfs set mountpoint=none ${zroot}/ROOT/default
	zfs set readonly=on ${zroot}/var/empty
	zpool set bootfs=${zroot}/ROOT/default ${zroot}
	zpool set autoexpand=on ${zroot}
	zpool export ${zroot}
	zroot=
	dd if=${mnt}/boot/zfsboot of=/dev/${md} count=1
	dd if=${mnt}/boot/zfsboot of=/dev/${md} iseek=1 oseek=1024
	/sbin/mdconfig -d -u ${md#md}
	md=
	mv ${WRKDIR}/raw.img "${OUTPUTDIR}/${FINALIMAGE}"
	;;
zsnapshot)
	FINALIMAGE=${IMAGENAME}

	rm -f ${WRKDIR}/mnt/.version
	echo ${SNAPSHOT_NAME} > ${WRKDIR}/mnt/.version
	chmod 400 ${WRKDIR}/mnt/.version

	if [ ! -z "${ORIGIN_IMAGE}" ]; then
		zfs diff \
       			${ZPOOL}${ZROOTFS}/images/work/${JAILNAME}@previous \
			${ZPOOL}${ZROOTFS}/images/work/${JAILNAME} > ${WRKDIR}/modified.files
	fi

	zfs umount ${ZPOOL}${ZROOTFS}/images/work/${JAILNAME}
	zfs set mountpoint=none \
       		${ZPOOL}${ZROOTFS}/images/work/${JAILNAME}
	zfs snapshot ${ZPOOL}${ZROOTFS}/images/work/${JAILNAME}@${SNAPSHOT_NAME}
	zfs send ${ZPOOL}${ZROOTFS}/images/work/${JAILNAME}@${SNAPSHOT_NAME} > ${WRKDIR}/raw.img
	FULL_HASH=$(sha512 -q ${WRKDIR}/raw.img)
	# snapshot have some sparse regions, gzip is here to avoid them
	gzip -1 ${WRKDIR}/raw.img

	if [ ! -z "${ORIGIN_IMAGE}" ]; then
		zfs send -i previous ${ZPOOL}${ZROOTFS}/images/work/${JAILNAME}@${SNAPSHOT_NAME} > ${WRKDIR}/incr.img
		INCR_HASH=$(sha512 -q ${WRKDIR}/incr.img)
		gzip -1 ${WRKDIR}/incr.img
	fi

	if [ ! -z "${ORIGIN_IMAGE}" ]; then
		echo "{\"full\":{\"filename\":\"${FINALIMAGE}-${SNAPSHOT_NAME}.full.img.gz\", \"sha512\": \"${FULL_HASH}\"},\"incr\":{\"filename\":\"${FINALIMAGE}-${SNAPSHOT_NAME}.incr.img.gz\", \"sha512\": \"${INCR_HASH}\", \"previous\":\"${PREVIOUS_SNAPSHOT_VERSION}\", \"changed\":\"${FINALIMAGE}-${SNAPSHOT_NAME}.modified.files\"}, \"version\":\"${SNAPSHOT_NAME}\",\"name\":\"${FINALIMAGE}\"}" > ${WRKDIR}/manifest.json
	else
		echo "{\"full\":{\"filename\":\"${FINALIMAGE}-${SNAPSHOT_NAME}.full.img.gz\", \"sha512\": \"${FULL_HASH}\"}, \"version\":\"${SNAPSHOT_NAME}\",\"name\":\"${FINALIMAGE}\"}" > ${WRKDIR}/manifest.json
	fi

	if [ ! -z "${ORIGIN_IMAGE}" ]; then
		mv ${WRKDIR}/incr.img.gz "${OUTPUTDIR}/${FINALIMAGE}-${SNAPSHOT_NAME}.incr.img.gz"
		mv ${WRKDIR}/modified.files "${OUTPUTDIR}/${FINALIMAGE}-${SNAPSHOT_NAME}.modified.files"
	fi
	mv ${WRKDIR}/raw.img.gz "${OUTPUTDIR}/${FINALIMAGE}-${SNAPSHOT_NAME}.full.img.gz"
	mv ${WRKDIR}/manifest.json "${OUTPUTDIR}/${FINALIMAGE}-${SNAPSHOT_NAME}.manifest.json"
	ln -s ${FINALIMAGE}-${SNAPSHOT_NAME}.manifest.json ${WRKDIR}/${FINALIMAGE}-latest.manifest.json
	mv ${WRKDIR}/${FINALIMAGE}-latest.manifest.json "${OUTPUTDIR}/${FINALIMAGE}-latest.manifest.json"
	;;
esac

CLEANUP_HOOK=delete_image
msg "Image available at: ${OUTPUTDIR}/${FINALIMAGE}"
