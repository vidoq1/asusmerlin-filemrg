#!/bin/sh
#
#
# Copyright (c) 2026 Albert Sayapov
# SPDX-License-Identifier: MIT
#
# File Manager for Asuswrt-Merlin: installer / repair tool.
#
#   sh install.sh install     Install or repair (idempotent)
#   sh install.sh status      Show state
#   sh install.sh uninstall   Remove everything this tool added
#
# Only marker blocks of this tool are written to shared hook files
# (existing content and other add-ons' blocks are preserved). No other
# add-on, helper.sh or firmware slot allocator is used or required.
#

set -u

PATH="/sbin:/bin:/usr/sbin:/usr/bin:/opt/sbin:/opt/bin"
export PATH

DIR="${FM_DIR:-/jffs/addons/filemgr}"
PAYLOAD="$DIR/payload"
SCRIPTS="${FM_SCRIPTS:-/jffs/scripts}"
SETTINGS="${FM_SETTINGS:-/jffs/addons/custom_settings.txt}"
TREE="${FM_TREE:-/tmp/menuTree.js}"
WWW_USER="${FM_WWW_USER:-/www/user}"
WEB="${FM_WEB:-/tmp/filemgr-web}"
PRIV="${FM_PRIV:-/tmp/filemgr-private}"
VERSION="2.1.0"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$DIR/install-backup-$STAMP"
export DIR WEB PRIV SETTINGS
BEGIN='# BEGIN FILEMGR WEBUI'
END='# END FILEMGR WEBUI'

log() {
    echo "$*"
    logger -t filemgr-install "$*" 2>/dev/null || true
}

die() {
    log "ERROR: $*"
    exit 1
}

require_root() {
    probe="$SCRIPTS/.filemgr-write-test.$$"
    mkdir -p "$SCRIPTS" 2>/dev/null
    : > "$probe" 2>/dev/null || die "Need write access to $SCRIPTS."
    rm -f "$probe"
}

ensure_script() {
    file="$1"

    if [ ! -f "$file" ]; then
        printf '%s\n' '#!/bin/sh' > "$file" || return 1
    fi

    chmod 755 "$file"
}

backup_file() {
    file="$1"

    [ -f "$file" ] || return 0
    mkdir -p "$BACKUP"
    cp -p "$file" "$BACKUP/$(basename "$file")"
}

strip_block() {
    file="$1"

    [ -f "$file" ] || return 0

    awk -v begin="$BEGIN" -v end="$END" '
        $0 == begin { inside=1; next }
        $0 == end   { inside=0; next }
        !inside     { print }
    ' "$file" > "$file.tmp.$$" || return 1

    cat "$file.tmp.$$" > "$file" || {
        rm -f "$file.tmp.$$"
        return 1
    }

    rm -f "$file.tmp.$$"
}

append_block() {
    file="$1"
    content="$2"

    ensure_script "$file" || return 1
    strip_block "$file" || return 1

    {
        printf '\n%s\n' "$BEGIN"
        printf '%s\n' "$content"
        printf '%s\n' "$END"
    } >> "$file" || return 1

    chmod 755 "$file"
}

extract_payload() {
    mkdir -p "$PAYLOAD" || die "Cannot create $PAYLOAD"
    cat > "$PAYLOAD/lib.sh" <<'__FM_LIB_EOF__'
#!/bin/sh
# FILEMGR_LIB_V2
: "${DIR:=/jffs/addons/filemgr}"
: "${WEB:=/tmp/filemgr-web}"
: "${PRIV:=/tmp/filemgr-private}"
: "${SETTINGS:=/jffs/addons/custom_settings.txt}"
: "${JFFS:=/jffs}"
: "${MNTBASE:=/tmp/mnt}"
: "${PROC_MOUNTS:=/proc/mounts}"
: "${FLOCK:=/usr/bin/flock}"
: "${LS:=ls}"
: "${LOCKFILE:=/tmp/filemgr-handler.lock}"
: "${MAXDL:=52428800}"
: "${TTL:=300}"
: "${MAXENTRIES:=1000}"
: "${MAXPREPARED:=2}"
: "${EXCLUDE:=}"
PATH="/sbin:/bin:/usr/sbin:/usr/bin:/opt/sbin:/opt/bin"
export PATH
LC_ALL=C
export LC_ALL
TAB="$(printf '\t')"

if [ -z "${B64:-}" ]; then
    if [ -x /opt/bin/base64 ]; then
        B64="/opt/bin/base64"
    elif /bin/busybox base64 </dev/null >/dev/null 2>&1; then
        B64="/bin/busybox base64"
    else
        B64=""
    fi
fi

get_setting() {
    grep "^$1 " "$SETTINGS" 2>/dev/null | head -n 1 | cut -d' ' -f2-
}

log() { logger -t filemgr "$*" 2>/dev/null || :; }

json_str() {
    printf '%s' "$1" | tr -d '\000-\037\177' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

valid_id() {
    case "$1" in ''|*[!0-9a-f]*) return 1 ;; esac
    [ "${#1}" -eq 32 ]
}

valid_req() {
    case "$1" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
    [ "${#1}" -ge 8 ] && [ "${#1}" -le 64 ]
}

new_hex() {
    dd if=/dev/urandom bs=64 count=1 2>/dev/null | md5sum | cut -c1-32
}

hash_token() {
    printf '%s' "$1" | md5sum | cut -d' ' -f1
}

vol_id() {
    printf '%s' "$1" | md5sum | cut -c1-12
}

clear_request() {
    [ -f "$SETTINGS" ] || return 0
    sed -i '/^_filemgr_action /d; /^_filemgr_request /d; /^_filemgr_vol /d; /^_filemgr_path /d; /^_filemgr_dlid /d; /^_filemgr_token /d' "$SETTINGS"
}

put_result_file() {
    chmod 644 "$1" && mv -f "$1" "$WEB/res-$REQ.json"
}

put_result() {
    printf '%s\n' "$1" > "$WEB/.res-$REQ.tmp" && put_result_file "$WEB/.res-$REQ.tmp"
}

fail() {
    put_result "{\"ok\":false,\"error\":\"$1\"}"
    log "request=$REQ action=$ACTION error=$1"
    return 0
}

volumes_raw() {
    awk -v jffs="$JFFS" -v base="$MNTBASE/" -v excl="$EXCLUDE" '
        $2 == jffs { if (!j++) print "jffs\t" jffs "\t" $3 "\t" $1; next }
        $1 ~ /^\/dev\/sd[a-z]+[0-9]*$/ && index($2, base) == 1 {
            if (seen[$1]++) next
            m = $2
            if (m ~ /\\01[12]/) next
            gsub(/\\040/, " ", m)
            if (m == excl) next
            print "usb\t" m "\t" $3 "\t" $1
        }' "$PROC_MOUNTS"
}

publish_volumes() {
    {
        printf '{"ok":true,"volumes":['
        _sep=""
        volumes_raw | while IFS="$TAB" read -r _k _mp _fs _dev; do
            [ -d "$_mp" ] || continue
            if [ "$_k" = jffs ]; then _label="JFFS"; else _label="${_mp##*/}"; fi
            printf '%s{"id":"%s","kind":"%s","label":"%s","path":"%s","fs":"%s","dev":"%s"}' \
                "$_sep" "$(vol_id "$_mp")" "$_k" "$(json_str "$_label")" "$(json_str "$_mp")" \
                "$(json_str "$_fs")" "$(json_str "$_dev")"
            _sep=","
        done
        printf ']}\n'
    } > "$WEB/.volumes.tmp" && chmod 644 "$WEB/.volumes.tmp" && mv -f "$WEB/.volumes.tmp" "$WEB/volumes.json"
}

VOL_ROOT=""
VOL_KIND=""

resolve_volume() {
    VOL_ROOT=""
    VOL_KIND=""
    case "$1" in ''|*[!0-9a-f]*) return 1 ;; esac
    [ "${#1}" -eq 12 ] || return 1
    _want="$1"
    _hit="$(volumes_raw | while IFS="$TAB" read -r _k _mp _fs _dev; do
        if [ "$(vol_id "$_mp")" = "$_want" ]; then
            printf '%s\t%s' "$_k" "$_mp"
            break
        fi
    done)"
    [ -n "$_hit" ] || return 1
    VOL_KIND="${_hit%%"$TAB"*}"
    VOL_ROOT="${_hit#*"$TAB"}"
    [ -d "$VOL_ROOT" ] && [ ! -L "$VOL_ROOT" ]
}

