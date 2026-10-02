#!/usr/bin/env bash
# Power state of lab VMs: vm-power.sh <action> [name...]. Runs on the libvirt host as the host user.
#   status            the lab's VMs: state, RAM, memory in use on the host, saved RAM image
#   config  <name...> lab domain settings: vCPUs and RAM of the config, no autostart, free page
#                     reporting (the guest gives the memory it frees back to the host); takes
#                     effect at the next cold start
#   start   <name...> boot, or restore the saved RAM image and set the guest clock
#   stop    <name...> ACPI shutdown, forced off after 3 minutes
#   suspend <name...> save the RAM to $HOST_SAVED and stop (virsh save); Talos VMs are stopped
# The RAM images go to $HOST_SAVED on the lab store: libvirt's managed save would put them on the
# host's small root filesystem. An image is only restored if the VM's disks have not changed since
# it was saved; otherwise it is stale and removed.
source "$(dirname "$0")/../lib/remote.sh"

VIRSH="virsh -c $LIBVIRT_URI"
mkdir -p "$HOST_SAVED"

# state of a domain; virtqemud runs on demand and exits when idle, so a call can fail now and then
state() {
	local s i
	for i in 1 2 3 4 5; do
		s=$($VIRSH domstate "$1" 2>/dev/null | head -1)
		[ -n "$s" ] && { echo "$s"; return 0; }
		sleep 1
	done
	echo missing
}
exists() { $VIRSH dominfo "$1" >/dev/null 2>&1; }
image() { echo "$HOST_SAVED/$1.save"; }
# mtime and size of the VM's disks: an image only fits the disks it was saved with
disk_stamp() {
	local f
	for f in $($VIRSH domblklist "$1" --details | awk '$2 == "disk" {print $4}'); do
		stat -c '%n %Y %s' "$f"
	done
}
drop_image() { rm -f "$(image "$1")" "$HOST_SAVED/$1.disks"; }

config() {
	local vm=$1
	exists "$vm" || die "$vm does not exist"
	if [ "$($VIRSH dominfo "$vm" | awk '/^Autostart/ {print $2}')" = enable ]; then
		$VIRSH autostart --disable "$vm" >/dev/null
		log "$vm: autostart disabled"
	fi
	# vCPUs and RAM as the config says (a VM created with other values, or the config changed)
	local cpus ram
	cpus=$($VIRSH dumpxml --inactive "$vm" | sed -n 's/.*<vcpu[^>]*>\([0-9]*\)<.*/\1/p')
	ram=$($VIRSH dumpxml --inactive "$vm" | sed -n "s/.*<memory unit='KiB'>\([0-9]*\)<.*/\1/p")
	# (virt-xml takes one change at a time)
	if [ "$cpus" != "$(vm_field "$vm" cpus)" ]; then
		virt-xml --connect "$LIBVIRT_URI" "$vm" --edit --vcpus "$(vm_field "$vm" cpus)" >/dev/null ||
			die "$vm: cannot set the vCPUs"
		log "$vm: $(vm_field "$vm" cpus) vCPUs (from its next cold start)"
	fi
	if [ "$((ram / 1024))" != "$(vm_field "$vm" ram)" ]; then
		virt-xml --connect "$LIBVIRT_URI" "$vm" --edit --memory "$(vm_field "$vm" ram)" >/dev/null ||
			die "$vm: cannot set the RAM"
		log "$vm: $(vm_field "$vm" ram) MB RAM (from its next cold start)"
	fi
	if ! $VIRSH dumpxml --inactive "$vm" | grep -q "freePageReporting='on'"; then
		virt-xml --connect "$LIBVIRT_URI" "$vm" --edit \
			--memballoon model=virtio,freePageReporting=on >/dev/null 2>&1 ||
			die "$vm: cannot enable free page reporting"
		log "$vm: free page reporting enabled (from its next cold start)"
	fi
}

start() {
	local vm=$1 i
	case $(state "$vm") in
	running)
		# it was started behind our back: the image no longer fits its disks
		[ -e "$(image "$vm")" ] && { drop_image "$vm"; log "$vm: stale RAM image removed"; }
		log "$vm is running"
		return 0
		;;
	missing) die "$vm does not exist (lab create $vm)" ;;
	paused) $VIRSH resume "$vm" >/dev/null; log "$vm resumed"; return 0 ;;
	esac
	if [ -e "$(image "$vm")" ]; then
		if [ "$(disk_stamp "$vm")" = "$(cat "$HOST_SAVED/$vm.disks" 2>/dev/null)" ]; then
			$VIRSH restore "$(image "$vm")" --bypass-cache --running >/dev/null
			drop_image "$vm"
			# the guest clock stood still while it was saved, and chrony would only slew it
			for i in 1 2 3 4 5; do
				$VIRSH domtime "$vm" --sync >/dev/null 2>&1 && break
				[ $i = 5 ] && log "$vm: guest clock not set (no guest agent?)"
				sleep 2
			done
			log "$vm restored from its saved RAM"
			return 0
		fi
		drop_image "$vm"
		log "$vm: disks changed since its RAM was saved, image removed"
	fi
	$VIRSH start "$vm" >/dev/null
	log "$vm started"
}

