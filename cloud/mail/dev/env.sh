# Ports and secrets of the mail dev stack. Sourced by stack.sh and demo.sh.
#
# The JWT secret is the public, well-known Supabase local-development secret.
# It signs nothing outside this machine's loopback stack.
export PALM_PG_PORT=${PALM_PG_PORT:-55522}
export PALM_REST_PORT=${PALM_REST_PORT:-55521}
export PALM_AUTH_PORT=${PALM_AUTH_PORT:-55529}
export PALM_SMTP_PORT=${PALM_SMTP_PORT:-55525}
export PALM_SUBMIT_PORT=${PALM_SUBMIT_PORT:-55587}
export PALM_JMAP_PORT=${PALM_JMAP_PORT:-55580}
export PALM_MAIL_DOMAIN=${PALM_MAIL_DOMAIN:-palm.test}
export PALM_JWT_SECRET=${PALM_JWT_SECRET:-super-secret-jwt-token-with-at-least-32-characters-long}