REL=""

decode_rel() {
    REL=""
    [ -n "$1" ] || return 0
    case "$1" in *[!0-9a-f]*) return 1 ;; esac
    [ "${#1}" -le 4096 ] || return 1
    [ $(( ${#1} % 2 )) -eq 0 ] || return 1
    _esc="$(printf '%s' "$1" | awk '{
        h = "0123456789abcdef"
        for (i = 1; i <= length($0); i += 2) {
            v = (index(h, substr($0, i, 1)) - 1) * 16 + index(h, substr($0, i + 1, 1)) - 1
            if (v < 32 || v == 127) exit 1
            printf "\\0%03o", v
        }
    }')" || return 1
    REL="$(printf '%b' "$_esc")"
    [ -n "$REL" ] || return 1
    case "$REL" in /*|*//*|*/) return 1 ;; esac
    _oi="$IFS"
    IFS=/
    set -f
    for _s in $REL; do
        case "$_s" in
            ''|.|..) IFS="$_oi"; set +f; return 1 ;;
        esac
    done
    IFS="$_oi"
    set +f
    return 0
}

TARGET=""

walk_check() {
    TARGET="$1"
    [ -d "$TARGET" ] && [ ! -L "$TARGET" ] || return 1
    [ -n "$2" ] || return 0
    _oi="$IFS"
    IFS=/
    set -f
    for _s in $2; do
        TARGET="$TARGET/$_s"
        if [ -L "$TARGET" ] || [ ! -e "$TARGET" ]; then
            IFS="$_oi"
            set +f
            return 1
        fi
    done
    IFS="$_oi"
    set +f
    return 0
}

is_protected() {
    [ "$VOL_KIND" = jffs ] || return 1
    case "$1" in
        addons/filemgr|addons/filemgr/*|addons/custom_settings.txt|scripts/*) return 0 ;;
    esac
    return 1
}

file_size() {
    $LS -ln -- "$1" 2>/dev/null | awk 'NR == 1 { print $5 }'
}

TF=""

detect_time_flag() {
    TF=""
    for _o in --full-time -e; do
        _ok="$($LS -lnd $_o -- "$1" 2>/dev/null | head -n 1 | awk '{
            if ($6 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ || $6 ~ /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)$/) print "ok"
        }')"
        if [ "$_ok" = ok ]; then
            TF="$_o"
            return 0
        fi
    done
    return 0
}

cleanup_download() {
    valid_id "$1" || return 1
    rm -f "$WEB/dl-$1.json" "$WEB/.dl-$1.tmp" "$PRIV/$1.rec"
    return 0
}

purge_expired() {
    _now="$(date +%s)"
    for _f in "$PRIV"/*.rec; do
        [ -f "$_f" ] || continue
        _i="${_f##*/}"
        _i="${_i%.rec}"
        valid_id "$_i" || continue
        _exp="$(sed -n '2p' "$_f")"
        case "$_exp" in ''|*[!0-9]*) _exp=0 ;; esac
        [ "$_exp" -gt "$_now" ] || cleanup_download "$_i"
    done
}

