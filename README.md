# ZFS Scrub Script for Talos Linux with Pushover Notifications

This repository contains a Bash script designed to perform ZFS pool scrubbing operations within a Docker container, specifically tailored for **Talos Linux**. The script supports sending real-time notifications via Pushover when a scrub starts and completes.

The container now **dynamically downloads** the appropriate ZFS package based on the specified `TALOS_VERSION`, ensuring compatibility with your Talos Linux system.

> **Note:** This is primarily for personal use, but it's open-sourced in case others find it useful.

## Usage

### Environment Variables

Configure the script using the following environment variables:

| Variable                | Required | Default | Description                                                                                   |
|-------------------------|----------|---------|-----------------------------------------------------------------------------------------------|
| `ZFS_POOL`              | **Yes**  |         | Name of the ZFS pool on which to perform actions.                                             |
| `TALOS_VERSION`         | **Yes**  |         | Talos Linux version to determine the compatible ZFS package.                                  |
| `ACTION`                | No       | `scrub` | Action to perform (`scrub` is the supported action).                                           |
| `PUSHOVER_NOTIFICATION` | No       | `false` | Set to `true` to enable Pushover notifications.                                               |
| `PUSHOVER_USER_KEY`     | Cond.    |         | Your Pushover User Key. Required if `PUSHOVER_NOTIFICATION` is `true`.                        |
| `PUSHOVER_API_TOKEN`    | Cond.    |         | Your Pushover API Token. Required if `PUSHOVER_NOTIFICATION` is `true`.                       |

*Cond.*: Required if `PUSHOVER_NOTIFICATION` is `true`.

### Actions

- **`scrub`**: Starts a ZFS scrub on the specified pool.

## Example Usage

Here's an example of how to deploy the script using a HelmRelease in Kubernetes:

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/bjw-s/helm-charts/main/charts/other/app-template/schemas/helmrelease-helm-v2.schema.json
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: zfs-scrub
spec:
  interval: 30m
  chart:
    spec:
      chart: app-template
      version: 3.5.1
      sourceRef:
        kind: HelmRepository
        name: bjw-s
        namespace: flux-system
  install:
    remediation:
      retries: 3
  upgrade:
    remediation:
      strategy: rollback
      retries: 3

  values:
    controllers:
      zfs-scrub:
        type: cronjob
        cronjob:
          schedule: "0 0 1,15 * *"
          successfulJobsHistory: 1
          failedJobsHistory: 1
          concurrencyPolicy: Forbid
          timeZone: ${TIMEZONE}
          backoffLimit: 0
        containers:
          app:
            image:
              repository: ghcr.io/heavybullets8/zfs-scrubber
              tag: 1.0.5@sha256:d977db8813026b4ba54298313c6bd535ef02106f74673fc1201248ccd174cbd2
            env:
              ZFS_POOL: "speed"
              PUSHOVER_NOTIFICATION: true
              TALOS_VERSION: v1.8.2
            envFrom:
              - secretRef: # For our PUSHOVER_USER_KEY and PUSHOVER_API_TOKEN values
                  name: zfs-scrubber-secret
            securityContext:
              privileged: true

    persistence:
      dev:
        type: hostPath
        hostPath: /dev/zfs
        globalMounts:
          - path: /dev/zfs
```

## Flux Users

Flux users can dynamically set the `TALOS_VERSION` using Flux's substitution feature. Here's how to configure your `ks.yaml`:

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: zfs-scrubber
  namespace: flux-system
spec:
  targetNamespace: zfs
  commonMetadata:
    labels:
      app.kubernetes.io/name: zfs-scrubber
  path: ./kubernetes/apps/zfs/zfs-scrubber/app
  prune: true
  sourceRef:
    kind: GitRepository
    name: home-kubernetes
  wait: false
  interval: 30m
  timeout: 5m
  postBuild:
    substitute:
      # renovate: datasource=docker depName=ghcr.io/siderolabs/installer
      TALOS_VERSION: v1.8.2
```

With this setup, when Talos is updated by Renovate, the `TALOS_VERSION` environment variable will automatically update, ensuring the container fetches the correct ZFS package.

**Environment Variable Example:**
```yaml
env:
  TALOS_VERSION: ${TALOS_VERSION}
```

## Notes

- **Pushover Notifications:** Set `PUSHOVER_NOTIFICATION` to `true` and provide your `PUSHOVER_USER_KEY` and `PUSHOVER_API_TOKEN` to receive notifications.
- **Security Context:** The container requires privileged access to perform ZFS operations.
- **Persistence:** Ensure that the `/dev/zfs` device is available within the container.
- **Permissions:** Access to `/dev/zfs` requires `securityContext.privileged = true`
- **backoffLimit** This should be set to `0`, to avoid running the job again if the scrub fails, which could wear out your drives.
