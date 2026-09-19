import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repo=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
test('deploy hooks never mount, merge, restore or enumerate private tenant paths',t=>{
  const temp=fs.mkdtempSync(path.join(os.tmpdir(),'tf-user-hooks-test-'));
  t.after(()=>fs.rmSync(temp,{recursive:true,force:true}));
  const marker=path.join(temp,'private-tenant.sqlite');
  fs.writeFileSync(marker,'newer user edits');
  for(const name of ['00-restore-portfolio-from-snapshot.sh','00a-diagnose-portfolio-restore.sh']) {
    const result=spawnSync('/bin/bash',[path.join(repo,'.platform/hooks/postdeploy',name)],{
      cwd:temp,encoding:'utf8',env:{PATH:'/nonexistent',USER_DATA_ROOT:temp,PORTFOLIO_LEGACY_SNAPSHOT_RESTORE_ENABLED:'true'}
    });
    assert.equal(result.status,0,result.stderr);
    assert.doesNotMatch(result.stdout,/private-tenant|sqlite\s+\d+|\/var\/app\/data/);
    assert.equal(fs.readFileSync(marker,'utf8'),'newer user edits');
    assert.deepEqual(fs.readdirSync(temp),['private-tenant.sqlite']);
  }
});