count_prepared() {
    _n=0
    for _f in "$PRIV"/*.rec; do
        [ -f "$_f" ] && _n=$((_n + 1))
    done
    echo "$_n"
}

op_list() {
    walk_check "$VOL_ROOT" "$REL" || { fail not_found; return 0; }
    [ -d "$TARGET" ] || { fail not_directory; return 0; }
    detect_time_flag "$TARGET"
    {
        printf '{"ok":true,"entries":['
        $LS -lnA $TF -- "$TARGET" 2>/dev/null | awk -v limit="$MAXENTRIES" -v cy="$(date +%Y)" -v cm="$(date +%m)" -v cd="$(date +%d)" '
            function esc(s) {
                gsub(/\\/, "\\\\", s)
                gsub(/"/, "\\\"", s)
                gsub(/[\001-\037\177]/, "", s)
                return s
            }
            BEGIN {
                split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", mn, " ")
                for (i = 1; i <= 12; i++) mi[mn[i]] = i
                cy += 0; cm += 0; cd += 0
            }
            /^total / { next }
            {
                t = substr($1, 1, 1)
                if (t != "d" && t != "-") next
                if ($6 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) {
                    npre = 8
                    m = $6 " " substr($7, 1, 8)
                } else if ($6 ~ /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)$/) {
                    npre = 10
                    m = sprintf("%04d-%02d-%02d %s", $10, mi[$7], $8, $9)
                } else {
                    npre = 8
                    mon = mi[$6]; day = $7 + 0
                    if ($8 ~ /:/) {
                        y = cy
                        if (mon > cm || (mon == cm && day > cd)) y = cy - 1
                        m = sprintf("%04d-%02d-%02d %s", y, mon, day, $8)
                    } else {
                        m = sprintf("%04d-%02d-%02d", $8, mon, day)
                    }
                }
                name = $0
                for (i = 1; i <= npre; i++) sub(/^[^ ]+ +/, "", name)
                if (n >= limit) { trunc = 1; next }
                printf "%s{\"n\":\"%s\",\"d\":%s,\"s\":%d,\"m\":\"%s\"}", (n++ ? "," : ""), esc(name), (t == "d" ? "true" : "false"), $5, esc(m)
            }
            END { printf "],\"truncated\":%s}\n", (trunc ? "true" : "false") }'
    } > "$WEB/.res-$REQ.tmp" && put_result_file "$WEB/.res-$REQ.tmp"
}

op_download() {
    [ -n "$B64" ] || { fail no_base64; return 0; }
    [ -n "$REL" ] || { fail not_file; return 0; }
    walk_check "$VOL_ROOT" "$REL" || { fail not_found; return 0; }
    [ -f "$TARGET" ] || { fail not_file; return 0; }
    _size="$(file_size "$TARGET")"
    case "$_size" in ''|*[!0-9]*) fail stat_failed; return 0 ;; esac
    [ "$_size" -le "$MAXDL" ] || { fail too_large; return 0; }
    [ "$(count_prepared)" -lt "$MAXPREPARED" ] || { fail busy; return 0; }

    _id="$(new_hex)"
    _tok="$(new_hex)"
    valid_id "$_id" && valid_id "$_tok" || { fail id_failed; return 0; }

    _name="${TARGET##*/}"
    {
        printf '{"name":"%s","size":%s,"base64":"' "$(json_str "$_name")" "$_size"
        $B64 "$TARGET" | tr -d '\r\n'
        printf '"}\n'
    } > "$WEB/.dl-$_id.tmp" || { cleanup_download "$_id"; fail read_failed; return 0; }

    chmod 644 "$WEB/.dl-$_id.tmp" && mv -f "$WEB/.dl-$_id.tmp" "$WEB/dl-$_id.json" \
        || { cleanup_download "$_id"; fail publish_failed; return 0; }

    {
        hash_token "$_tok"
        echo $(( $(date +%s) + TTL ))
    } > "$PRIV/$_id.rec"

    ( sleep "$TTL"; "$DIR/handler.sh" expire "$_id" ) </dev/null >/dev/null 2>&1 8>&- &

    put_result "{\"ok\":true,\"id\":\"$_id\",\"token\":\"$_tok\",\"payload\":\"dl-$_id.json\",\"size\":$_size}"
    log "request=$REQ prepared download id=$_id size=$_size"
}

op_cleanup() {
    valid_id "$DLID" && valid_id "$TOKEN" || { fail bad_request; return 0; }
    [ -f "$PRIV/$DLID.rec" ] || { fail unknown_download; return 0; }
    _have="$(sed -n '1p' "$PRIV/$DLID.rec")"
    [ "$_have" = "$(hash_token "$TOKEN")" ] || { fail denied; return 0; }
    cleanup_download "$DLID"
    put_result '{"ok":true}'
}

op_delete() {
    [ -n "$REL" ] || { fail not_file; return 0; }
    is_protected "$REL" && { fail protected; return 0; }
    walk_check "$VOL_ROOT" "$REL" || { fail not_found; return 0; }
    [ -f "$TARGET" ] || { fail not_file; return 0; }
    rm -f -- "$TARGET" || { fail delete_failed; return 0; }
    log "request=$REQ deleted vol=$VOL_ROOT"
    put_result '{"ok":true}'
}
__FM_LIB_EOF__
    cat > "$PAYLOAD/handler.sh" <<'__FM_HANDLER_EOF__'
#!/bin/sh
# FILEMGR_HANDLER_V2
. "${FM_LIB:-/jffs/addons/filemgr/lib.sh}"

umask 077
mkdir -p "$WEB" "$PRIV" || exit 1
chmod 755 "$WEB"
chmod 700 "$PRIV"

exec 8>"$LOCKFILE"
"$FLOCK" -x 8 || exit 1

case "${1:-}" in
    expire)
        cleanup_download "${2:-}"
        exit 0
        ;;
    publish)
        EXCLUDE="${2:-}"
        publish_volumes
        exit 0
        ;;
esac

ACTION="$(get_setting _filemgr_action)"
REQ="$(get_setting _filemgr_request)"
VOLID="$(get_setting _filemgr_vol)"
PATHHEX="$(get_setting _filemgr_path)"
DLID="$(get_setting _filemgr_dlid)"
TOKEN="$(get_setting _filemgr_token)"
clear_request

