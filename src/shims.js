// src/shims.js - Node.js compatibility for Cloudflare Workers
export const process = {
  env: {},
  versions: {},
  nextTick: (cb) => setTimeout(cb, 0),
};

export const Buffer = {
  from: (data) => data,
  isBuffer: () => false,
};

export const global = globalThis;
