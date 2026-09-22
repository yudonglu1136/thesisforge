from dataclasses import dataclass, field, asdict
from typing import Any
import hashlib
import json


def encode(value):
    return json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False,default=str).encode()


def digest(value):
    return hashlib.sha256(encode(value)).hexdigest()


@dataclass(frozen=True)
class TaskSpec:
    id: str
    kind: str
    implementationVersion: str
    methodologyVersion: str
    configHashes: dict
    requiredInputs: tuple
    optionalInputs: tuple = ()
    partitionSelector: str = 'changed-source-partitions'
    outputSchemaVersion: str = '1'
    resourceClass: str = 'bounded'
    retryPolicy: str = 'resume-validated-result'
    timeout: int = 3600
    validators: tuple = ('checksum','schema','coverage')
    publicationGroup: str = ''
    dependsOn: tuple = ()
    publicationPolicy: str = 'automatic_after_checks'


@dataclass(frozen=True)
class InputSnapshot:
    snapshotId: str
    root: str
    schemaVersions: dict
    inputs: dict
    frozenConfig: dict
    codeVersion: str


@dataclass(frozen=True)
class TaskPlan:
    taskId: str
    inputFingerprint: str
    reason: str
    affectedPartitions: dict
    reusedOutputs: Any = None
    expectedBytes: int = 0
    missingRequired: tuple = ()
    inputVector: dict = field(default_factory=dict)


@dataclass(frozen=True)
class BuildResult:
    status: str
    artifactId: str
    semanticSha256: str
    files: tuple
    schemaVersion: str
    coverage: dict
    inputRefs: dict
    validationReceipt: dict


@dataclass(frozen=True)
class PublicationGroupManifest:
    groupId: str
    generationId: str
    members: dict
    inputVector: dict
    compatibilityVersion: str
    requiredMatrix: tuple
    checks: dict
    previousGeneration: str | None


def record(value):
    return asdict(value)