valid_req "$REQ" || exit 1

rm -f "$WEB"/res-*.json "$WEB"/.res-*.tmp
purge_expired

case "$ACTION" in
    volumes)
        publish_volumes
        put_result '{"ok":true}'
        ;;
    list|download|delete)
        resolve_volume "$VOLID" || { fail volume_unavailable; exit 0; }
        decode_rel "$PATHHEX" || { fail bad_path; exit 0; }
        case "$ACTION" in
            list) op_list ;;
            download) op_download ;;
            delete) op_delete ;;
        esac
        ;;
    cleanup)
        op_cleanup
        ;;
    *)
        fail bad_action
        ;;
esac
exit 0
__FM_HANDLER_EOF__
    cat > "$PAYLOAD/mount.sh" <<'__FM_MOUNT_EOF__'
#!/bin/sh
# FILEMGR_MOUNT_V2
DIR="${DIR:-/jffs/addons/filemgr}"
. "$DIR/lib.sh"

WWW_USER="${FM_WWW_USER:-/www/user}"
MENU_SRC="${FM_MENU_SRC:-/www/require/modules/menuTree.js}"
TREE="${FM_TREE:-/tmp/menuTree.js}"
MENULOCK="${FM_MENULOCK:-/tmp/addonwebui.lock}"

for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
    [ -f "$MENU_SRC" ] && break
    sleep 5
done
[ -f "$MENU_SRC" ] || { logger -t filemgr "menuTree.js not found"; exit 1; }

mkdir -p "$WWW_USER" "$WEB" "$PRIV" || exit 1
chmod 755 "$WEB"
chmod 700 "$PRIV"

exec 9>"$MENULOCK"
"$FLOCK" -x 9 || exit 1

[ -f "$TREE" ] || cp "$MENU_SRC" "$TREE" || exit 1

ANCHOR=""
for a in Advanced_SettingBackup_Content.asp Advanced_FirmwareUpgrade_Content.asp Advanced_System_Content.asp Advanced_VLAN_Switch_Content.asp Advanced_SwitchCtrl_Content.asp; do
    if grep -Fq "$a" "$TREE"; then
        ANCHOR="$a"
        break
    fi
done
[ -n "$ANCHOR" ] || { logger -t filemgr "menu anchor not found; no menu changes made"; exit 1; }

slot_free() {
    [ ! -e "$WWW_USER/user$1.asp" ] || return 1
    if grep -v 'filemgr-webui' "$TREE" | grep -Eq "user$1\\.asp([^0-9A-Za-z]|\$)"; then
        return 1
    fi
    return 0
}

PAGE=""
for f in "$WWW_USER"/user*.asp; do
    if [ -f "$f" ] && grep -q 'FILEMGR_WEBUI_V2' "$f"; then
        PAGE="${f##*/}"
        break
    fi
done

if [ -z "$PAGE" ]; then
    prev="$(cat "$DIR/page" 2>/dev/null)"
    case "$prev" in
        user[1-9].asp)
            n="${prev#user}"
            n="${n%.asp}"
            slot_free "$n" && PAGE="$prev"
            ;;
    esac
fi

if [ -z "$PAGE" ]; then
    for n in 9 8 7 6 5 4 3 2 1; do
        if slot_free "$n"; then
            PAGE="user$n.asp"
            break
        fi
    done
fi
[ -n "$PAGE" ] || { logger -t filemgr "no free userX.asp slot"; exit 1; }

if [ -e "$WWW_USER/filemgr" ] && [ ! -L "$WWW_USER/filemgr" ]; then
    logger -t filemgr "resource path $WWW_USER/filemgr is occupied"
    exit 1
fi
if [ -L "$WWW_USER/filemgr" ] && [ "$(readlink "$WWW_USER/filemgr")" != "$WEB" ]; then
    logger -t filemgr "resource symlink belongs to another module"
    exit 1
fi
ln -snf "$WEB" "$WWW_USER/filemgr"
cp "$DIR/filemgr.asp" "$WWW_USER/$PAGE" || exit 1
chmod 644 "$WWW_USER/$PAGE"
printf '%s\n' "$PAGE" > "$DIR/page"

awk -v anchor="$ANCHOR" -v page="$PAGE" '
    /filemgr-webui/ { next }
    { print }
    !added && index($0, anchor) {
        print "{url: \"" page "\", tabName: \"File Manager\"}, // filemgr-webui"
        added = 1
    }
' "$TREE" > "$TREE.filemgr.$$" || exit 1
cat "$TREE.filemgr.$$" > "$TREE"
rm -f "$TREE.filemgr.$$"

if [ -z "${FM_TEST:-}" ] && ! grep -Fq " $MENU_SRC " /proc/mounts; then
    mount -o bind "$TREE" "$MENU_SRC" || exit 1
fi

"$DIR/handler.sh" publish

