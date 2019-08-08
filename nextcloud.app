#!/ebrmain/bin/run_script -clear_screen -bitmap=sync_steps_icon

IFS=$'\n'

# Parse configuration
. /mnt/ext1/system/config/nextcloud.cfg

REMOTE_PATH="$REMOTE_PATH_SUFFIX$REMOTE_DIR_NAME"
ESCAPED_REMOTE_PATH=$(echo $REMOTE_PATH | sed "s/\//\\\\\//g")
REMOTE_DIR_URL="$REMOTE_HOST$REMOTE_PATH"

# Special characters e.g. umlauts, whitespaces... must be URL-encoded
# https://meyerweb.com/eric/tools/dencoder/

LOCAL_DIR="/mnt/ext1/NextCloud"
# /mnt/ext1 --> internal storage
# /mnt/ext2 --> SD-Card


read_cfg_file()
{
	#usage read_cfg_file config prefix
	while read X; do
		X1=`echo $X|cut -d = -f 1|sed -e "s/[^a-zA-Z0-9_]//g"`
		X2=`echo $X|cut -d = -f 2-`
		eval ${2}${X1}='$X2'
	done < $1 || false
}

network_up()
{
	/ebrmain/bin/netagent status > /tmp/netagent_status_wb
	read_cfg_file /tmp/netagent_status_wb NETAGENT_
	if [ "$NETAGENT_nagtpid" -gt 0 ]; then
		:
		#network enabled
	else
		/ebrmain/bin/dialog 5 "" @NeedInternet @Cancel @TurnOnWiFi
		if ! [ $? -eq 2 ]; then
			exit 1
		fi

		/ebrmain/bin/netagent net on
	fi
	/ebrmain/bin/netagent connect
}


# Connect to the net first if necessary.
ifconfig eth0 > /dev/null 2>&1
if [ $? -ne 0 ]; then
	touch /tmp/webdav-wifi
	network_up
fi

# Tests internet connection
echo -e "GET http://google.com HTTP/1.0\n\n" | nc google.com 80 > /dev/null 2>&1
if [ $? -ne 0 ]; then
	# Offline
	#/ebrmain/bin/dialog 5 "" "Connection error. Please check your internet connection." "Ok"
	/ebrmain/bin/dialog 5 "" "Verbindungsfehler. Bitte Internetverbindung überprüfen." "Ok"
	exit 1
fi

# Gets a list of all remote file d:response tags
REMOTE_FILES_TAGS=$(curl --silent --user "$USER":"$PASSWORD" "$REMOTE_DIR_URL" -X PROPFIND -H 'Depth:infinity' --data '<?xml version="1.0"?><a:propfind xmlns:a="DAV:"><a:prop><a:resourcetype /><a:getlastmodified /></a:prop></a:propfind>' | sed -n 's/<d:multistatus[^>]*>\(.*\)<\/d:multistatus>/\1/p' | sed 's/<\/d:response><d:response>/<\/d:response>\n<d:response>/g' | grep '<d:resourcetype/>')

# Get the list of local files
LOCAL_FILES_LIST=$(cd "$LOCAL_DIR"; find . -type f | sed 's/^\.\///')

# Checks for every file if the remote version is different to the local one
for TAG in $REMOTE_FILES_TAGS; do
	FILE=$(echo $TAG | sed -n "s/^.*<d:href>$ESCAPED_REMOTE_PATH\/\(.*\)<\/d:href>.*$/\1/p" | echo -ne "$(sed 's/+/ /g; s/%/\\x/g')")
	if [ -n "$FILE" ]; then
		if [ -z "$REMOTE_FILES_LIST" ]; then
			REMOTE_FILES_LIST=$FILE
		else
			REMOTE_FILES_LIST=$REMOTE_FILES_LIST$'\n'$FILE
		fi
		REMOTE_TIMESTAMP=$(echo $TAG | sed -n 's/^.*<d:getlastmodified>\(.*\)<\/d:getlastmodified>.*$/\1/p' | sed 's/ *[A-Z]*$//')
		LOCAL_TIMESTAMP=$(date -ur "$LOCAL_DIR/$FILE" +'%a, %d %b %Y %H:%M:%S')
		if [ "$REMOTE_TIMESTAMP" != "$LOCAL_TIMESTAMP" ]; then
			if [ -z "$UPDATED_FILES_LIST" ]; then
				UPDATED_FILES_LIST=$FILE
			else
				UPDATED_FILES_LIST=$UPDATED_FILES_LIST$'\n'$FILE
			fi
		fi
	fi
