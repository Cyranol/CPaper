import {execFile as rawExec, spawn} from 'node:child_process';
import {promisify} from 'node:util';
import {createServer} from 'node:net';
import {readFile, realpath} from 'node:fs/promises';
import {dirname, join, relative, resolve, sep, win32} from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';
import {setTimeout as delay} from 'node:timers/promises';
import {buildInjection} from './payload.mjs';
import {connect, localSocket, pageTarget} from './cdp.mjs';

const exec = promisify(rawExec);
const root = dirname(dirname(fileURLToPath(import.meta.url)));

function argument(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

async function powershell(script) {
  const {stdout} = await exec('powershell.exe', [
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script
  ], {timeout: 15000, maxBuffer: 1024 * 1024, windowsHide: true});
  return stdout.trim();
}

export function remoteDebuggingArguments(port) {
  const value = Number(port);
  if (!Number.isInteger(value) || value <= 0 || value > 65535) throw new Error('无效的调试端口');
  return [
    '--remote-debugging-address=127.0.0.1',
    `--remote-debugging-port=${value}`
  ];
}

export function animationProgress(state) {
  if (state?.phase === 'failed' || state?.phase === 'timeout') return 'failed';
  if (state?.ready && state?.overlay) return 'ready';
  return 'waiting';
}

async function activateOfficialApplication() {
  const opener = spawn('explorer.exe', [
    'shell:AppsFolder\\OpenAI.Codex_2p2nqsd0c76g0!App'
  ], {detached: true, stdio: 'ignore', windowsHide: true});
  await new Promise((resolveSpawn, rejectSpawn) => {
    opener.once('spawn', resolveSpawn);
    opener.once('error', rejectSpawn);
  });
  opener.unref();
  await delay(250);
}

async function showApplicationWindow(processId) {
  await exec('powershell.exe', [
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', join(root, 'tools', 'show-chatgpt-window.ps1'),
    '-ProcessId', String(processId)
  ], {timeout: 15000, windowsHide: true});
  await delay(300);
}

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

export function isWindowsSubpath(parent, child) {
  const value = win32.relative(win32.resolve(parent), win32.resolve(child));
  return value === '' || (!value.startsWith('..' + win32.sep) && value !== '..' && !win32.isAbsolute(value));
}

export function validateListenerRecords(records, port, bundle, sessionId) {
  if (!Array.isArray(records) || records.length === 0) throw new Error('尚未发现调试端口监听进程');
  for (const record of records) {
    if (record.LocalAddress !== '127.0.0.1' || Number(record.LocalPort) !== port) {
      throw new Error('调试端口没有严格限定在 127.0.0.1，停止连接');
    }
    if (!Number.isInteger(Number(record.OwningProcess)) || !isWindowsSubpath(bundle, record.Path || '')) {
      throw new Error('调试端口不属于目标 Codex 应用');
    }
    if (Number(record.SessionId) !== Number(sessionId)) throw new Error('调试端口所属 Windows 会话不匹配');
  }
  return records;
}

export async function verifyListener(port, bundle) {
  const script = [
    `$currentSession=(Get-Process -Id ${process.pid} -ErrorAction Stop).SessionId`,
    `$items=@(Get-NetTCPConnection -State Listen -LocalPort ${port} -ErrorAction Stop | ForEach-Object {`,
    '  $owner=Get-Process -Id $_.OwningProcess -ErrorAction Stop',
    '  [pscustomobject]@{LocalAddress=$_.LocalAddress;LocalPort=$_.LocalPort;OwningProcess=$_.OwningProcess;Path=$owner.Path;SessionId=$owner.SessionId;CurrentSessionId=$currentSession}',
    '})',
    'ConvertTo-Json -InputObject $items -Compress'
  ].join(';');
  const value = JSON.parse(await powershell(script) || '[]');
  const records = Array.isArray(value) ? value : [value];
  const sessionId = records[0]?.CurrentSessionId;
  return validateListenerRecords(records, port, bundle, sessionId);
}

async function validatePackage(bundle, executable) {
  const expected = await realpath(join(bundle, 'app', 'ChatGPT.exe'));
  if (expected.toLowerCase() !== executable.toLowerCase()) throw new Error('Codex 可执行文件路径不匹配');
  const manifest = await readFile(join(bundle, 'AppxManifest.xml'), 'utf8');
  if (!/<Identity\b[^>]*\bName="OpenAI\.Codex"/i.test(manifest)) throw new Error('应用包标识不匹配');
}

async function activateRunningApp() {
  try {
    const {stdout} = await exec('tasklist.exe', [
      '/FI', 'IMAGENAME eq ChatGPT.exe', '/NH', '/FO', 'CSV'
    ], {timeout: 3000, windowsHide: true});
    if (!/^"ChatGPT\.exe"/im.test(stdout)) return false;
    return true;
  } catch {
    return false;
  }
}

export async function runningDebugPorts(bundle) {
  const escapedBundle = bundle.replaceAll("'", "''");
  const script = [
    `$bundle='${escapedBundle}'`,
    `$currentSession=(Get-Process -Id ${process.pid} -ErrorAction Stop).SessionId`,
    '$ports=@(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | ForEach-Object {',
    '  $owner=$null; try { $owner=Get-Process -Id $_.OwningProcess -ErrorAction Stop } catch {}',
    "  if ($owner -and $_.LocalAddress -eq '127.0.0.1' -and $owner.SessionId -eq $currentSession -and $owner.Path -and ([IO.Path]::GetFullPath($owner.Path)).StartsWith($bundle + '\\', [StringComparison]::OrdinalIgnoreCase)) { [int]$_.LocalPort }",
    '} | Sort-Object -Unique)',
    'ConvertTo-Json -InputObject $ports -Compress'
  ].join(';');
  const value = JSON.parse(await powershell(script) || '[]');
  return (Array.isArray(value) ? value : [value])
    .map(Number).filter(port => Number.isInteger(port) && port > 0 && port <= 65535);
}

async function inject(port, bundle, sourcePromise, timeout) {
  const deadline = Date.now() + timeout;
  let lastError = '等待 Codex 页面';
  let lastActivation = 0;
  let revealed = false;
  while (Date.now() < deadline) {
    let client;
    try {
      const response = await fetch(`http://127.0.0.1:${port}/json/list`, {
        signal: AbortSignal.timeout(450), redirect: 'error'
      });
      if (!response.ok) throw new Error('调试页面尚未就绪');
      const targets = await response.json();
      if (!Array.isArray(targets)) throw new Error('无效页面列表');
      const target = targets.find(pageTarget);
      if (!target) throw new Error('尚未找到主窗口');
      const records = await verifyListener(port, bundle);
      client = await connect(localSocket(target.webSocketDebuggerUrl, port));
      if (!revealed && Date.now() - lastActivation >= 1500) {
        lastActivation = Date.now();
        await showApplicationWindow(records[0].OwningProcess);
        revealed = true;
      }
      if (!revealed) throw new Error('等待 ChatGPT 主窗口');
      const visibility = await client.call('Runtime.evaluate', {
        expression: 'document.visibilityState', returnByValue: true
      });
      if (visibility.result?.value !== 'visible') {
        revealed = false;
        throw new Error('主窗口尚未显示');
      }
      await client.call('Runtime.evaluate', {
        expression: 'globalThis.__aemeathExtension?.dispose?.()',
        awaitPromise: true
      });
      const source = await sourcePromise;
      const result = await client.call('Runtime.evaluate', {
        expression: source, returnByValue: true, awaitPromise: true
      });
      if (result.exceptionDetails || result.result?.value?.installed !== true) throw new Error('外观脚本未能加载');
      for (let attempt = 0; attempt < 50; attempt++) {
        const answer = await client.call('Runtime.evaluate', {
          expression: 'globalThis.__aemeathExtension?.status()', returnByValue: true
        });
        const state = answer.result?.value;
        const progress = animationProgress(state);
        if (progress === 'failed') throw new Error('动画素材加载失败，覆盖层已移除');
        if (progress === 'ready') return state;
        await delay(100);
      }
      throw new Error('动画启动确认超时');
    } catch (error) {
      lastError = error.message;
    } finally {
      client?.close();
    }
    await delay(80);
  }
  throw new Error(lastError);
}

async function main() {
  if (process.platform !== 'win32') throw new Error('这个入口仅用于 Windows');
  const bundleArg = argument('--bundle');
  const executableArg = argument('--executable');
  if (!bundleArg || !executableArg) throw new Error('请从“启动 Codex 动画.cmd”启动');

  const bundle = await realpath(bundleArg);
  const executable = await realpath(executableArg);
  await validatePackage(bundle, executable);
  const sourcePromise = buildInjection(root);
  if (await activateRunningApp()) {
    const ports = await runningDebugPorts(bundle);
    if (!ports.length) {
      await activateOfficialApplication();
      console.log('已唤醒正在运行的 Codex；该实例没有动画调试端口，本次跳过动画。');
      return;
    }
    let lastError = '没有可连接的调试页面';
    for (const port of ports) {
      try {
        await inject(port, bundle, sourcePromise, 15000);
        console.log('已在重新打开的 Codex 窗口应用动画与背景。');
        return;
      } catch (error) {
        lastError = error.message;
      }
    }
    throw new Error('重新应用背景失败：' + lastError);
  }

  const port = await freePort();
  const child = spawn(executable, remoteDebuggingArguments(port), {
    detached: true,
    stdio: 'ignore',
    windowsHide: true
  });
  await new Promise((resolveSpawn, rejectSpawn) => {
    child.once('spawn', resolveSpawn);
    child.once('error', rejectSpawn);
  });
  child.unref();
  try {
    await inject(port, bundle, sourcePromise, 45000);
    console.log('已在 Codex 窗口开始播放。Ctrl+Alt+B 可重新打开图片与文字设置。');
  } catch (error) {
    throw new Error('本版本暂未完成接入：' + error.message + '。Codex 安装包未修改；完全退出后从原图标打开即可关闭调试端口。');
  }
}

const invoked = process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href;
if (invoked) main().catch(error => {
  console.error(error.message);
  process.exitCode = 1;
});
