import importlib.util
from pathlib import Path
import unittest

spec=importlib.util.spec_from_file_location('fact_os_aws_template',Path(__file__).with_name('fact-os-aws-template.py'))
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)


class InfrastructureContractTest(unittest.TestCase):
    def setUp(self): self.template=module.template();self.resources=self.template['Resources']

    def test_schedule_has_explicit_timezone_and_starts_disabled(self):
        schedule=self.resources['DailySchedule']['Properties']
        self.assertEqual(schedule['ScheduleExpressionTimezone'],'Asia/Riyadh')
        self.assertEqual(schedule['ScheduleExpression'],'cron(30 7 * * ? *)')
        self.assertEqual(self.template['Parameters']['ScheduleState']['Default'],'DISABLED')

    def test_single_worker_encrypted_retained_data_volume_no_inbound_ports(self):
        self.assertEqual(sum(r['Type']=='AWS::EC2::Instance' for r in self.resources.values()),1)
        volume=self.resources['DataVolume']
        self.assertTrue(volume['Properties']['Encrypted'])
        self.assertEqual(volume['DeletionPolicy'],'Retain')
        self.assertNotIn('SecurityGroupIngress',self.resources['WorkerSecurityGroup']['Properties'])

    def test_secret_not_embedded_and_dispatch_is_fixed_document_version(self):
        self.assertNotIn('SecretString',self.resources['SharadarSecret']['Properties'])
        parameters=self.resources['StateMachine']['Properties']['Definition']['States']['Send']['Parameters']
        self.assertEqual(parameters['DocumentVersion'],{'Ref':'RunDocumentVersion'})
        self.assertEqual(self.template['Parameters']['RunDocumentVersion']['AllowedPattern'],'^[1-9][0-9]*$')
        self.assertNotIn('commands',parameters['Parameters'])
        self.assertEqual(self.resources['StateMachine']['Properties']['StateMachineType'],'STANDARD')

    def test_no_frontend_or_private_broker_resource(self):
        names=' '.join(self.resources).lower()
        for term in ('frontend','broker','yodlee','ibkr'): self.assertNotIn(term,names)

    def test_delivery_failure_timeout_and_worker_output_are_independently_observable(self):
        target=self.resources['DailySchedule']['Properties']['Target']
        self.assertEqual(target['DeadLetterConfig']['Arn'],{'Fn::GetAtt':['DispatchDlq','Arn']})
        self.assertTrue(self.resources['DispatchDlq']['Properties']['SqsManagedSseEnabled'])
        send=self.resources['StateMachine']['Properties']['Definition']['States']['Send']['Parameters']
        self.assertTrue(send['CloudWatchOutputConfig']['CloudWatchOutputEnabled'])
        self.assertEqual(self.resources['WorkerLogs']['Properties']['RetentionInDays'],30)
        self.assertEqual(self.resources['TimeoutAlarm']['Properties']['MetricName'],'ExecutionsTimedOut')
        self.assertEqual(self.resources['DispatchAlarm']['Properties']['Namespace'],'AWS/SQS')


if __name__=='__main__': unittest.main()
