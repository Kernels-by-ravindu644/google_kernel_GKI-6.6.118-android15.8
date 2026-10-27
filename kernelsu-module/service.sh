#!/system/bin/sh
# KernelSU late_start service: load the shipped Wi-Fi drivers in load.conf order.
# They link against the phone's stock cfg80211/mac80211, so nothing is unloaded
# or replaced -- built-in Wi-Fi/BT keep working.

MODDIR="${0%/*}"
LOG="${MODDIR}/service.log"
loaded=0
failed=0

log() { echo "$(date '+%F %T') $*" >> "${LOG}"; }

# load.conf without comments and blank lines: one .ko per line.
module_list() {
	sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "${MODDIR}/load.conf"
}

is_loaded() {
	grep -q "^$(basename "$1" .ko | tr '-' '_') " /proc/modules
}

load_module() {
	if is_loaded "$1"; then
		log "$1: already loaded"
	elif insmod "${MODDIR}/modules/$1" 2>>"${LOG}"; then
		log "$1: loaded"
	else
		log "$1: FAILED (see dmesg)"
		failed=$((failed + 1))
		return
	fi
	loaded=$((loaded + 1))
}

# "<description> | ✅ 7 loaded, ❌ 0 failed" in the manager; the part after
# " | " is last boot's status, so drop it before appending the new one.
update_status() {
	sed -i "s/^\(description=[^|]*\) |.*$/\1/; s/^\(description=.*\)$/\1 | ✅ ${loaded} loaded, ❌ ${failed} failed/" \
		"${MODDIR}/module.prop"
	log "done: ${loaded} loaded, ${failed} failed"
}

main() {
	: > "${LOG}"
	# a here-doc, not a pipe: the loop must run in this shell to keep the counters
	while read -r ko; do
		load_module "${ko}"
	done <<EOF
$(module_list)
EOF
	update_status
}

main
