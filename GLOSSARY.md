# pocket-cloud

How the pocket apps and other stacks on the home server are run: what runs where, under which version, and where
its data lives. Pocket app repos use these terms for anything about deployment.

## Language

### Where things run

**Home server**:
The one physical machine at home that runs every pocket app.
_Avoid_: Mac mini, the Mac, host, server, home-server (that is pocket-home's server app)

**pocket-cloud VM**:
The Linux VM on the home server that runs every stack.
_Avoid_: profile, context, Colima

**Dev VM**:
The separate VM used for local development, never for running apps.
_Avoid_: default profile

**Native part**:
The part of a pocket app that runs directly on the home server, outside the pocket-cloud VM.
_Avoid_: native service, host half, host service

### What runs

**Pocket app**:
One of our own pocket-* products, deployed as a stack, a native part, or both.
_Avoid_: app (that is a runnable inside a pocket app), project, product

**Stack**:
One deployable unit of the pocket-cloud VM, holding one or more containers, started and stopped together.
_Avoid_: service

**Container**:
One running unit of a stack, started from one image.
_Avoid_: service (that is a part of a pocket app's backend), stack

**Release**:
The exact pinned version of a pocket app that the home server runs.
_Avoid_: version, build, deploy

### Reaching and keeping things

**Tailnet**:
The private network of the owner's own devices, through which stacks are reached from anywhere.

**Tailnet node**:
The tailnet address through which one stack is reachable from the owner's devices.
_Avoid_: sidecar, exposed service

**Data root**:
The one place on the home server where stacks keep their data, one folder per stack, never in git.
_Avoid_: data dir, volume

**Backup**:
A nightly copy of the data root, kept on storage separate from it.
_Avoid_: snapshot (for the whole), dump
