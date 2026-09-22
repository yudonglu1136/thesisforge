#!/usr/bin/env python3
"""Emit the reviewed single-writer AWS topology (no credentials in template)."""
import json


def template():
    ref=lambda name:{'Ref':name}
    sub=lambda text:{'Fn::Sub':text}
    arn=lambda name:{'Fn::GetAtt':[name,'Arn']}
    trust=lambda service:{'Version':'2012-10-17','Statement':[{'Effect':'Allow','Principal':{'Service':service},'Action':'sts:AssumeRole'}]}
    statement=lambda actions,resources:{'Effect':'Allow','Action':actions,'Resource':resources}
    policy=lambda name,statements:{'PolicyName':name,'PolicyDocument':{'Version':'2012-10-17','Statement':statements}}
    resources={
      'SharadarSecret':{'Type':'AWS::SecretsManager::Secret','DeletionPolicy':'Retain','UpdateReplacePolicy':'Retain','Properties':{
        'Name':'thesisforge/fact-os/sharadar','Description':'Native Sharadar API key; populated separately without logging value'}},
      'WorkerRole':{'Type':'AWS::IAM::Role','Properties':{'AssumeRolePolicyDocument':trust('ec2.amazonaws.com'),
        'ManagedPolicyArns':['arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore'],
        'Policies':[policy('fact-os-bounded-storage',[
          statement(['secretsmanager:GetSecretValue'],ref('SharadarSecret')),
          {**statement(['s3:ListBucket'],sub('arn:aws:s3:::${Bucket}')),'Condition':{'StringLike':{'s3:prefix':['fact-os/*']}}},
          statement(['s3:GetObject','s3:PutObject','s3:GetObjectTagging','s3:PutObjectTagging'],sub('arn:aws:s3:::${Bucket}/fact-os/*')),
          statement(['ssm:SendCommand'],[sub('arn:aws:ssm:${AWS::Region}:${AWS::AccountId}:document/${InstallDocument}'),sub('arn:aws:ec2:${AWS::Region}:${AWS::AccountId}:instance/${ApiInstanceId}')]),
          statement(['ssm:GetCommandInvocation'],'*'),
        ])]}},
      'WorkerProfile':{'Type':'AWS::IAM::InstanceProfile','Properties':{'Roles':[ref('WorkerRole')]}},
      'WorkerSecurityGroup':{'Type':'AWS::EC2::SecurityGroup','Properties':{
        'GroupDescription':'Fact OS worker: no inbound ports; administration through SSM', 'VpcId':ref('VpcId'),
        'SecurityGroupEgress':[{'IpProtocol':'tcp','FromPort':443,'ToPort':443,'CidrIp':'0.0.0.0/0'},
                              {'IpProtocol':'tcp','FromPort':80,'ToPort':80,'CidrIp':'0.0.0.0/0'}]}},
      'DataVolume':{'Type':'AWS::EC2::Volume','DeletionPolicy':'Retain','UpdateReplacePolicy':'Retain','Properties':{
        'AvailabilityZone':ref('AvailabilityZone'),'Size':100,'VolumeType':'gp3','Encrypted':True,
        'Tags':[{'Key':'Name','Value':'thesisforge-fact-os-authoritative-data'}]}},
      'Worker':{'Type':'AWS::EC2::Instance','Properties':{
        'ImageId':ref('AmiId'),'InstanceType':'m7i.large','IamInstanceProfile':ref('WorkerProfile'),
        'SubnetId':ref('SubnetId'),'SecurityGroupIds':[ref('WorkerSecurityGroup')],
        'MetadataOptions':{'HttpTokens':'required','HttpEndpoint':'enabled'},
        'BlockDeviceMappings':[{'DeviceName':'/dev/xvda','Ebs':{'VolumeSize':24,'VolumeType':'gp3','Encrypted':True,'DeleteOnTermination':True}}],
        'Tags':[{'Key':'Name','Value':'thesisforge-fact-os-writer'},{'Key':'DataAuthority','Value':'fact-os'}],
        'UserData':{'Fn::Base64':sub('''#!/bin/bash
set -euo pipefail
dnf install -y python3.12 python3.12-pip nodejs22 amazon-ssm-agent
useradd --system --create-home --home-dir /opt/fact-os factos
install -d -m 0750 -o factos -g factos /var/lib/fact-os /opt/fact-os/releases
python3.12 -m venv /opt/fact-os/venv
/opt/fact-os/venv/bin/pip install 'duckdb==1.4.4' 'httpx==0.28.1' 'boto3==1.42.70' 'pyarrow==23.0.1'
# Mount ONLY the exact retained volume provisioned by this stack.
volume='${DataVolume}'
serial="$(echo "$volume" | tr -d '-')"
device="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_$serial"
for attempt in $(seq 1 120); do test -b "$device" && break; sleep 5; done
test -b "$device"
if ! blkid "$device"; then mkfs.ext4 "$device"; fi
uuid="$(blkid -s UUID -o value "$device")"
test -n "$uuid"
printf 'UUID=%s /var/lib/fact-os ext4 defaults,nofail 0 2\n' "$uuid" >> /etc/fstab
mount /var/lib/fact-os
chown factos:factos /var/lib/fact-os
chmod 0750 /var/lib/fact-os
systemctl enable --now amazon-ssm-agent
''') }}},
      'DataAttachment':{'Type':'AWS::EC2::VolumeAttachment','Properties':{
        'Device':'/dev/sdf','InstanceId':ref('Worker'),'VolumeId':ref('DataVolume')}},
      'ApiReadPolicy':{'Type':'AWS::IAM::Policy','Properties':{**policy('fact-os-read-and-ssm',[
        statement(['s3:GetObject'],sub('arn:aws:s3:::${Bucket}/fact-os/published/*')),
        statement(['ssm:UpdateInstanceInformation','ssmmessages:CreateControlChannel','ssmmessages:CreateDataChannel',
                   'ssmmessages:OpenControlChannel','ssmmessages:OpenDataChannel'],'*'),
        ]),'Roles':[ref('ApiRoleName')]}},
      'InstallDocument':{'Type':'AWS::SSM::Document','Properties':{'DocumentType':'Command','DocumentFormat':'JSON','UpdateMethod':'NewVersion',
        'Content':{'schemaVersion':'2.2','description':'Fixed public Fact OS installer; no arbitrary commands or writer access',
          'parameters':{'ReleaseKey':{'type':'String','allowedPattern':'^fact-os/published/releases/[a-f0-9]{64}\\.json$','interpolationType':'ENV_VAR'},
                        'ExpectedRelease':{'type':'String','allowedPattern':'^([a-f0-9]{64}|none)$','interpolationType':'ENV_VAR'}},
          'mainSteps':[{'action':'aws:runShellScript','name':'InstallFactOs','inputs':{'timeoutSeconds':'3600','runCommand':[
            'set -eu','cd /var/app/current',
            sub('/opt/thesisforge-fact-os/bin/python scripts/fact-os-api-install.py --bucket ${Bucket} --candidate-key "$SSM_ReleaseKey" --expected-release "$SSM_ExpectedRelease"')
          ]}}]}}},
      'RunDocument':{'Type':'AWS::SSM::Document','Properties':{
        'DocumentType':'Command','DocumentFormat':'JSON','UpdateMethod':'NewVersion',
        'Content':{'schemaVersion':'2.2','description':'Fixed Fact OS pipeline entrypoint; no caller-provided shell commands',
          'parameters':{'ScheduledFor':{'type':'String','allowedPattern':'^[0-9T:.Z+\\-]+$','interpolationType':'ENV_VAR'}},
          'mainSteps':[{'action':'aws:runShellScript','name':'FactOsDaily','inputs':{
            'timeoutSeconds':'21600','runCommand':[
              'set -eu',
              'test -x /opt/fact-os/current/bin/fact-os-worker',
              sub('sudo -u factos env FACT_OS_ROOT=/var/lib/fact-os/data FACT_OS_SECRET_ID=${SharadarSecret} FACT_OS_BUCKET=${Bucket} FACT_OS_INSTALL_DOCUMENT=${InstallDocument} FACT_OS_INSTALL_DOCUMENT_VERSION=${InstallDocumentVersion} FACT_OS_API_INSTANCE_ID=${ApiInstanceId} AWS_DEFAULT_REGION=${AWS::Region} /opt/fact-os/current/bin/fact-os-worker --scheduled-for "$SSM_ScheduledFor"')
            ]}}]}}},
      'StateRole':{'Type':'AWS::IAM::Role','Properties':{'AssumeRolePolicyDocument':trust('states.amazonaws.com'),
        'Policies':[policy('only-fact-os-worker',[
          statement(['ssm:SendCommand'],[sub('arn:aws:ssm:${AWS::Region}:${AWS::AccountId}:document/${RunDocument}'),sub('arn:aws:ec2:${AWS::Region}:${AWS::AccountId}:instance/${Worker}')]),
          statement(['ssm:GetCommandInvocation'],'*')])]}},
      'StateMachine':{'Type':'AWS::StepFunctions::StateMachine','Properties':{
        'StateMachineType':'STANDARD','RoleArn':arn('StateRole'),
        'Definition':{'StartAt':'Send','TimeoutSeconds':22200,'States':{
          'Send':{'Type':'Task','Resource':'arn:aws:states:::aws-sdk:ssm:sendCommand',
            'Parameters':{'DocumentName':ref('RunDocument'),'DocumentVersion':ref('RunDocumentVersion'),'InstanceIds':[ref('Worker')],
                          'Parameters':{'ScheduledFor.$':'States.Array($.scheduledFor)'},'TimeoutSeconds':600},
            'ResultPath':'$.dispatch','Next':'Wait'},
          'Wait':{'Type':'Wait','Seconds':30,'Next':'Poll'},
          'Poll':{'Type':'Task','Resource':'arn:aws:states:::aws-sdk:ssm:getCommandInvocation',
            'Parameters':{'CommandId.$':'$.dispatch.Command.CommandId','InstanceId':ref('Worker')},
            'Retry':[{'ErrorEquals':['Ssm.InvocationDoesNotExistException'],'IntervalSeconds':10,'MaxAttempts':6}],
            'ResultPath':'$.invocation','Next':'Check'},
          'Check':{'Type':'Choice','Choices':[
            {'Variable':'$.invocation.Status','StringEquals':'Success','Next':'Verified'},
            {'Variable':'$.invocation.Status','StringEquals':'Pending','Next':'Wait'},
            {'Variable':'$.invocation.Status','StringEquals':'InProgress','Next':'Wait'},
            {'Variable':'$.invocation.Status','StringEquals':'Delayed','Next':'Wait'}],'Default':'Failed'},
          # Worker exits zero ONLY after published-generation API ACK validation.
          'Verified':{'Type':'Succeed'},'Failed':{'Type':'Fail','Error':'FactOsPipelineNotVerified'}
        }}}},
      'SchedulerRole':{'Type':'AWS::IAM::Role','Properties':{'AssumeRolePolicyDocument':trust('scheduler.amazonaws.com'),
        'Policies':[policy('start-fact-os-only',[statement(['states:StartExecution'],arn('StateMachine'))])]}},
      'DailySchedule':{'Type':'AWS::Scheduler::Schedule','Properties':{
        'Name':'thesisforge-fact-os-daily','Description':'All 14 authorized Fact OS tables; worker receipt and API ACK required',
        'ScheduleExpression':'cron(30 7 * * ? *)','ScheduleExpressionTimezone':'Asia/Riyadh',
        'State':ref('ScheduleState'),'FlexibleTimeWindow':{'Mode':'OFF'},
        'Target':{'Arn':arn('StateMachine'),'RoleArn':arn('SchedulerRole'),
            'Input':'{"scheduledFor":"<aws.scheduler.scheduled-time>","trigger":"scheduler"}',
            'RetryPolicy':{'MaximumEventAgeInSeconds':3600,'MaximumRetryAttempts':2}}}},
      'FailureAlarm':{'Type':'AWS::CloudWatch::Alarm','Properties':{
        'AlarmDescription':'Fact OS daily workflow failed; previous release retained',
        'Namespace':'AWS/States','MetricName':'ExecutionsFailed','Statistic':'Sum','Period':300,
        'EvaluationPeriods':1,'Threshold':1,'ComparisonOperator':'GreaterThanOrEqualToThreshold','TreatMissingData':'notBreaching',
        'Dimensions':[{'Name':'StateMachineArn','Value':arn('StateMachine')}]}}
    }
    return {'AWSTemplateFormatVersion':'2010-09-09','Description':'ThesisForge unified Fact OS single-writer pipeline; schedule disabled until live verification',
      'Parameters':{
        'Bucket':{'Type':'String'},'VpcId':{'Type':'AWS::EC2::VPC::Id'},'SubnetId':{'Type':'AWS::EC2::Subnet::Id'},
        'AvailabilityZone':{'Type':'String'},
        'ApiRoleName':{'Type':'String','Default':'thesisforge-elasticbeanstalk-ec2-role'},
        'ApiInstanceId':{'Type':'String','AllowedPattern':'^i-[a-f0-9]+$'},
        'RunDocumentVersion':{'Type':'String','Default':'1','AllowedPattern':'^[1-9][0-9]*$'},
        'InstallDocumentVersion':{'Type':'String','Default':'1','AllowedPattern':'^[1-9][0-9]*$'},
        'AmiId':{'Type':'AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>','Default':'/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64'},
        'ScheduleState':{'Type':'String','Default':'DISABLED','AllowedValues':['DISABLED','ENABLED']}},
      'Resources':resources,'Outputs':{'WorkerId':{'Value':ref('Worker')},'VolumeId':{'Value':ref('DataVolume')},
        'SecretArn':{'Value':ref('SharadarSecret')},'StateMachineArn':{'Value':arn('StateMachine')},'RunDocument':{'Value':ref('RunDocument')},
        'InstallDocument':{'Value':ref('InstallDocument')}}}


if __name__=='__main__':
    print(json.dumps(template(),indent=2))
