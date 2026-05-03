#!/usr/bin/env bash
set -euo pipefail

# Crea (si no existe) un cluster ElastiCache (Redis) chico y conecta su endpoint al EB env
# como REDIS_HOST / REDIS_PORT. Hay que correr scripts/deploy.sh ANTES, porque necesitamos
# que el environment de EB ya este corriendo para detectar su VPC y security group.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export AWS_SHARED_CREDENTIALS_FILE="$ROOT/aws/credentials"
export AWS_DEFAULT_REGION="us-east-1"
export AWS_PAGER=""

APP_NAME="asp-cache-example"
ENV_NAME="asp-cache-env"
CLUSTER_ID="asp-cache-redis"
SUBNET_GROUP="asp-cache-subnets"
CACHE_SG_NAME="asp-cache-redis-sg"

# IMPORTANTE: ElastiCache vive DENTRO de una VPC y NO tiene endpoint publico. Solo se puede
# acceder desde recursos en la misma VPC (en este caso, la EC2 que levanta EB). Por eso
# necesitamos saber en que VPC esta el EB y cual es su security group, para crear el Redis
# en la misma VPC y autorizar al SG del EB a hablarle.
INSTANCE_ID="$(aws elasticbeanstalk describe-environment-resources \
  --environment-name "$ENV_NAME" \
  --query 'EnvironmentResources.Instances[0].Id' --output text)"
[ "$INSTANCE_ID" = "None" ] && { echo "EB env has no instance — run deploy.sh first" >&2; exit 1; }

VPC_ID="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].VpcId' --output text)"
EB_SG="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text)"
SUBNET_IDS="$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[].SubnetId' --output text)"

# Crear OR describir: intentamos crear el SG. Si ya existe, create-security-group falla
# (devuelve error y exit code != 0); el `||` activa el fallback que lo busca por nombre.
# Asi el script es idempotente sin tener que chequear antes "existe?" con un if.
# OJO: Redis por defecto NO tiene autenticacion. La unica proteccion es el security group.
# Si abrieran este SG a 0.0.0.0/0 cualquiera de internet podria leer / escribir el cache.
CACHE_SG="$(aws ec2 create-security-group \
  --group-name "$CACHE_SG_NAME" --vpc-id "$VPC_ID" \
  --description "redis access for asp-cache-example" \
  --query GroupId --output text 2>/dev/null \
  || aws ec2 describe-security-groups \
       --filters "Name=group-name,Values=$CACHE_SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
       --query 'SecurityGroups[0].GroupId' --output text)"

# Permitimos trafico al puerto 6379 (Redis) SOLO desde el SG del EB. Si la regla ya existe,
# el comando falla con InvalidPermission.Duplicate; el `|| true` lo ignora.
# --source-group: en vez de dar un rango de IPs, autorizamos un security group entero. Es la
# forma "correcta" en AWS — si EB cambia la IP de la EC2, sigue funcionando.
aws ec2 authorize-security-group-ingress --group-id "$CACHE_SG" \
  --protocol tcp --port 6379 --source-group "$EB_SG" 2>/dev/null || true

# ElastiCache requiere un "subnet group" que liste las subnets donde puede colocar nodos.
# Sin esto no se puede crear el cluster. Pasamos todas las subnets de la VPC del EB.
# Si ya existe, create-cache-subnet-group falla; el `|| true` lo ignora.
aws elasticache create-cache-subnet-group \
  --cache-subnet-group-name "$SUBNET_GROUP" \
  --cache-subnet-group-description "asp-cache subnets" \
  --subnet-ids $SUBNET_IDS >/dev/null 2>&1 || true

# Si el cluster ya existe, no lo recreamos (seria caro y tarda). Si no existe, lo creamos
# y esperamos a que este "available". La creacion tarda 5-10 minutos.
if ! aws elasticache describe-cache-clusters --cache-cluster-id "$CLUSTER_ID" >/dev/null 2>&1; then
  echo "==> creating redis cluster $CLUSTER_ID"
  aws elasticache create-cache-cluster \
    --cache-cluster-id "$CLUSTER_ID" \
    --engine redis --cache-node-type cache.t3.micro --num-cache-nodes 1 \
    --cache-subnet-group-name "$SUBNET_GROUP" \
    --security-group-ids "$CACHE_SG" >/dev/null
  aws elasticache wait cache-cluster-available --cache-cluster-id "$CLUSTER_ID"
fi

# El endpoint del nodo es el host al que se conecta la app. Hay que pasar --show-cache-node-info
# porque sin ese flag describe-cache-clusters no devuelve los datos del nodo (incluido el endpoint).
REDIS_HOST="$(aws elasticache describe-cache-clusters \
  --cache-cluster-id "$CLUSTER_ID" --show-cache-node-info \
  --query 'CacheClusters[0].CacheNodes[0].Endpoint.Address' --output text)"

echo "==> redis at $REDIS_HOST:6379 — wiring into EB env"
# Setear variables de entorno en el EB env: namespace aws:elasticbeanstalk:application:environment.
# Esto dispara un redeploy automatico del environment para que la app vea las nuevas vars.
# La app las lee en index.js (process.env.REDIS_HOST / REDIS_PORT).
aws elasticbeanstalk update-environment \
  --application-name "$APP_NAME" --environment-name "$ENV_NAME" \
  --option-settings \
    "Namespace=aws:elasticbeanstalk:application:environment,OptionName=REDIS_HOST,Value=$REDIS_HOST" \
    "Namespace=aws:elasticbeanstalk:application:environment,OptionName=REDIS_PORT,Value=6379" >/dev/null

# Espera a que termine el redeploy del env. Si no esperaramos, el script termina pero la app
# todavia estaria con la config vieja por un par de minutos.
aws elasticbeanstalk wait environment-updated \
  --application-name "$APP_NAME" --environment-names "$ENV_NAME"

echo "done."
