set -e

DATABASES=("greenhouse_inventory" "greenhouse_telemetry")

for DB in "${DATABASES[@]}"; do
  echo "Creating database: $DB"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    SELECT 'CREATE DATABASE $DB'
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$DB')\gexec
EOSQL
done

echo "All databases created successfully."
