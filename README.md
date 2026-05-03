# ASP - Demo de Redis + Elastic Beanstalk

Proyecto de ejemplo para la materia **ASP**. La idea es mostrarles a los alumnos cómo usar **Redis (ElastiCache)** como cache de respuestas de una API pública, y cómo desplegar una app Node.js a **Elastic Beanstalk**, todo desde la consola/terminal usando AWS CLI (sin tocar la consola web de AWS).

La app es simple: una página web que pide un pokémon a la [PokeAPI](https://pokeapi.co/) y guarda la respuesta en Redis. La primera llamada tarda 100-300ms (va a la API pública). Las siguientes salen del cache en pocos milisegundos. La diferencia se ve en pantalla con un badge `API` o `CACHE` y la latencia en ms.

## Requisitos

- **Docker** y **Docker Compose** (para correrlo local).
- **AWS CLI v2** instalado y en el PATH (`aws --version`).
- **Cuenta de AWS Academy** con el Learner Lab iniciado. Los scripts asumen que existe `LabRole` y `LabInstanceProfile` (los provee Academy automáticamente).
- `bash` y `zip` (vienen por defecto en macOS y Linux).

## Estructura

- `index.js` — servidor Express con `/pokemon/:name` que cachea en Redis.
- `public/index.html` — frontend de demo (input + badges + historial).
- `Dockerfile`, `docker-compose.yml` — para correrlo local.
- `scripts/deploy.sh` — empaqueta y deploya a Elastic Beanstalk.
- `scripts/setup-redis.sh` — crea ElastiCache y la conecta al EB env.
- `scripts/eb-options.json` — config del EB env (single instance, t3.micro, LabRole).
- `aws/credentials` — acá van las creds del lab (gitignoreado).

## Correrlo local

```bash
docker compose up --build
```

Abrir `http://localhost:3000` y buscar un pokémon (ej: `pikachu`, `25`, `charizard`):

- Primera búsqueda → badge **API**, latencia alta.
- Click en el chip "buscados antes" → badge **CACHE**, latencia mucho menor.

Para parar: `Ctrl+C` y opcionalmente `docker compose down`.

## Deploy a AWS

> El Learner Lab tiene que estar iniciado (botón **Start Lab** en verde) antes de correr cualquiera de estos scripts.

### Paso 1 — Pegar las credenciales del lab

En AWS Academy, dentro del Learner Lab, click en **AWS Details** → en la sección **AWS CLI** click en **Show**. Vas a ver un bloque parecido a:

```ini
[default]
aws_access_key_id=ASIA...
aws_secret_access_key=...
aws_session_token=...
```

Copialo entero y pegalo en el archivo `aws/credentials` de este proyecto (queda en la raíz).

**Importante:** estas credenciales se vencen cuando termina la sesión del lab (~4 hs). Si un script falla con `ExpiredToken` o `InvalidClientTokenId`, copiá las credenciales nuevas y reintentá.

### Paso 2 — Deployar la app a Elastic Beanstalk

```bash
./scripts/deploy.sh
```

Lo que hace:

1. Empaqueta el código (Dockerfile + index.js + public/) en un zip.
2. Lo sube a un bucket de S3.
3. Crea (si no existe) la aplicación de EB y un environment `asp-cache-env` en `us-east-1`, single instance, `t3.micro`.
4. Espera hasta que el environment esté **Ready**.
5. Imprime la URL pública.

La primera vez tarda 5-10 minutos (creación del environment). Las siguientes son más rápidas porque solo actualiza la versión.

Probá la URL en el browser o con `curl http://<url>/pokemon/pikachu`. Vas a ver siempre `"source": "api"` — todavía no hay Redis conectado.

### Paso 3 — Crear ElastiCache y conectarlo al EB env

```bash
./scripts/setup-redis.sh
```

Lo que hace:

1. Detecta el VPC y el security group del environment de EB.
2. Crea (si no existe) un security group para Redis que permite tráfico en el puerto 6379 desde el SG del EB.
3. Crea (si no existe) un cluster de Redis `cache.t3.micro` en el mismo VPC.
4. Setea las variables `REDIS_HOST` y `REDIS_PORT` en el environment de EB.
5. Espera a que el env termine de actualizarse.

Tarda varios minutos (sobre todo la creación del cluster).

### Paso 4 — Verificar

Abrí la URL del Paso 2 en el browser y buscá el mismo pokémon dos veces:

- 1ra búsqueda → badge **API**, latencia alta.
- 2da búsqueda (click en el chip) → badge **CACHE**, latencia mucho menor.

## Limpieza

Antes de cerrar la clase conviene borrar los recursos creados:

```bash
export AWS_SHARED_CREDENTIALS_FILE=$(pwd)/aws/credentials
export AWS_DEFAULT_REGION=us-east-1

aws elasticbeanstalk terminate-environment --environment-name asp-cache-env
aws elasticache delete-cache-cluster --cache-cluster-id asp-cache-redis
```

## Notas

- Región hardcodeada: `us-east-1` (es la default del Learner Lab).
- Roles: `LabRole` y `LabInstanceProfile`. En una cuenta de AWS normal habría que crear roles propios.
- TTL del cache: 60 segundos (constante `CACHE_TTL_SECONDS` en `index.js`). Pasado ese tiempo la siguiente búsqueda vuelve a pegar a la PokeAPI.
