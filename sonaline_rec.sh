#!/bin/sh
# Sonaline recording upload for FreePBX. Contains no secrets.
# FreePBX "Post Call Recording Script":
#   curl -fsm9 <raw url of this file>|sh -s <token> ^{CALLFILENAME} x^{CDR(dstchannel)}
# Only calls on the extensions below are sent.

EXTS="105 1005 1006"
URL=https://voice.sonaline.com/voice/pbx/crm/Shmily_Werzberger
MON=${MON:-/var/spool/asterisk/monitor}
LOG=/tmp/sonaline.log

TOKEN=$1
NAME=$2              # external-105-8455551234-20261105-231700-1762402620.123
DST=${3#x}           # channel that answered, e.g. PJSIP/105-0000002a
ID=${NAME##*-}       # Asterisk uniqueid, used as the Sonaline call_id
TYPE=$(echo "$NAME" | cut -d- -f1)
TO=$(echo "$NAME" | cut -d- -f2)
FROM=$(echo "$NAME" | cut -d- -f3)

# Which listed extension is on this call: the one that answered first,
# then the one named in the file name
EXT=
for e in $EXTS; do case "$DST" in */"$e"-*) EXT=$e ;; esac; done
[ -n "$EXT" ] || for e in $EXTS; do [ "$TO" = "$e" ] || [ "$FROM" = "$e" ] && EXT=$e; done
[ -n "$EXT" ] || exit 0

FILE=$(find "$MON" -name "$NAME.*" -mmin -720 2>/dev/null | head -n 1)
[ -s "$FILE" ] || { echo "no file for $NAME" >>"$LOG"; exit 0; }
BASE=${FILE##*/}
FMT=${BASE##*.}

if [ "$TYPE" = out ] || [ "$FROM" = "$EXT" ]; then
  DIR=outbound
else
  DIR=inbound
fi
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

ev() {
  printf '{"event":"%s","call_id":"%s","sequence":%s,"direction":"%s","caller_number":"%s","dialed_number":"%s","extension":"%s","device":"PJSIP/%s","timestamp":"%s","recording":"%s"}' \
    "$1" "$ID" "$(date +%s%6N)" "$DIR" "$FROM" "$TO" "$EXT" "$EXT" "$TS" "$BASE" |
  curl -sS -m 5 -X POST "$URL/call" -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" --data-binary @- >>"$LOG" 2>&1
  echo >>"$LOG"
}

echo "$TS $ID $BASE ext $EXT" >>"$LOG"
ev answered
ev hangup
case "$FMT" in mp3) T=audio/mpeg ;; *) T=audio/wav ;; esac
curl -sS -m 30 -X POST "$URL/recording" -H "Authorization: Bearer $TOKEN" \
  -H "X-Call-ID: $ID" -F "file=@$FILE;type=$T" >>"$LOG" 2>&1
echo >>"$LOG"
