#!/bin/sh
umask 077

# Start fail2ban
[ "${XUI_ENABLE_FAIL2BAN}" = "true" ] && fail2ban-client -x start

# Container recreation resets Alpine's crontab, so reconstruct the acme.sh
# renewal entry from the persistent ACME volume on every start.
if [ -x "${X_MILI_ACME_HOME:-/root/.acme.sh}/acme.sh" ]; then
  mkdir -p /var/spool/cron/crontabs
  printf '%s\n' '17 3 * * * /usr/bin/ml ssl cron >/proc/1/fd/1 2>/proc/1/fd/2' \
    > /var/spool/cron/crontabs/root
  chmod 0600 /var/spool/cron/crontabs/root
  crond -b -l 8
fi

# Run x-ui
exec /app/x-ui
