import {spawn} from 'node:child_process';
import {mkdir, writeFile} from 'node:fs/promises';
import {createServer} from 'node:net';
import {dirname, join, resolve} from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';
import {setTimeout as delay} from 'node:timers/promises';
import {connect, localSocket} from '../extension/cdp.mjs';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const browserIndex = process.argv.indexOf('--browser');
const browser = browserIndex >= 0 ? process.argv[browserIndex + 1] : undefined;
if (!browser) throw new Error('Pass --browser with the full path to Edge or Chrome.');
const pageIndex = process.argv.indexOf('--page');
const page = pageIndex >= 0 ? resolve(process.argv[pageIndex + 1]) : resolve(root, 'index.html');
const extensionMode = process.argv.includes('--extension');
const outputPrefix = extensionMode ? 'windows-extension' : 'windows';

async function freePort() {
  return new Promise((resolvePort, reject) => {
    const server = createServer();
    server.on('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const port = server.address().port;
      server.close(error => error ? reject(error) : resolvePort(port));
    });
  });
}

async function targetFor(port) {
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/json/list`, {signal: AbortSignal.timeout(1000)});
      const targets = await response.json();
      const target = targets.find(value => value.type === 'page' && value.url.startsWith('file:'));
      if (target) return target;
    } catch {}
    await delay(100);
  }
  throw new Error('Headless browser did not expose the preview page.');
}

async function screenshot(client, path) {
  const result = await client.call('Page.captureScreenshot', {format: 'png', captureBeyondViewport: false});
  await writeFile(path, Buffer.from(result.data, 'base64'));
}

const port = await freePort();
const profile = join(root, '.build', `browser-smoke-profile-${process.pid}`);
const output = join(root, '.build');
await mkdir(profile, {recursive: true});
const child = spawn(browser, [
  '--headless=new', '--disable-gpu', '--hide-scrollbars', '--allow-file-access-from-files',
  `--user-data-dir=${profile}`, '--remote-debugging-address=127.0.0.1',
  `--remote-debugging-port=${port}`, '--window-size=1440,1000',
  pathToFileURL(page).href
], {stdio: 'ignore', windowsHide: true});

let client;
try {
  const target = await targetFor(port);
  client = await connect(localSocket(target.webSocketDebuggerUrl, port));
  await client.call('Page.enable');
  await client.call('Runtime.evaluate', {
    expression: `new Promise((resolve,reject)=>{
      const end=Date.now()+10000;
      const check=()=>{
        const doc=document.querySelector('#aemeath-extension-overlay')?.contentDocument||document;
        const art=doc.querySelector('.artwork'),avatar=doc.querySelector('.avatar');
        if(art?.complete&&art.naturalWidth&&avatar?.complete&&avatar.naturalWidth)return resolve(true);
        if(Date.now()>end)return reject(new Error('asset timeout'));
        setTimeout(check,50);
      };check();
    })`, awaitPromise: true, returnByValue: true
  });
  await delay(250);
  await client.call('Runtime.evaluate', {
    expression: `(()=>{const doc=document.querySelector('#aemeath-extension-overlay')?.contentDocument||document;const slider=doc.querySelector('#timeline');slider.value='7.5';slider.dispatchEvent(new Event('input',{bubbles:true}));return true})()`,
    returnByValue: true
  });
  await delay(100);
  await screenshot(client, join(output, `${outputPrefix}-preview-7.5s.png`));
  await client.call('Runtime.evaluate', {
    expression: `(()=>{const frame=document.querySelector('#aemeath-extension-overlay');if(frame)return frame.contentWindow.launcherUI.openSettings();return window.launcherUI?.openSettings()})()`,
    returnByValue: true
  });
  await delay(100);
  await screenshot(client, join(output, `${outputPrefix}-settings.png`));
  const result = await client.call('Runtime.evaluate', {
    expression: `({
      extensionInstalled:Boolean(window.__aemeathExtension),
      artworkWidth:(document.querySelector('#aemeath-extension-overlay')?.contentDocument||document).querySelector('.artwork')?.naturalWidth,
      avatarWidth:(document.querySelector('#aemeath-extension-overlay')?.contentDocument||document).querySelector('.avatar')?.naturalWidth,
      elapsed:(document.querySelector('#aemeath-extension-overlay')?.contentDocument||document).querySelector('.window')?.dataset.elapsed,
      settingsOpen:(document.querySelector('#aemeath-extension-overlay')?.contentDocument||document).querySelector('#settings-dialog')?.open,
      assetErrorHidden:(document.querySelector('#aemeath-extension-overlay')?.contentDocument||document).querySelector('#asset-error')?.hidden
    })`, returnByValue: true
  });
  console.log(JSON.stringify(result.result?.value));
} finally {
  client?.close();
  child.kill();
}