stop() {
	local vm=$1 i
	case $(state "$vm") in
	"shut off") log "$vm is stopped"; return 0 ;;
	missing) die "$vm does not exist" ;;
	running) [ -e "$(image "$vm")" ] && drop_image "$vm" ;;
	esac
	$VIRSH shutdown "$vm" >/dev/null
	for i in $(seq 1 90); do
		[ "$(state "$vm")" = "shut off" ] && { log "$vm stopped"; return 0; }
		sleep 2
	done
	$VIRSH destroy "$vm" >/dev/null
	log "$vm did not shut down within 3 minutes, forced off"
}

suspend() {
	local vm=$1 img
	img=$(image "$vm")
	if [ "$(vm_field "$vm" role)" = talos ]; then
		# no guest agent to set the clock after a restore; Talos keeps its state on disk anyway
		log "$vm (Talos) is stopped instead"
		stop "$vm"
		return
	fi
	case $(state "$vm") in
	running) ;;
	"shut off") log "$vm is not running$([ -e "$img" ] && echo ", its RAM is saved")"; return 0 ;;
	*) die "$vm: cannot save in state $(state "$vm")" ;;
	esac
	rm -f "$img.part"
	$VIRSH save "$vm" "$img.part" --bypass-cache >/dev/null || { rm -f "$img.part"; die "$vm: save failed"; }
	mv "$img.part" "$img"
	disk_stamp "$vm" >"$HOST_SAVED/$vm.disks"
	log "$vm suspended: $(du -h --apparent-size "$img" | cut -f1) of RAM in $img"
}

status() {
	local vm st ram use saved notes
	printf '  %-10s %-9s %6s %7s %7s  %s\n' VM STATE RAM IN-USE SAVED NOTES
	for vm in $(vm_names); do
		st=$(state "$vm") ram=- use=- saved=- notes=""
		if [ "$st" != missing ]; then
			ram=$($VIRSH dominfo "$vm" | awk '/^Max memory/ {printf "%.1fG", $3 / 1048576}')
			[ "$st" = running ] &&
				use=$($VIRSH dommemstat "$vm" 2>/dev/null | awk '/^rss/ {printf "%.1fG", $2 / 1048576}')
			[ "$($VIRSH dominfo "$vm" | awk '/^Autostart/ {print $2}')" = enable ] && notes="autostart "
			$VIRSH dumpxml "$vm" | grep -q "freePageReporting='on'" ||
				notes="${notes}no-page-reporting"
		fi
		if [ -e "$(image "$vm")" ]; then
			saved=$(du -h --apparent-size "$(image "$vm")" | cut -f1)
			[ "$st" = "shut off" ] && st=saved
		fi
		printf '  %-10s %-9s %6s %7s %7s  %s\n' "$vm" "$st" "$ram" "$use" "$saved" "$notes"
	done
	awk '/^MemTotal/ {t = $2} /^MemAvailable/ {a = $2}
		END {printf "  host: %.1fG RAM, %.1fG available\n", t / 1048576, a / 1048576}' /proc/meminfo
}

# figures for bin/lab, in MB: "host <available>", then per VM
# "<name> <running|stopped|saved|missing|...> <RAM> <saved image> <in use>"
mem() {
	local vm st ram img use
	awk '/^MemAvailable/ {printf "host %d\n", $2 / 1024}' /proc/meminfo
	for vm in $(vm_names); do
		st=$(state "$vm" | tr ' ' '-') ram=0 img=0 use=0
		[ "$st" = shut-off ] && st=stopped
		if [ "$st" != missing ]; then
			ram=$($VIRSH dominfo "$vm" | awk '/^Max memory/ {printf "%d", $3 / 1024}')
			[ "$st" = running ] &&
				use=$($VIRSH dommemstat "$vm" 2>/dev/null | awk '/^rss/ {printf "%d", $2 / 1024}')
		fi
		if [ -e "$(image "$vm")" ]; then
			img=$(($(stat -c %s "$(image "$vm")") / 1048576))
			[ "$st" = stopped ] && st=saved
		fi
		echo "$vm $st $ram $img ${use:-0}"
	done
}

action=${1:?action: status, mem, config, start, stop or suspend}
shift
case $action in
status) status ;;
mem) mem ;;
config | start | stop | suspend) for vm in "$@"; do "$action" "$vm"; done ;;
*) die "unknown action $action" ;;
esac
