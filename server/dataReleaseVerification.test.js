import test from 'node:test';
import assert from 'node:assert/strict';
import {DataReleaseVerification} from './dataReleaseVerification.js';
const tick=()=>new Promise(resolve=>setImmediate(resolve));
test('lease failure is terminal and never starts work',()=>{
 const v=new DataReleaseVerification();let calls=0;
 const result=v.poll({key:'missing',pin:()=>{throw Error('private');},run:()=>calls++});
 assert.equal(result.status,'failed');assert.equal(calls,0);
});
test('polling returns immediately, pins once, and coalesces repeated requests',async()=>{
 const v=new DataReleaseVerification();let finish,calls=0,leases=0;
 const args={key:'one',pin:()=>{leases++;return ()=>leases--;},run:stage=>stage('fundamentals',async()=>{calls++;await new Promise(r=>finish=r);return {status:'verified',releaseId:'one'};})};
 assert.equal(v.poll(args).status,'preparing');assert.equal(leases,1);
 await tick();assert.equal(v.poll(args).stage,'fundamentals');assert.equal(calls,1);
 finish();await tick();assert.equal(v.poll(args).releaseId,'one');assert.equal(leases,0);
});
test('failed checks never become verified, retain phase and retry only after cooldown',async()=>{
 let now=0,calls=0;const v=new DataReleaseVerification({clock:()=>now,retryMs:30});
 const args={key:'x',pin:()=>()=>{},run:stage=>stage('research',()=>{calls++;throw Error('secret must not leak');})};
 v.poll(args);await tick();assert.equal(v.poll(args).status,'failed');assert.equal(v.poll(args).stage,'research');
 assert.ok(!JSON.stringify(v.poll(args)).includes('secret'));assert.equal(calls,1);
 now=31;assert.equal(v.poll(args).status,'preparing');await tick();assert.equal(calls,2);
});
test('new release cannot reuse old verification or overlap a running job',async()=>{
 const v=new DataReleaseVerification();let finish;
 v.poll({key:'old',pin:()=>()=>{},run:()=>new Promise(r=>finish=r)});await tick();
 const args={key:'new',pin:()=>()=>{},run:async()=>({status:'verified',releaseId:'new'})};
 assert.equal(v.poll(args).stage,'waiting_for_previous_verification');
 finish({status:'verified',releaseId:'old'});await tick();
 assert.equal(v.poll(args).status,'preparing');await tick();assert.equal(v.poll(args).releaseId,'new');
});