logger -t filemgr "mounted page=$PAGE anchor=$ANCHOR"
echo "File Manager -> $PAGE (menu anchor: $ANCHOR)"
__FM_MOUNT_EOF__
    cat > "$PAYLOAD/filemgr.asp" <<'__FM_ASP_EOF__'
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
<meta http-equiv="X-UA-Compatible" content="IE=Edge">
<meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
<meta http-equiv="Cache-Control" content="no-cache, no-store, must-revalidate">
<meta http-equiv="Pragma" content="no-cache">
<meta http-equiv="Expires" content="-1">
<link rel="shortcut icon" href="images/favicon.png">
<link rel="icon" href="images/favicon.png">
<title>File Manager</title>
<!-- FILEMGR_WEBUI_V2 -->
<link rel="stylesheet" type="text/css" href="index_style.css">
<link rel="stylesheet" type="text/css" href="form_style.css">
<style>
.fm-bar{margin:6px 0 10px 0;overflow:hidden}
.fm-crumbs{float:left;font-size:13px;color:#cfd8dc;padding-top:6px}
.fm-crumbs a{color:#7fd0ff;cursor:pointer;text-decoration:none}
.fm-btns{float:right}
.fm-status{min-height:18px;margin:4px 0 8px 0;font-size:12px;color:#ffd27f}
.fm-status.err{color:#ff8a80}
table.fm-list{width:100%;border-collapse:collapse;font-size:13px;color:#fff}
table.fm-list th{padding:5px 6px;border-bottom:1px solid #6b8fa3;text-align:left;color:#cfd8dc;font-weight:normal;font-size:12px}
table.fm-list td{padding:5px 6px;border-bottom:1px solid #3d4b50;vertical-align:middle}
table.fm-list tr.fm-row:hover{background:#34444a}
.fm-ico{width:28px}
.fm-ico svg{width:22px;height:22px;display:block}
.fm-name{word-break:break-all}
.fm-name a{color:#fff;cursor:pointer;text-decoration:none}
.fm-size{width:80px;text-align:right;color:#b0bec5;white-space:nowrap}
.fm-mod{width:140px;color:#b0bec5;white-space:nowrap}
.fm-act{width:130px;text-align:right;white-space:nowrap}
.fm-act a{color:#7fd0ff;cursor:pointer;margin-left:10px}
.fm-act a.del{color:#ff8a80}
.fm-vol{display:inline-block;width:210px;margin:6px 10px 6px 0;padding:10px;border:1px solid #5b6a70;border-radius:6px;background:#2a353a;cursor:pointer;vertical-align:top}
.fm-vol:hover{background:#34444a}
.fm-vol b{display:block;color:#fff}
.fm-vol span{display:block;font-size:11px;color:#b0bec5;word-break:break-all}
</style>
<script type="text/javascript" src="/js/jquery.js"></script>
<script type="text/javascript" src="/state.js"></script>
<script type="text/javascript" src="/general.js"></script>
<script type="text/javascript" src="/popup.js"></script>
<script type="text/javascript" src="/help.js"></script>
<script type="text/javascript" src="/detect.js"></script>
<script id="addon-settings" type="application/json"><% get_custom_settings(); %></script>
<script>
function SetCurrentPage() {
  document.form.next_page.value = window.location.pathname.substring(1);
  document.form.current_page.value = window.location.pathname.substring(1);
}
var FM = (function () {
  'use strict';
  var BASE = '/user/filemgr/';
  var KEYS = ['_filemgr_action', '_filemgr_request', '_filemgr_vol', '_filemgr_path', '_filemgr_dlid', '_filemgr_token'];
  var ERR = {
    volume_unavailable: 'This storage is no longer mounted.',
    not_found: 'Path not found.',
    not_directory: 'Not a folder.',
    not_file: 'Not a regular file.',
    bad_path: 'Invalid path.',
    too_large: 'File is larger than the 50 MiB download limit.',
    busy: 'Too many prepared downloads. Try again shortly.',
    protected: 'This file is protected by the File Manager.',
    delete_failed: 'Delete failed (read-only or in use).',
    denied: 'Cleanup request denied.',
    unknown_download: 'Download record not found.',
    no_base64: 'The router has no base64 tool (install Entware coreutils-base64).'
  };
  var SVG_DIR = '<svg viewBox="0 0 24 24"><path fill="#f2b84b" d="M10 4H4a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-8z"/></svg>';
  var SVG_FILE = '<svg viewBox="0 0 24 24"><path fill="#b0bec5" d="M6 2h8l6 6v12a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2z"/><path fill="#78909c" d="M14 2v6h6z"/></svg>';
  var busy = false, volumes = [], vol = null, parts = [];

  function $(id) { return document.getElementById(id); }
  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
  function rid() {
    var a = new Uint8Array(12);
    crypto.getRandomValues(a);
    return Array.prototype.map.call(a, function (b) { return ('0' + b.toString(16)).slice(-2); }).join('');
  }
  function hex(s) {
    var b = new TextEncoder().encode(s), x = '';
    for (var i = 0; i < b.length; i++) x += ('0' + b[i].toString(16)).slice(-2);
    return x;
  }
  function pathHex(list) { return list.length ? hex(list.join('/')) : ''; }
  function fmtSize(n) {
    if (n < 1024) return n + ' B';
    if (n < 1048576) return (n / 1024).toFixed(1) + ' KiB';
    if (n < 1073741824) return (n / 1048576).toFixed(1) + ' MiB';
    return (n / 1073741824).toFixed(2) + ' GiB';
  }
  function status(msg, isErr) {
    var el = $('fm-status');
    el.textContent = msg || '';
    el.className = 'fm-status' + (isErr ? ' err' : '');
  }
  function setBusy(v) {
    busy = v;
    var btns = document.querySelectorAll('.fm-btns input');
    for (var i = 0; i < btns.length; i++) btns[i].disabled = v;
  }
  function errText(code) { return ERR[code] || ('Error: ' + code); }

  async function freshSettings() {
    var r = await fetch(location.pathname + '?settings=' + Date.now(), { cache: 'no-store', credentials: 'same-origin' });
    if (!r.ok) throw new Error('Failed to read WebUI settings.');
    var d = new DOMParser().parseFromString(await r.text(), 'text/html');
    var e = d.getElementById('addon-settings');
    if (!e) throw new Error('WebUI session may have expired. Sign in again.');
    return JSON.parse(e.textContent);
  }

  async function send(action, fields) {
    var settings = await freshSettings();
    KEYS.forEach(function (k) { delete settings[k]; });
    var id = rid();
    settings._filemgr_action = action;
    settings._filemgr_request = id;
    Object.keys(fields || {}).forEach(function (k) { settings['_filemgr_' + k] = fields[k]; });
    var params = new URLSearchParams();
    new FormData(document.form).forEach(function (v, k) { params.set(k, v); });
    params.set('amng_custom', JSON.stringify(settings));
    var post = await fetch('/start_apply.htm', { method: 'POST', body: params, credentials: 'same-origin', cache: 'no-store' });
    if (!post.ok) throw new Error('Router rejected the request (HTTP ' + post.status + ').');
    var url = BASE + 'res-' + id + '.json';
    var t0 = Date.now();
    while (Date.now() - t0 < 120000) {
      await sleep(400);
      try {
        var r = await fetch(url + '?t=' + Date.now(), { cache: 'no-store', credentials: 'same-origin' });
        if (r.ok) return await r.json();
      } catch (e) { /* keep polling */ }
    }
    throw new Error('No response from router (timeout or session expired).');
  }

  function crumbs() {
    var c = $('fm-crumbs');
    c.textContent = '';
    function link(text, fn) {
      var a = document.createElement('a');
      a.textContent = text;
      a.onclick = fn;
      c.appendChild(a);
    }
    link('Storage', function () { if (!busy) showVolumes(); });
    if (vol) {
      c.appendChild(document.createTextNode(' / '));
      link(vol.label, function () { if (!busy) openDir([]); });
      parts.forEach(function (p, i) {
        c.appendChild(document.createTextNode(' / '));
        link(p, function () { if (!busy) openDir(parts.slice(0, i + 1)); });
      });
    }
  }

  function headRow() {
    var tr = document.createElement('tr');
    ['', 'Name', 'Size', 'Modified', ''].forEach(function (h, i) {
      var th = document.createElement('th');
      th.textContent = h;
      if (i === 2) th.style.textAlign = 'right';
      tr.appendChild(th);
    });
    return tr;
  }

  function render(entries) {
    var box = $('fm-content');
    box.textContent = '';
    if (!vol) {
      if (!volumes.length) { box.textContent = 'No storage available.'; return; }
      volumes.forEach(function (v) {
        var d = document.createElement('div');
        d.className = 'fm-vol';
        var b = document.createElement('b'); b.textContent = v.label;
        var s1 = document.createElement('span'); s1.textContent = v.path;
        var s2 = document.createElement('span'); s2.textContent = v.fs + (v.kind === 'usb' ? ' \u00b7 ' + v.dev : '');
        d.appendChild(b); d.appendChild(s1); d.appendChild(s2);
        d.onclick = function () { if (!busy) { vol = v; openDir([]); } };
        box.appendChild(d);
      });
      return;
    }
    entries.sort(function (a, b) {
      if (a.d !== b.d) return a.d ? -1 : 1;
      return a.n.localeCompare(b.n);
    });
    var t = document.createElement('table');
    t.className = 'fm-list';
    t.appendChild(headRow());
    if (!entries.length) {
      var e = document.createElement('tr'), ec = document.createElement('td');
      ec.colSpan = 5;
      ec.textContent = 'Empty folder.';
      e.appendChild(ec); t.appendChild(e);
    }
    entries.forEach(function (en) {
      var tr = document.createElement('tr');
      tr.className = 'fm-row';
      var ic = document.createElement('td'); ic.className = 'fm-ico'; ic.innerHTML = en.d ? SVG_DIR : SVG_FILE;
      var nm = document.createElement('td'); nm.className = 'fm-name';
      var sz = document.createElement('td'); sz.className = 'fm-size';
      var md = document.createElement('td'); md.className = 'fm-mod'; md.textContent = en.m || '';
      var ac = document.createElement('td'); ac.className = 'fm-act';
      if (en.d) {
        var a = document.createElement('a'); a.textContent = en.n;
        a.onclick = function () { if (!busy) openDir(parts.concat([en.n])); };
        nm.appendChild(a);
      } else {
        nm.textContent = en.n;
        sz.textContent = fmtSize(en.s);
        var dl = document.createElement('a'); dl.textContent = 'Download';
        dl.onclick = function () { if (!busy) download(en); };
        var de = document.createElement('a'); de.textContent = 'Delete'; de.className = 'del';
        de.onclick = function () { if (!busy) del(en); };
        ac.appendChild(dl); ac.appendChild(de);
      }
      tr.appendChild(ic); tr.appendChild(nm); tr.appendChild(sz); tr.appendChild(md); tr.appendChild(ac);
      t.appendChild(tr);
    });
    box.appendChild(t);
  }

  async function loadVolumes() {
    var r = await fetch(BASE + 'volumes.json?t=' + Date.now(), { cache: 'no-store', credentials: 'same-origin' });
    if (!r.ok) throw new Error('Storage list is not published yet. Click Refresh.');
    var res = await r.json();
    volumes = res.volumes.sort(function (a, b) {
      if (a.kind !== b.kind) return a.kind === 'jffs' ? -1 : 1;
      return a.label.localeCompare(b.label);
    });
    vol = null; parts = [];
    crumbs(); render([]);
  }

  async function showVolumes(republish) {
    setBusy(true); status('Reading storage...');
    try {
      if (republish) {
        var res = await send('volumes', {});
        if (!res.ok) throw new Error(errText(res.error));
      }
      await loadVolumes();
      status('');
    } catch (e) { status(e.message, true); }
    setBusy(false);
  }

  async function openDir(newParts) {
    setBusy(true); status('Reading folder...');
    try {
      var res = await send('list', { vol: vol.id, path: pathHex(newParts) });
      if (!res.ok) {
        if (res.error === 'volume_unavailable') {
          setBusy(false);
          await showVolumes(true);
          status(errText(res.error), true);
          return;
        }
        throw new Error(errText(res.error));
      }
      parts = newParts;
      crumbs(); render(res.entries);
      status(res.truncated ? 'Showing the first entries only (list truncated).' : '');
    } catch (e) { status(e.message, true); }
    setBusy(false);
  }

  async function download(en) {
    setBusy(true); status('Preparing ' + en.n + '...');
    var prep = null;
    try {
      prep = await send('download', { vol: vol.id, path: pathHex(parts.concat([en.n])) });
      if (!prep.ok) { var code = prep.error; prep = null; throw new Error(errText(code)); }
      if (!/^dl-[0-9a-f]{32}\.json$/.test(prep.payload)) throw new Error('Unexpected response.');
      status('Downloading ' + en.n + '...');
      var r = await fetch(BASE + prep.payload + '?t=' + Date.now(), { cache: 'no-store', credentials: 'same-origin' });
      if (!r.ok) throw new Error('Download failed: HTTP ' + r.status);
      var data = await r.json();
      var bin = atob(data.base64), bytes = new Uint8Array(bin.length);
      for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
      bin = null;
      if (bytes.length !== data.size || data.size !== prep.size) throw new Error('Size mismatch, file changed during download.');
      data = null;
      var url = URL.createObjectURL(new Blob([bytes], { type: 'application/octet-stream' }));
      var a = document.createElement('a');
      a.href = url; a.download = en.n;
      document.body.appendChild(a); a.click(); a.remove();
      setTimeout(function () { URL.revokeObjectURL(url); }, 60000);
      status('Saved ' + en.n + ' (' + fmtSize(bytes.length) + ').');
    } catch (e) { status(e.message, true); }
    if (prep) {
      try { await send('cleanup', { dlid: prep.id, token: prep.token }); } catch (e2) { /* the router removes it after 5 minutes */ }
    }
    setBusy(false);
  }

  async function del(en) {
    var full = vol.path + '/' + parts.concat([en.n]).join('/');
    if (!confirm('Delete this file permanently?\n\n' + full)) return;
    setBusy(true); status('Deleting...');
    try {
      var res = await send('delete', { vol: vol.id, path: pathHex(parts.concat([en.n])) });
      if (!res.ok) throw new Error(errText(res.error));
      setBusy(false);
      await openDir(parts);
      status('Deleted ' + en.n + '.');
      return;
    } catch (e) { status(e.message, true); }
    setBusy(false);
  }

  function refresh() {
    if (busy) return;
    if (vol) openDir(parts); else showVolumes(true);
  }
  function init() { showVolumes(false); }
  return { init: init, refresh: refresh };
})();

function refreshMenuCache(done) {
  var finished = false;
  function fin() { if (!finished) { finished = true; done(); } }
  setTimeout(fin, 2500);
  try {
    require(['/require/modules/menuTree.js?fm_menu=' + Date.now()], function (menuTree) {
      try {
        Session.set('menuList.' + ui_lang, menuTree.list);
        Session.set('menuExclude', { menus: menuTree.exclude.menus(), tabs: menuTree.exclude.tabs() });
      } catch (e) { /* keep the existing cache */ }
      fin();
    }, fin);
  } catch (e) { fin(); }
}

function initial() {
  SetCurrentPage();
  refreshMenuCache(function () { show_menu(); });
  FM.init();
}
</script>
</head>

<body onload="initial();" class="bg">
<div id="TopBanner"></div>
<div id="Loading" class="popup_bg"></div>
<iframe name="hidden_frame" id="hidden_frame" src="" width="0" height="0" frameborder="0"></iframe>
<form method="post" name="form" action="start_apply.htm" onsubmit="return false;">
<input type="hidden" name="current_page" value="">
<input type="hidden" name="next_page" value="">
<input type="hidden" name="group_id" value="">
<input type="hidden" name="modified" value="0">
<input type="hidden" name="action_mode" value="apply">
<input type="hidden" name="action_wait" value="0">
<input type="hidden" name="first_time" value="">
<input type="hidden" name="action_script" value="restart_filemgr">
<input type="hidden" name="preferred_lang" id="preferred_lang" value="<% nvram_get("preferred_lang"); %>">
<input type="hidden" name="firmver" value="<% nvram_get("firmver"); %>">
<input type="hidden" name="amng_custom" id="amng_custom" value="">

<table class="content" align="center" cellpadding="0" cellspacing="0">
<tr>
<td width="17">&nbsp;</td>
<td valign="top" width="202">
<div id="mainMenu"></div>
<div id="subMenu"></div>
</td>
<td valign="top">
<div id="tabMenu" class="submenuBlock"></div>
<table width="98%" border="0" align="left" cellpadding="0" cellspacing="0">
<tr>
<td align="left" valign="top">
<table width="760px" border="0" cellpadding="5" cellspacing="0" bordercolor="#6b8fa3" class="FormTitle" id="FormTitle">
<tr>
<td bgcolor="#4D595D" colspan="3" valign="top">
<div>&nbsp;</div>
<div class="formfonttitle">File Manager</div>
<div style="margin:10px 0 10px 5px;" class="splitLine"></div>
<div class="fm-bar">
<div class="fm-crumbs" id="fm-crumbs"></div>
<div class="fm-btns"><input class="button_gen" type="button" value="Refresh" onclick="FM.refresh();"></div>
</div>
<div class="fm-status" id="fm-status"></div>
<div id="fm-content"></div>
</td>
</tr>
</table>
</td>
</tr>
</table>
</td>
<td width="10" align="center" valign="top"></td>
</tr>
</table>
</form>
<div id="footer"></div>
</body>
</html>
__FM_ASP_EOF__
}

install_files() {
    mkdir -p "$DIR"

    for f in lib.sh handler.sh mount.sh filemgr.asp; do
        backup_file "$DIR/$f"
        cp -pf "$PAYLOAD/$f" "$DIR/$f" || die "Cannot write $DIR/$f"
    done

    chmod 644 "$DIR/lib.sh" "$DIR/filemgr.asp"
    chmod 755 "$DIR/handler.sh" "$DIR/mount.sh"

    case "$0" in
        */install.sh|install.sh) ;;
        *) [ -f "$0" ] && cp -f "$0" "$DIR/install.sh" 2>/dev/null ;;
    esac
    [ -f "$DIR/install.sh" ] && chmod 755 "$DIR/install.sh"
    printf '%s\n' "$VERSION" > "$DIR/.managed-v2"

    grep -q 'FILEMGR_WEBUI_V2' "$DIR/filemgr.asp" || die "Payload ASP marker missing."
    grep -q 'class="button_gen"' "$DIR/filemgr.asp" || die "Payload ASP lacks native buttons."
    grep -q 'value="Refresh"' "$DIR/filemgr.asp" || die "Payload ASP lacks Refresh button."
    grep -q 'fm_menu=' "$DIR/filemgr.asp" || die "Payload ASP lacks menu cache-busting."
    grep -q "'Modified'" "$DIR/filemgr.asp" || die "Payload ASP lacks the Modified column."
    grep -q 'function init() { showVolumes(false); }' "$DIR/filemgr.asp" || die "Payload ASP init is not read-only."
    for f in lib.sh handler.sh mount.sh; do
        sh -n "$DIR/$f" || die "Syntax error in $f"
    done
}

install_hooks() {
    for f in services-start service-event service-event-end post-mount unmount; do
        backup_file "$SCRIPTS/$f"
    done

    append_block "$SCRIPTS/services-start" '(
    sleep 8
    /jffs/addons/filemgr/mount.sh >/tmp/filemgr-mount.log 2>&1
) &' || die "Unable to update services-start."

    append_block "$SCRIPTS/service-event" 'if [ "$2" = "filemgr" ]; then
    /jffs/addons/filemgr/handler.sh >/tmp/filemgr-handler.log 2>&1 &
fi' || die "Unable to update service-event."

    append_block "$SCRIPTS/service-event-end" 'case "$*" in
    *httpd*)
        (
            sleep 3
            /jffs/addons/filemgr/mount.sh >/tmp/filemgr-mount.log 2>&1
        ) &
        ;;
esac' || die "Unable to update service-event-end."

    append_block "$SCRIPTS/post-mount" '(
    /jffs/addons/filemgr/handler.sh publish >/tmp/filemgr-publish.log 2>&1
) &' || die "Unable to update post-mount."

    append_block "$SCRIPTS/unmount" '(
    /jffs/addons/filemgr/handler.sh publish "$1" >/tmp/filemgr-publish.log 2>&1
) &' || die "Unable to update unmount."
}

remove_runtime() {
    if [ -f "$TREE" ] && grep -q 'filemgr-webui' "$TREE"; then
        awk '!/filemgr-webui/' "$TREE" > "$TREE.filemgr.$$" && cat "$TREE.filemgr.$$" > "$TREE"
        rm -f "$TREE.filemgr.$$"
    fi

    for page in "$WWW_USER"/user*.asp; do
        [ -f "$page" ] || continue
        if grep -q 'FILEMGR_WEBUI_V[12]' "$page"; then
            rm -f "$page"
        fi
    done

    if [ -L "$WWW_USER/filemgr" ]; then
        rm -f "$WWW_USER/filemgr"
    fi

    rm -rf "$WEB" "$PRIV"
}

do_install() {
    require_root
    extract_payload
    install_files
    install_hooks

    for page in "$WWW_USER"/user*.asp; do
        [ -f "$page" ] || continue
        grep -q 'FILEMGR_WEBUI_V1' "$page" && rm -f "$page"
    done

    if [ -z "${FM_NOMOUNT:-}" ]; then
        "$DIR/mount.sh" || die "WebUI mount failed (see: logread | grep filemgr)."

        PAGE="$(cat "$DIR/page" 2>/dev/null)"
        case "$PAGE" in
            user[0-9].asp|user[0-9][0-9].asp) ;;
            *) die "Invalid WebUI page after mount: $PAGE" ;;
        esac
        [ -f "$WWW_USER/$PAGE" ] || die "Live page missing: $WWW_USER/$PAGE"
        grep -q 'FILEMGR_WEBUI_V2' "$WWW_USER/$PAGE" || die "Live page verification failed."
    fi

    echo
    log "File Manager $VERSION installed. Reload the WebUI (hard refresh), then open Administration -> File Manager."
}

do_uninstall() {
    require_root
    for f in services-start service-event service-event-end post-mount unmount; do
        backup_file "$SCRIPTS/$f"
        strip_block "$SCRIPTS/$f"
        if [ -f "$SCRIPTS/$f" ] && ! grep -qvE '^[[:space:]]*(#!.*)?$' "$SCRIPTS/$f"; then
            rm -f "$SCRIPTS/$f"
        fi
    done

    remove_runtime

    if [ -f "$SETTINGS" ]; then
        sed -i '/^_filemgr_/d' "$SETTINGS"
    fi

    rm -rf "$DIR"

    echo
    log "File Manager removed. Other add-ons were not touched."
}

do_status() {
    echo "=== File Manager status ==="
    if [ -f "$DIR/.managed-v2" ]; then
        echo "Installation: managed ($(cat "$DIR/.managed-v2"))"
    else
        echo "Installation: not installed"
    fi
    echo "WebUI page: $(cat "$DIR/page" 2>/dev/null || echo unavailable)"
    for f in services-start service-event service-event-end post-mount unmount; do
        if grep -qF "$BEGIN" "$SCRIPTS/$f" 2>/dev/null; then
            echo "OK: hook block in $f"
        else
            echo "MISSING: hook block in $f"
        fi
    done
    [ -L "$WWW_USER/filemgr" ] && echo "OK: resource link" || echo "MISSING: resource link"
    [ -f "$WEB/volumes.json" ] && echo "OK: volumes.json published" || echo "MISSING: volumes.json"
    grep -q 'filemgr-webui' "$TREE" 2>/dev/null && echo "OK: menu entry" || echo "MISSING: menu entry"
}

case "${1:-install}" in
    install) do_install ;;
    status) do_status ;;
    uninstall) do_uninstall ;;
    *)
        echo "Usage: $0 {install|status|uninstall}" >&2
        exit 1
        ;;
esac
