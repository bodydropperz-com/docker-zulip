#!/bin/bash

if [ "$DEBUG" == "true" ]; then
  set -x
fi
set -e

ZULIP_CURRENT_DEPLOY="$ZULIP_DIR/deployments/current"
MANAGE_PY="$ZULIP_CURRENT_DEPLOY/manage.py"
ZULIP_SETTINGS="/etc/zulip/settings.py"

# Some functions were originally taken from the zulip/zulip repo folder scripts
# I modified them to fit the "docker way" of installation ;)
function database-settings-setup(){
  # TODO See ZULIP/zproject/settings.py Line: ~284
#  cat << > /EOFDATABASES = {"default": {
#    'ENGINE': 'django.db.backends.postgresql_psycopg2',
#    'NAME': 'zulip',
#    'USER': 'zulip',
#    'PASSWORD': '', # Authentication done via certificates
#    'HOST': '',  # Host = '' => connect through a local socket
#    'SCHEMA': 'zulip',
#    'CONN_MAX_AGE': 600,
#    'OPTIONS': {
#        'connection_factory': TimeTrackingConnection
#        },
#    },
#  }
}
function database-setup(){
  if [ -z "$PGPASSWORD" ]; then
    export PGPASSWORD="$DB_PASSWORD"
  fi
  psql -h "$DB_HOST" -p "$DB_PORT" -u "$DB_USER" "CREATE USER zulip;
    ALTER ROLE zulip SET search_path TO zulip,public;
    DROP DATABASE IF EXISTS zulip;
    CREATE DATABASE zulip OWNER=zulip;"
  psql -h "$DB_HOST" -p "$DB_PORT" -u "$DB_USER" zulip "CREATE SCHEMA zulip AUTHORIZATION zulip;
    CREATE EXTENSION tsearch_extras SCHEMA zulip;" || :
}
function database-initiation(){
  cd "$ZULIP_CURRENT_DEPLOY"
  su zulip -c "$MANAGE_PY checkconfig"
  su zulip -c "$MANAGE_PY migrate --noinput"
  su zulip -c "$MANAGE_PY createcachetable third_party_api_results"
  su zulip -c "$MANAGE_PY initialize_voyager_db"
}
function zulip-add-custom-secrets(){
  ZULIP_SECRETS="/etc/zulip/zulip-secrets.conf"
  POSSIBLE_SECRETS=(
    "s3_key" "s3_secret_key" "android_gcm_api_key" "google_oauth2_client_secret"
    "dropbox_app_key" "mailchimp_api_key" "mandrill_api_key" "twitter_consumer_key" "twitter_consumer_secret"
    "twitter_access_token_key" "twitter_access_token_secret" "email_password"
  )
  for SECRET_KEY in "${POSSIBLE_SECRETS[@]}"; do
    KEY="ZULIP_SECRETS_$SECRET_KEY"
    SECRET_VAR="${!KEY}"
    if [ -z "$SECRET_VAR" ]; then
      echo "No settings env var found for key \"$SECRET_KEY\". Continuing."
      continue
    fi
    echo "Setting secret \"$SECRET_KEY\"."
    echo "$SECRET_KEY = '$SECRET_VAR'" >> "$ZULIP_SECRETS"
  done
}
function zulip-setup-external-services(){
  # Also see ZULIP/zproject/local_settings.py for "example"
  # TODO MEMCACHE See ZULIP/zproject/settings.py Line: ~328+
  # ...'LOCATION': '127.0.0.1:11211',...
  # TODO RABBITMQ See ZULIP/zproject/settings.py Line: ~318
  # RABBITMQ_USERNAME = 'zulip'
  # RABBITMQ_PASSWORD = get_secret("rabbitmq_password")
  # TODO REDIS See ZULIP/zproject/settings.py Line: ~352
  # REDIS_HOST = '127.0.0.1'
  # REDIS_PORT = 6379
  # TODO CAMO Search the file ^
}
function zulip-setup-zulip-settings(){
  if [ "$ZULIP_USE_EXTERNAL_SETTINGS" == "true" ] && [ -f "$DATA_DIR/settings.py" ]; then
    rm -f "$ZULIP_SETTINGS"
    cp -rf "$DATA_DIR/settings.py" "$ZULIP_SETTINGS"
    chown zulip:zulip "$ZULIP_SETTINGS"
    return 0
  fi
  # ^#?([a-zA-Z0-9_]*)[ ]*=[ ]*([\"'].*[\"']+|[\(\{]+(\n[^)]*)+.*[\)\}])$ and ^#?[ ]?([a-zA-Z0-9_]*)
  POSSIBLE_SETTINGS=($(grep -E "^#?([a-zA-Z0-9_]*)[ ]*=[ ]*([\"'].*[\"']+|[\(\{]+(\n[^)]*)+.*[\)\}])$" "$ZULIP_SETTINGS" | grep -oE "^#?[ ]?([a-zA-Z0-9_]*)") "S3_AUTH_UPLOADS_BUCKET" "S3_AVATAR_BUCKET")
  for SETTING_KEY in "${POSSIBLE_SETTINGS[@]}"; do
    KEY="ZULIP_SETTINGS_$SETTING_KEY"
    SETTING_VAR="${!KEY}"
    if [ -z "$SETTING_VAR" ]; then
      echo "No settings env var found for key \"$SETTING_KEY\". Continuing."
      continue
    fi
    echo "Setting key \"$SETTING_KEY\" to value \"$SETTING_VAR\"."
    sed -i "s~#?${SETTING_KEY}[ ]*=[ ]*['\"]+.*['\"]+$~${SETTING_KEY} = '${SETTING_VAR}'~g" "$ZULIP_SETTINGS"
  done
  if [ ! -z "$ZULIP_SAVE_SETTINGS_PY" ]; then
    rm -f "$DATA_DIR/settings.py"
    cp -f "$ZULIP_SETTINGS" "$DATA_DIR/settings.py"
  fi
}
function zulip-create-user(){
  if [ -z "$ZULIP_USER_EMAIL" ]; then
    echo "No zulip user email given."
    return 1
  fi
    if [ -z "$ZULIP_USER_PASSWORD" ]; then
      echo "No zulip user password given."
      return 1
    fi
  if [ -z "$ZULIP_USER_FULLNAME" ]; then
    echo "No zulip user full name given. Defaulting to \"Zulip Docker\""
    ZULIP_USER_FULLNAME="Zulip Docker"
  fi
  su zulip -c " $MANAGE_PY create_user --new-email \"$ZULIP_USER_EMAIL\" --new-password \"$ZULIP_USER_PASSWORD\" --new-full-name \"$ZULIP_USER_FULLNAME\""
  su zulip -c "$MANAGE_PY knight \"$ZULIP_USER_EMAIL\" -f"
}
function rabbitmq-setup(){
  # TODO do something about the RABBIT_HOST var
  rabbitmqctl -n "$RABBIT_HOST" delete_user zulip || :
  rabbitmqctl -n "$RABBIT_HOST" delete_user guest || :
  rabbitmqctl -n "$RABBIT_HOST" add_user zulip "$("$ZULIP_CURRENT_DEPLOY/bin/get-django-setting" RABBITMQ_PASSWORD)" || :
  rabbitmqctl -n "$RABBIT_HOST" set_user_tags zulip administrator
  rabbitmqctl -n "$RABBIT_HOST" set_permissions -p / zulip '.*' '.*' '.*'
}

