// build.js - Custom build script
import { build } from 'esbuild';
import { fileURLToPath } from 'url';
import { dirname, resolve } from 'path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

await build({
  entryPoints: [resolve(__dirname, 'src/index.js')],
  bundle: true,
  outfile: resolve(__dirname, 'dist/index.js'),
  format: 'esm',
  platform: 'browser',
  target: 'es2020',
  external: ['php-wasm', '@php-wasm/node', '@php-wasm/web'],
  loader: {
    '.js': 'jsx',
  },
  define: {
    'process.env.NODE_ENV': '"production"',
  },
  inject: [resolve(__dirname, 'src/shims.js')],
});
