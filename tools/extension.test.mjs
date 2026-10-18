import test from 'node:test';
import assert from 'node:assert/strict';
import {connect,localSocket,pageTarget} from '../extension/cdp.mjs';
import {animationProgress,isWindowsSubpath,remoteDebuggingArguments,validateListenerRecords} from '../extension/run-windows.mjs';
test('只选择官方主窗口，拒绝网站及辅助窗口',()=>{
  assert.equal(pageTarget({type:'page',url:'app://-/index.html'}),true);
  for(const url of ['https://example.com/index.html','app://other/index.html','about:blank','app://-/index.html?initialRoute=quick-chat','app://-/index.html?initialRoute=avatar'])assert.equal(pageTarget({type:'page',url}),false);
});
test('只连接指定回环端口的页面 websocket',()=>{
  assert.equal(localSocket('ws://127.0.0.1:9341/devtools/page/1',9341),'ws://127.0.0.1:9341/devtools/page/1');
  for(const value of ['ws://example.com:9341/devtools/page/1','ws://127.0.0.1:9222/devtools/page/1','ws://127.0.0.1:9341/devtools/browser/1','ws://user@127.0.0.1:9341/devtools/page/1'])assert.throws(()=>localSocket(value,9341));
});
class FakeSocket extends EventTarget{
  constructor(){super();queueMicrotask(()=>this.dispatchEvent(new Event('open')));}
  send(data){const {id,method}=JSON.parse(data);if(method==='timeout')return;queueMicrotask(()=>this.dispatchEvent(new MessageEvent('message',{data:JSON.stringify(method==='error'?{id,error:{message:'denied'}}:{id,result:{ok:method}})})));}
  close(){this.dispatchEvent(new Event('close'));}
}
test('请求匹配、错误和超时后可正常关闭',async()=>{
  const client=await connect('ws://test',FakeSocket);
  assert.deepEqual(await Promise.all([client.call('first'),client.call('second')]),[{ok:'first'},{ok:'second'}]);
  await assert.rejects(client.call('error'),/denied/);await assert.rejects(client.call('timeout',{},10),/超时/);client.close();
});
test('Windows 监听进程必须来自目标包和当前会话',()=>{
  const bundle='C:\\Program Files\\WindowsApps\\OpenAI.Codex_1.0.0.0_x64__2p2nqsd0c76g0';
  const good={LocalAddress:'127.0.0.1',LocalPort:9341,OwningProcess:41,Path:bundle+'\\app\\ChatGPT.exe',SessionId:3};
  assert.equal(isWindowsSubpath(bundle,good.Path),true);
  assert.equal(isWindowsSubpath(bundle,'C:\\Windows\\System32\\cmd.exe'),false);
  assert.deepEqual(validateListenerRecords([good],9341,bundle,3),[good]);
  assert.throws(()=>validateListenerRecords([{...good,LocalAddress:'0.0.0.0'}],9341,bundle,3),/127\.0\.0\.1/);
  assert.throws(()=>validateListenerRecords([{...good,Path:'C:\\Temp\\ChatGPT.exe'}],9341,bundle,3),/不属于/);
  assert.throws(()=>validateListenerRecords([{...good,SessionId:4}],9341,bundle,3),/会话/);
});
test('Windows 应用激活参数只接受有效回环调试端口',()=>{
  assert.deepEqual(remoteDebuggingArguments(9341),[
    '--remote-debugging-address=127.0.0.1',
    '--remote-debugging-port=9341'
  ]);
  for(const value of [0,65536,1.5,'invalid'])assert.throws(()=>remoteDebuggingArguments(value),/无效/);
});
test('Windows 动画只有在可见覆盖层播放时才算启动成功',()=>{
  assert.equal(animationProgress({ready:true,phase:'playing',overlay:true}),'ready');
  assert.equal(animationProgress({ready:true,phase:'playing',overlay:false}),'waiting');
  assert.equal(animationProgress({ready:true,phase:'timeout',overlay:false}),'failed');
  assert.equal(animationProgress({ready:false,phase:'loading',overlay:true}),'waiting');
});
