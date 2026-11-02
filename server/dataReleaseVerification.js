// One bounded verification workflow, polled by the loopback installer. Slow
// preparation must not hold an HTTP request open or launch duplicate warmups.
export class DataReleaseVerification {
  constructor({retryMs=30_000,clock=Date.now}={}) {
    this.retryMs=retryMs;this.clock=clock;this.job=null;
  }
  poll({key,run,pin}) {
    const prior=this.job;
    if(prior?.key===key && (prior.status!=='failed'||this.clock()-prior.finishedAt<this.retryMs))return this.view(prior);
    if(prior?.status==='preparing')return {status:'preparing',stage:'waiting_for_previous_verification'};
    const job={key,status:'preparing',stage:'queued',startedAt:this.clock(),timings:{}};
    this.job=job;
    // Pin synchronously, before the short polling response releases its lease.
    let release;
    try{release=pin();}catch{job.status='failed';job.finishedAt=this.clock();return this.view(job);}
    job.promise=Promise.resolve().then(()=>run(async (name,operation)=>{
      job.stage=name;const start=this.clock();
      try{return await operation();}finally{job.timings[name]=this.clock()-start;}
    })).then(value=>{job.value=value;job.status='verified';},()=>{job.status='failed';})
      .finally(()=>{job.finishedAt=this.clock();release();});
    return this.view(job);
  }
  view(job) {
    if(job.status==='verified')return {...job.value,verificationTimingsMs:{...job.timings}};
    return {status:job.status,stage:job.stage,verificationTimingsMs:{...job.timings},
      ...(job.status==='failed'?{error:'data_release_probe_failed'}:{})};
  }
}
