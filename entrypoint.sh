#!/bin/zsh
#
# Unsure why but newrelic did not like the placeholders
#
export NEW_RELIC_HOST_DISPLAY_NAME=$(hostname -f)
export NEW_RELIC_PROCESS_HOST_DISPLAY_NAME=$(hostname -f)
cat >  /etc/newrelic-infra.yml << EOI
license_key: ${NEW_RELIC_LICENSE_KEY}
kernel_modules_refresh_sec: -1
systemd_refresh_sec: -1
dbus_refresh_sec: -1
logs:
  enabled: false
EOI

newrelic-admin generate-config ${NEW_RELIC_LICENSE_KEY} /etc/newrelic.ini
sed -i "s%app_name.*%app_name = ${NEW_RELIC_APM_NAME}%g" /etc/newrelic.ini
mkdir -p ${PROMETHEUS_MULTIPROC_DIR}
mkdir -p /tmp/logs


if [[ -n "${GH_SSH_KEY}" ]]; then
  [ ! -d "/root/.ssh/" ] && mkdir -p /root/.ssh
  ln -sf /etc/ssh_config /root/.ssh/config || true
  base64 -d <<< "${GH_SSH_KEY}" > /root/.ssh/ed25519_key
  chmod 600 /root/.ssh/ed25519_key
fi

/usr/bin/supervisord -c /etc/supervisord.conf