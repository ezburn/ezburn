// To run this, you must first build the Deno package with "make platform-deno"
import * as ezburnNative from '../deno/mod.js';
import * as ezburnWASM from '../deno/wasm.js';
import * as path from 'https://deno.land/std@0.95.0/path/mod.ts';
import * as asserts from 'https://deno.land/std@0.95.0/testing/asserts.ts';

const __dirname = path.dirname(path.fromFileUrl(import.meta.url));
const rootTestDir = path.join(__dirname, '.deno-tests');
const wasmModule = await WebAssembly.compile(
  await Deno.readFile(path.join(__dirname, '..', 'deno', 'ezburn.wasm'))
);

try {
  Deno.removeSync(rootTestDir, { recursive: true });
} catch {
  // Ignore if directory doesn't exist
}
Deno.mkdirSync(rootTestDir, { recursive: true });

function test(name, backends, fn) {
  for (const backend of backends) {
    switch (backend) {
      case 'native':
        Deno.test(`${name}-native`, async () => {
          const testDir = path.join(rootTestDir, `${name}-native`);
          await Deno.mkdir(testDir, { recursive: true });
          try {
            await fn({ ezburn: ezburnNative, testDir });
            await Deno.remove(testDir, { recursive: true }).catch(() => null);
          } finally {
            await ezburnNative.stop();
          }
        });
        break;

      case 'wasm-main':
        Deno.test(`${name}-wasm-main`, async () => {
          const testDir = path.join(rootTestDir, `${name}-wasm-main`);
          await ezburnWASM.initialize({ wasmModule, worker: false });
          await Deno.mkdir(testDir, { recursive: true });
          try {
            await fn({ ezburn: ezburnWASM, testDir });
            await Deno.remove(testDir, { recursive: true }).catch(() => null);
          } finally {
            await ezburnWASM.stop();
          }
        });
        break;

      case 'wasm-worker':
        Deno.test(`${name}-wasm-worker`, async () => {
          const testDir = path.join(rootTestDir, `${name}-wasm-worker`);
          await ezburnWASM.initialize({ wasmModule, worker: true });
          await Deno.mkdir(testDir, { recursive: true });
          try {
            await fn({ ezburn: ezburnWASM, testDir });
            await Deno.remove(testDir, { recursive: true }).catch(() => null);
          } finally {
            await ezburnWASM.stop();
          }
        });
        break;
    }
  }
}

// Use globalThis for Deno unload event (cross-platform)
globalThis.addEventListener("unload", () => {
  try {
    Deno.removeSync(rootTestDir, { recursive: true });
  } catch {
    // Directory may already be removed, ignore error
  }
});

// This test doesn't run in WebAssembly because it requires file system access
test("basicBuild", ['native'], async ({ ezburn, testDir }) => {
  const input = path.join(testDir, 'in.ts');
  const dep = path.join(testDir, 'dep.ts');
  const output = path.join(testDir, 'out.ts');
  await Deno.writeTextFile(input, 'import dep from "./dep.ts"; export default dep === 123');
  await Deno.writeTextFile(dep, 'export default 123');
  await ezburn.build({
    entryPoints: [input],
    bundle: true,
    outfile: output,
    format: 'esm',
  });
  const result = await import(path.toFileUrl(output));
  asserts.assertStrictEquals(result.default, true);
});

test("basicContext", ['native'], async ({ ezburn, testDir }) => {
  const input = path.join(testDir, 'in.ts');
  const dep = path.join(testDir, 'dep.ts');
  const output = path.join(testDir, 'out.ts');
  await Deno.writeTextFile(input, 'import dep from "./dep.ts"; export default dep === 123');
  await Deno.writeTextFile(dep, 'export default 123');
  const ctx = await ezburn.context({
    entryPoints: ['in.ts'],
    bundle: true,
    outfile: output,
    format: 'esm',
    absWorkingDir: testDir,
  });
  const { errors, warnings } = await ctx.rebuild();
  asserts.assertStrictEquals(errors.length, 0);
  asserts.assertStrictEquals(warnings.length, 0);
  await ctx.dispose();
  const result = await import(path.toFileUrl(output));
  asserts.assertStrictEquals(result.default, true);
});

test("basicPlugin", ['native', 'wasm-main', 'wasm-worker'], async ({ ezburn }) => {
  const build = await ezburn.build({
    entryPoints: ['<entry>'],
    bundle: true,
    format: 'esm',
    write: false,
    plugins: [{
      name: 'plug',
      setup(build) {
        build.onResolve({ filter: /^<.*>$/ }, args => ({ path: args.path, namespace: '<>' }));
        build.onLoad({ filter: /^<entry>$/ }, () => ({ contents: `import dep from "<dep>"; export default dep === 123` }));
        build.onLoad({ filter: /^<dep>$/ }, () => ({ contents: `export default 123` }));
      },
    }],
  });
  const result = await import('data:application/javascript;base64,' + btoa(build.outputFiles[0].text));
  asserts.assertStrictEquals(result.default, true);
});

test("basicTransform", ['native', 'wasm-main', 'wasm-worker'], async ({ ezburn }) => {
  const ts = 'let x: number = 1+2';
  const result = await ezburn.transform(ts, { loader: 'ts' });
  asserts.assertStrictEquals(result.code, 'let x = 1 + 2;\n');
});

// This test doesn't run in WebAssembly because of a stack overflow
test("largeTransform", ['native'], async ({ ezburn }) => {
  let x = '0';
  for (let i = 0; i < 1000; i++) x += '+' + i;
  x += ',';
  let y = 'return[';
  for (let i = 0; i < 1000; i++) y += x;
  y += ']';
  const result = await ezburn.build({
    stdin: { contents: y },
    write: false,
    minifyWhitespace: true,
  });
  asserts.assertStrictEquals(result.outputFiles[0].text, y.slice(0, -2) + '];\n');
});

test("analyzeMetafile", ['native', 'wasm-main', 'wasm-worker'], async ({ ezburn }) => {
  const result = await ezburn.analyzeMetafile({
    outputs: {
      'out.js': {
        bytes: 4096,
        inputs: {
          'in.js': { bytesInOutput: 1024 },
        },
      },
    },
  });
  asserts.assertStrictEquals(result, `
  out.js    4.0kb  100.0%
   └ in.js  1.0kb   25.0%
`);
});
