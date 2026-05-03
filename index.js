const path = require('path');
const express = require('express');
const axios = require('axios');
const Redis = require('ioredis');

const app = express();
const port = Number(process.env.PORT) || 3000;

const redis = new Redis({
  host: process.env.REDIS_HOST || 'localhost',
  port: Number(process.env.REDIS_PORT) || 6379,
  // lazyConnect: no abre la conexion al instanciar, sino al primer comando. Sin esto, si Redis
  // no esta disponible al arrancar la app, el proceso se cae antes de poder responder cualquier
  // request HTTP. Con lazyConnect el server arranca igual y degrada (responde sin cache).
  lazyConnect: true,
  // Por defecto ioredis reintenta cada comando ~20 veces. Si Redis se cae, cada request HTTP
  // queda colgado varios segundos. Con 1 reintento falla rapido y caemos al fallback (API).
  maxRetriesPerRequest: 1,
});

// Sin este handler, ioredis emite 'error' y como nadie lo escucha Node tira "unhandled error".
redis.on('error', (err) => console.error('redis error:', err.message));

const API_URL = 'https://pokeapi.co/api/v2/pokemon';
// TTL del cache. Pasado este tiempo Redis borra la key sola y la siguiente request vuelve a
// pegarle a la API. Es la estrategia "cache-aside con expiracion": no hay invalidacion explicita.
const CACHE_TTL_SECONDS = 60;
const RECENT_LIMIT = 20;

// Lista en memoria del proceso.
const recent = [];

function trackRecent(name) {
  const idx = recent.indexOf(name);
  if (idx >= 0) recent.splice(idx, 1); // si ya estaba, lo sacamos para reinsertar al principio
  recent.unshift(name);
  if (recent.length > RECENT_LIMIT) recent.pop();
}

app.use(express.static(path.join(__dirname, 'public')));

app.get('/recent', (_req, res) => {
  res.json({ names: recent });
});

app.get('/pokemon/:name', async (req, res) => {
  // Normalizamos el nombre: la PokeAPI no distingue mayusculas pero la cache key si.
  // Sin esto "Pikachu" y "pikachu" generarian dos entradas distintas.
  const name = req.params.name.toLowerCase();
  const cacheKey = `pokemon:${name}`;
  const start = Date.now();

  // Patron "cache-aside": primero pregunto al cache, si hay devuelvo, si no voy al origen.
  // El try/catch envuelve el GET para que si Redis esta caido, la app igual sirva (degradada).
  let cached = null;
  try {
    cached = await redis.get(cacheKey);
  } catch (err) {
    console.error('cache get failed:', err.message);
  }

  if (cached) {
    const data = JSON.parse(cached);
    trackRecent(data.name);
    return res.json({
      source: 'cache',
      elapsedMs: Date.now() - start,
      data,
    });
  }

  try {
    const response = await axios.get(`${API_URL}/${name}`);
    const data = {
      id: response.data.id,
      name: response.data.name,
      height: response.data.height,
      weight: response.data.weight,
      types: response.data.types.map((t) => t.type.name),
      sprite: response.data.sprites?.front_default || null,
    };

    // El 'EX' es el flag de SET para indicar TTL en segundos. Equivalente a SETEX.
    // Si Redis falla en este SET no es critico: la respuesta de igual va, solo que la
    // proxima request va a tener que ir de nuevo a la API.
    try {
      await redis.set(cacheKey, JSON.stringify(data), 'EX', CACHE_TTL_SECONDS);
    } catch (err) {
      console.error('cache set failed:', err.message);
    }

    trackRecent(data.name);
    res.json({
      source: 'api',
      elapsedMs: Date.now() - start,
      data,
    });
  } catch (err) {
    res.status(502).json({ error: err.message });
  }
});

app.listen(port, () => {
  console.log(`server listening on port ${port}`);
});
