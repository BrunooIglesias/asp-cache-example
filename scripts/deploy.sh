#!/usr/bin/env bash
# set -e:        cortar el script si cualquier comando falla.
# set -u:        error si se usa una variable no definida (atrapa typos).
# set -o pipefail: en un pipe (cmd1 | cmd2), si cmd1 falla, falla todo. Sin esto solo importa cmd2.
set -euo pipefail

# Deploya esta app a Elastic Beanstalk armando un "source bundle" tipo Docker.
# Las credenciales se leen de ./aws/credentials. Como service role e instance profile
# se usan los que provee AWS Academy (LabRole / LabInstanceProfile) — el script NO crea IAM.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CREDS_FILE="$ROOT/aws/credentials"

if [ ! -s "$CREDS_FILE" ]; then
  echo "missing or empty credentials file: $CREDS_FILE" >&2
  exit 1
fi

# AWS_SHARED_CREDENTIALS_FILE le dice al AWS CLI que use ESTE archivo de credenciales en vez
# del default ~/.aws/credentials. Asi no pisamos la config global del sistema y cada proyecto
# puede tener sus propias creds.
export AWS_SHARED_CREDENTIALS_FILE="$CREDS_FILE"
export AWS_DEFAULT_REGION="us-east-1"
# AWS_PAGER="": el CLI por defecto pasa la salida por `less` en comandos largos. En un script
# eso lo dejaria colgado esperando que aprietes "q". Vacio = sin pager.
export AWS_PAGER=""

APP_NAME="asp-cache-example"
ENV_NAME="asp-cache-env"

# Necesitamos el ID de cuenta para nombrar el bucket de S3. Los nombres de bucket son GLOBALES
# (unicos en TODO AWS). Sufijar con el account id da unicidad sin pensarlo.
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET_NAME="asp-cache-eb-${ACCOUNT_ID}"
# EB requiere que cada "application version" tenga un label unico. Usar timestamp evita
# colisiones si deployan varias veces seguidas.
VERSION_LABEL="v-$(date +%Y%m%d-%H%M%S)"
ZIP_PATH="/tmp/${APP_NAME}-${VERSION_LABEL}.zip"

echo "==> account=$ACCOUNT_ID region=$AWS_DEFAULT_REGION version=$VERSION_LABEL"

echo "==> packaging source bundle"
cd "$ROOT"
rm -f "$ZIP_PATH"
# El zip que sube a EB tiene que contener el Dockerfile + lo que el COPY del Dockerfile
# necesita (index.js, package*.json, public/). Excluimos:
#  - aws/        → tiene secretos, NO debe ir al server.
#  - node_modules → los instala `npm install` adentro del container.
#  - .git/, scripts/, *.zip, docker-compose.yml → no aportan al runtime.
zip -rq "$ZIP_PATH" . \
  -x "aws/*" "node_modules/*" ".git/*" "scripts/*" "*.zip" "docker-compose.yml"

echo "==> ensuring S3 bucket"
# Patron idempotente: si head-bucket falla (el bucket no existe o no es nuestro), creamos.
# El `2>/dev/null` esconde el error de head-bucket cuando no existe.
aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null \
  || aws s3api create-bucket --bucket "$BUCKET_NAME" >/dev/null

echo "==> uploading bundle"
aws s3 cp "$ZIP_PATH" "s3://$BUCKET_NAME/$VERSION_LABEL.zip" >/dev/null

echo "==> creating application version"
# create-application-version registra un "label" en EB que apunta a un zip en S3. Esto NO
# deploya nada todavia; solo le dice a EB "tengo esta version disponible". El deploy real
# pasa cuando hacemos create-environment o update-environment apuntando a este label.
# --auto-create-application: si la "EB application" (el contenedor logico) no existe, la crea.
aws elasticbeanstalk create-application-version \
  --application-name "$APP_NAME" \
  --version-label "$VERSION_LABEL" \
  --source-bundle "S3Bucket=$BUCKET_NAME,S3Key=$VERSION_LABEL.zip" \
  --auto-create-application >/dev/null

# El "solution stack" es el AMI/plataforma que EB usa para el environment (sistema operativo,
# version, runtime). El nombre incluye la version exacta y cambia cada tanto, por eso lo
# buscamos dinamicamente en vez de hardcodear "Docker running on Amazon Linux 2023 v4.x.y".
SOLUTION_STACK="$(aws elasticbeanstalk list-available-solution-stacks \
  --query 'SolutionStacks[?contains(@,`running Docker`) && contains(@,`Amazon Linux 2023`)] | [0]' \
  --output text)"
echo "==> solution stack: $SOLUTION_STACK"

# describe-environments devuelve TAMBIEN los environments terminados (por hasta ~6 semanas
# despues de borrarlos). Sin el filtro Status!=Terminated pensariamos que el env existe
# cuando en realidad ya no esta y todo el flujo siguiente fallaria.
ENV_STATUS="$(aws elasticbeanstalk describe-environments \
  --application-name "$APP_NAME" \
  --environment-names "$ENV_NAME" \
  --query 'Environments[?Status!=`Terminated`] | [0].Status' \
  --output text 2>/dev/null || true)"

if [ -z "$ENV_STATUS" ] || [ "$ENV_STATUS" = "None" ]; then
  echo "==> creating environment $ENV_NAME"
  # Primera vez: crear el environment. Esto provisiona EC2, security groups, etc. Tarda 5-10 min.
  # Las options vienen de scripts/eb-options.json (single instance, t3.micro, LabRole, PORT=3000).
  aws elasticbeanstalk create-environment \
    --application-name "$APP_NAME" \
    --environment-name "$ENV_NAME" \
    --solution-stack-name "$SOLUTION_STACK" \
    --version-label "$VERSION_LABEL" \
    --option-settings "file://$ROOT/scripts/eb-options.json" >/dev/null
else
  echo "==> updating environment $ENV_NAME"
  # Ya existe: solo le decimos que cambie a la nueva version. EB hace deploy "in-place" rapido.
  aws elasticbeanstalk update-environment \
    --application-name "$APP_NAME" \
    --environment-name "$ENV_NAME" \
    --version-label "$VERSION_LABEL" >/dev/null
fi

# "wait environment-updated" sirve TANTO para create como para update — el nombre engaña.
# Bloquea hasta que el env vuelve a Status=Ready. Si algo se rompe, igual termina (con error)
# despues de un timeout largo (~20 min).
echo "==> waiting for environment to become Ready"
aws elasticbeanstalk wait environment-updated \
  --application-name "$APP_NAME" \
  --environment-names "$ENV_NAME"

URL="$(aws elasticbeanstalk describe-environments \
  --application-name "$APP_NAME" \
  --environment-names "$ENV_NAME" \
  --query 'Environments[0].CNAME' --output text)"

echo
echo "deployed: http://$URL"
echo "try: curl http://$URL/pokemon/pikachu"
