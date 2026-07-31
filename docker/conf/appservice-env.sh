# App Service injects app settings into PID 1, but sshd builds a fresh environment for every
# session, so WP-CLI over SSH would see no DATABASE_* and fail to connect to the database.
if [ -n "$BASH_VERSION" ] && [ -r /proc/1/environ ]; then
	while IFS= read -r -d '' var; do
		case "$var" in
			DATABASE_*|WP_*|PHP_INI_SCAN_DIR=*) export "$var" ;;
		esac
	done < /proc/1/environ
fi