if [ -d "$DATA_DIR/uploads" ]; then
  rm -rf "$ZULIP_DIR/uploads"
else
  mkdir -p "$DATA_DIR/uploads"
  mv -f "$ZULIP_DIR/uploads" "$DATA_DIR/uploads"
fi
ln -sfT "$DATA_DIR/uploads" "$ZULIP_DIR/uploads"
if [ ! -f "$DATA_DIR/.initiated" ]; then
  echo "Initiating Zulip initiation ..."
  echo "==="
  echo "Generating and setting secrets ..."
  # Generate the secrets
  /root/zulip/scripts/setup/generate_secrets.py
  zulip-add-custom-secrets
  echo "Secrets generated and set."
  echo "Setting up database settings and server ..."
  # Set database settings
  database-settings-setup
  # Init Postgres database server
  database-setup
  echo "Database settings and server setup done."
  echo "Setting Zulip settings ..."
  # Setup zulip settings
  zulip-setup-zulip-settings
  echo "Zulip settings setup done."
  echo "Initiating  Database ..."
  # Init database with something called data :D
  if ! database-initiation; then
    echo "Database initiation failed."
    exit 1
  fi
  touch "$DATA_DIR/.initiated"
  echo "Database initiated."
  echo "Creating zulip user account ..."
  zulip-create-user
  echo "Created zulip user account"
  echo "==="
  echo "Zulip initiation done."
fi
# Configure rabbitmq server everytime because it could be a new one ;)
rabbitmq-setup
# If there's an "update" available, then JUST DO IT!
if [ ! -f "$DATA_DIR/.zulip-$ZULIP_VERSION" ]; then
  echo "Starting zulip migration ..."
  if ! "$MANAGE_PY" migrate; then
    echo "Zulip migration error."
    exit 1
  fi
  touch "$DATA_DIR/.zulip-$ZULIP_VERSION"
  echo "Zulip migration done."
fi
echo "Starting zulip using supervisor ..."
# Start supervisord
exec supervisord
