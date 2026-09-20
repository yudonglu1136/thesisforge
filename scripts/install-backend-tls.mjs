// Operator/postdeploy installer. Existing nginx:80 and the application remain
// untouched. Only the dedicated backend hostname terminates TLS here.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import {execFileSync} from 'node:child_process';
const run=(bin,args,options={})=>execFileSync(bin,args,{encoding:'utf8',stdio:['ignore','pipe','pipe'],timeout:30000,...options});
if(process.argv[2]!=='--install-existing-host'||process.getuid()!==0||process.platform!=='linux'||process.arch!=='x64')throw Error('explicit_linux_root_install_required');
const env=JSON.parse(run('/opt/elasticbeanstalk/bin/get-config',['environment']));
if(!(/^\/var\/app\/data\/thesisforge-[0-9]{8}-v[1-9][0-9]*\.sqlite$/.test(env.SQLITE_DB_PATH||'')
  ||env.SQLITE_DB_PATH==='/var/app/data/thesisforge.sqlite')||env.NODE_ENV!=='production')throw Error('unexpected_backend_host');
const dir='/var/lib/thesisforge-caddy',binary='/usr/local/bin/thesisforge-caddy';
const cfg=`{
 admin off
 auto_https disable_redirects
 email luyudong1136@gmail.com
 storage file_system ${dir}
 servers {
  protocols h1 h2
  timeouts {
   read_header 10s
   idle 2m
  }
 }
}
backend.thesisforge.tech {
 tls {
  issuer acme {
   dir https://acme-v02.api.letsencrypt.org/directory
   disable_http_challenge
  }
 }
 @internal path_regexp private (?i)^/api/internal(?:/|$)
 handle @internal {
  header Cache-Control "no-store"
  respond 404
 }
 handle /api/* {
  reverse_proxy 127.0.0.1:80
 }
 handle /guru-avatars/* {
  reverse_proxy 127.0.0.1:80
 }
 handle {
  respond 404
 }
}
`;
const unit=`[Unit]
Description=ThesisForge HTTPS API (existing host)
After=network-online.target nginx.service
Wants=network-online.target
[Service]
User=thesisforge-caddy
Group=thesisforge-caddy
ExecStart=${binary} run --config /etc/thesisforge-caddy/Caddyfile --adapter caddyfile
Restart=on-failure
RestartSec=5s
TimeoutStopSec=10s
LimitNOFILE=16384
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
StateDirectory=thesisforge-caddy
StateDirectoryMode=0700
MemoryMax=192M
TasksMax=128
[Install]
WantedBy=multi-user.target
`;
const scratch=fs.mkdtempSync(path.join(os.tmpdir(),'tf-caddy-install-'));
try {
 let installed=false;try{installed=run(binary,['version']).startsWith('v2.11.4 ');}catch{}
 if(!installed){
  const response=await fetch('https://github.com/caddyserver/caddy/releases/download/v2.11.4/caddy_2.11.4_linux_amd64.tar.gz',{signal:AbortSignal.timeout(90000)});
  if(!response.ok)throw Error('caddy_download_failed');
  const data=Buffer.from(await response.arrayBuffer());
  if(crypto.createHash('sha512').update(data).digest('hex')!=='8220d1f013b6f27510247b2360c9e0ca9f018feebd82515f07635318b34ff9777ccc8fd0b6e6f2486ce3a33fe389fbb7db12d05baa474f4587509fb4f5ebf1c9')throw Error('caddy_checksum_mismatch');
  const archive=path.join(scratch,'caddy.tar.gz');fs.writeFileSync(archive,data,{mode:0o600});
  run('tar',['-xzf',archive,'-C',scratch,'caddy']);run('install',['-m','0755',path.join(scratch,'caddy'),binary]);
 }
 try{run('id',['thesisforge-caddy']);}catch{run('useradd',['--system','--home-dir',dir,'--shell','/sbin/nologin','thesisforge-caddy']);}
 run('install',['-d','-m','0700','-o','thesisforge-caddy','-g','thesisforge-caddy',dir]);
 run('install',['-d','-m','0755','/etc/thesisforge-caddy']);
 const target='/etc/thesisforge-caddy/Caddyfile',service='/etc/systemd/system/thesisforge-caddy.service';
 const changed=!fs.existsSync(target)||fs.readFileSync(target,'utf8')!==cfg||!fs.existsSync(service)||fs.readFileSync(service,'utf8')!==unit;
 const candidate=path.join(scratch,'Caddyfile');fs.writeFileSync(candidate,cfg);
 run(binary,['adapt','--config',candidate,'--adapter','caddyfile']);
 fs.writeFileSync(target,cfg,{mode:0o644});fs.writeFileSync(service,unit,{mode:0o644});
 run('systemctl',['daemon-reload']);run('systemctl',['enable','thesisforge-caddy.service']);
 run('systemctl',[changed?'restart':'start','thesisforge-caddy.service']);
 console.log(JSON.stringify({status:'https_service_installed',domain:'backend.thesisforge.tech',version:'2.11.4',active:run('systemctl',['is-active','thesisforge-caddy.service']).trim(),certificateMustBeVerifiedSeparately:true,existingNginxUnchanged:true}));
}finally{fs.rmSync(scratch,{recursive:true,force:true});}