done

if [ -n "$UPDATED_FILES_LIST" ]; then
	#/ebrmain/bin/dialog 2 "" "$(echo "$UPDATED_FILES_LIST" | wc -l) file(s) have changed:"$'\n'"$(echo "$UPDATED_FILES_LIST" | sed -e "s/^/$(printf '\xe2\x80\xa2 ')/")"$'\n'"Update those?" @Yes @Cancel
	/ebrmain/bin/dialog 2 "" "$(echo "$UPDATED_FILES_LIST" | wc -l) Datei(en) wurden geändert:"$'\n'"$(echo "$UPDATED_FILES_LIST" | sed -e "s/^/$(printf '\xe2\x80\xa2 ')/")"$'\n'"Diese aktualisieren?" @Yes @Cancel
	if [ $? -eq 1 ]; then
		for FILE in $UPDATED_FILES_LIST; do
			RESPONSE=$(wget -O "$LOCAL_DIR/$FILE" --user="$USER" --password="$PASSWORD" --server-response "$REMOTE_DIR_URL/$FILE" 2>&1)
			ERROR=$?
			if [ $ERROR -eq 0 -o $ERROR -eq 8 ]; then
				HTTP_CODE=$(echo "$RESPONSE" | sed -n 's/^  HTTP\/1.1 \([1-5][0-9]\{2\}\) .*$/\1/p' | tail -n1)
				if [ $HTTP_CODE -eq 200 ]; then
					if [ -z "$UPDATED_FILES_LIST" ]; then
						UPDATED_FILES_LIST=$FILE
					else
						UPDATED_FILES_LIST=$UPDATED_FILES_LIST$'\n'$FILE
					fi
				else
					#/ebrmain/bin/dialog 4 "" "Failed to download $FILE (HTTP $HTTP_CODE)!" "Ok" @Cancel
					/ebrmain/bin/dialog 4 "" "Konnte $FILE nicht herunterladen (HTTP $HTTP_CODE)!" "Ok" @Cancel
					if [ $? -eq 2 ]; then
						break
					fi
				fi
			else
				#/ebrmain/bin/dialog 4 "" "Failed to download $FILE (Wget error $ERROR)!" "Ok" @Cancel
				/ebrmain/bin/dialog 4 "" "Konnte $FILE nicht herunterladen (Wget Fehler $ERROR)!" "Ok" @Cancel
				if [ $? -eq 2 ]; then
					break
				fi
			fi
		done
	fi
else
	#/ebrmain/bin/dialog 1 "" "No updated files found." "Ok"
	/ebrmain/bin/dialog 1 "" "Keine aktualisierten Dateien gefunden." "Ok"
fi

# Delete local files that are not on the server if requested
if [ -n "$REMOTE_FILES_LIST" ]; then
	LOCAL_ONLY_FILES_LIST=$(echo "$LOCAL_FILES_LIST" | eval grep -vxF $(for FILE in $REMOTE_FILES_LIST; do echo -n " -e '$FILE'"; done))
else
	LOCAL_ONLY_FILES_LIST="$LOCAL_FILES_LIST"
fi

if [ -n "$LOCAL_ONLY_FILES_LIST" ]; then
	#/ebrmain/bin/dialog 2 "" "Found $(echo "$LOCAL_ONLY_FILES_LIST" | wc -l) file(s) that are not on the server anymore:"$'\n'"$(echo "$LOCAL_ONLY_FILES_LIST" | sed -e "s/^/$(printf '\xe2\x80\xa2 ')/")"$'\n'"Delete them?" @Yes @Cancel
	/ebrmain/bin/dialog 2 "" "$(echo "$LOCAL_ONLY_FILES_LIST" | wc -l) Datei(en) gefunden die nicht mehr auf dem Server sind:"$'\n'"$(echo "$LOCAL_ONLY_FILES_LIST" | sed -e "s/^/$(printf '\xe2\x80\xa2 ')/")"$'\n'"Diese löschen?" @Yes @Cancel
	if [ $? -eq 1 ]; then
		for FILE in $LOCAL_ONLY_FILES_LIST; do
			rm "$LOCAL_DIR/$FILE"
		done
	fi
fi

# Turns wifi off, if it was enabled by this script
if [ -f /tmp/webdav-wifi ]; then *
  rm -f /tmp/webdav-wifi
  /ebrmain/bin/netagent net off
fi

exit 0
